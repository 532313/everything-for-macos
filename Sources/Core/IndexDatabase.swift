import Foundation
import CoreServices

enum IndexState: Equatable {
    case empty
    case scanning
    case live
    case updating
    case failed(String)
}

struct IndexStatus {
    var state: IndexState = .empty
    var scanned: Int = 0
    var files: Int = 0
    var folders: Int = 0
    var bytes: Int64 = 0
    var lastDuration: TimeInterval = 0
    var watching: Bool = false
    var cacheLoaded = false
    var message: String = ""
}

/// Owns the live index: full scans, FSEvents driven incremental updates and an
/// on-disk cache so a relaunch is instant.
///
/// Readers never block on writers: every mutation produces a brand new
/// immutable snapshot which is swapped in atomically.
final class IndexDatabase {

    // MARK: public configuration

    var scanOptions = ScanOptions()
    var indexDirectory: URL
    var onStatusChange: ((IndexStatus) -> Void)?
    var onIndexChanged: (() -> Void)?
    /// A cache older than this is shown immediately but refreshed in the
    /// background (the FSEvents replay for it would be slow and lossy).
    var rescanInBackgroundAge: TimeInterval = 30 * 60

    // MARK: internals

    private var snapshot = FileIndex()
    private let snapshotLock = NSLock()
    private let updateQueue = DispatchQueue(label: "everything.update")
    private let saveQueue = DispatchQueue(label: "everything.save")
    private var watcher: FSWatcher?
    private var lastEventID: UInt64 = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    private var pendingEvents: [FSWatcher.Event] = []
    private var pendingLock = NSLock()
    private var applyWork: DispatchWorkItem?
    private var scanning = false
    private var cancelScan = false
    private var statusLock = NSLock()
    private var current = IndexStatus()
    private var dirty = false
    private var repairedOnLoad = false

    init(indexDirectory: URL? = nil) {
        self.indexDirectory = indexDirectory ?? IndexDatabase.defaultDirectory()
        if let path = ProcessInfo.processInfo.environment["EVERYTHING_DEBUG_LOG"], !path.isEmpty {
            IndexDatabase.debugLogURL = URL(fileURLWithPath: path)
        }
    }

    /// Optional diagnostics: set EVERYTHING_DEBUG_LOG to a file path to trace
    /// scanning, FSEvents batches and merges.
    static var debugLogURL: URL?

    static func trace(_ message: String) {
        guard let url = debugLogURL else { return }
        let line = String(format: "%.3f  %@\n", Date().timeIntervalSince1970, message)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func defaultDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["EVERYTHING_INDEX_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Everything", isDirectory: true)
    }

    var cacheURL: URL { indexDirectory.appendingPathComponent("index.bin") }

    /// True when the in-memory index has changes not yet written to disk.
    var hasUnsavedChanges: Bool {
        statusLock.lock(); defer { statusLock.unlock() }
        return dirty
    }

    var status: IndexStatus {
        statusLock.lock(); defer { statusLock.unlock() }
        return current
    }

    private func updateStatus(_ mutate: (inout IndexStatus) -> Void, notify: Bool = true) {
        statusLock.lock()
        mutate(&current)
        let snapshotStatus = current
        statusLock.unlock()
        if notify {
            DispatchQueue.main.async { self.onStatusChange?(snapshotStatus) }
        }
    }

    func currentIndex() -> FileIndex {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot
    }

    private func publish(_ newIndex: FileIndex) {
        snapshotLock.lock()
        snapshot = newIndex
        snapshotLock.unlock()
    }

    // MARK: - lifecycle

    /// Loads the cached index (if any) and starts watching for changes.
    func start(watch: Bool = true, rescanIfStale: TimeInterval = 24 * 3600) {
        let loaded = loadCache()
        updateStatus { s in
            s.cacheLoaded = loaded
            s.files = self.snapshot.stats.files
            s.folders = self.snapshot.stats.folders
            s.bytes = self.snapshot.stats.totalBytes
            s.state = loaded ? .live : .empty
        }
        if watch { startWatching() }
        if !loaded || cacheAge() > rescanIfStale {
            rebuild()
        } else if cacheAge() > rescanInBackgroundAge {
            // The cached index may be missing changes from the idle period and
            // the FSEvents replay for it is slow: show it immediately, then
            // refresh in the background.
            markClean()
            updateStatus { $0.message = "Showing cached index; refreshing in the background…" }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.rebuild()
            }
        } else {
            markClean()
            if repairedOnLoad {
                // Persist the healed ordering once, in the background: writing a
                // few hundred MB must never block the UI thread.
                repairedOnLoad = false
                dirty = true
                saveQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.saveCache()
                }
            }
        }
    }

    private func cacheAge() -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let date = attrs[.modificationDate] as? Date else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(date)
    }

    private func markClean() {
        dirty = false
        startSaveTimer()
    }

    func stop() {
        IndexDatabase.trace("stop() called")
        watcher?.stop()
        watcher = nil
        saveCache()
    }

    // MARK: - full scan

    var isScanning: Bool {
        statusLock.lock(); defer { statusLock.unlock() }
        return scanning
    }

    func rebuild() {
        statusLock.lock()
        if scanning {
            statusLock.unlock()
            return
        }
        scanning = true
        cancelScan = false
        statusLock.unlock()

        let options = scanOptions
        updateStatus { s in
            s.state = .scanning
            s.scanned = 0
            s.message = "Indexing \(options.roots.joined(separator: ", "))…"
        }
        // Remember the event id *before* walking the tree: resuming from it after
        // the scan replays exactly the changes that happened while scanning.
        let watchPoint = FSWatcher.currentEventID()
        let progress = ScanProgress()
        progress.onUpdate = { [weak self] n in
            self?.updateStatus { $0.scanned = n }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let started = Date()
            let newIndex = Walker.scan(options: options, progress: progress) { [weak self] in
                guard let self = self else { return true }
                self.statusLock.lock(); defer { self.statusLock.unlock() }
                return self.cancelScan
            }
            self.publish(newIndex)
            self.updateStatus { s in
                s.state = .live
                s.scanned = newIndex.count
                s.files = newIndex.stats.files
                s.folders = newIndex.stats.folders
                s.bytes = newIndex.stats.totalBytes
                s.lastDuration = newIndex.stats.duration
                s.message = String(format: "Indexed %d objects in %.1fs",
                                   newIndex.count, newIndex.stats.duration)
            }
            self.statusLock.lock()
            self.scanning = false
            self.statusLock.unlock()
            self.dirty = true
            self.saveCache()
            self.markClean()
            _ = started
            DispatchQueue.main.async { self.onIndexChanged?() }
            // Keep the existing stream and apply the events collected while
            // scanning. (Resuming a stream from an old event id instead would
            // make the kernel replay history in a throttled trickle, leaving the
            // index seconds-to-minutes behind reality.)
            if self.watcher == nil {
                self.startWatching(sinceNow: true)
            } else {
                IndexDatabase.trace("scan finished; flushing \(self.pendingEvents.count) buffered events (watchPoint=\(watchPoint))")
                self.scheduleApply(after: 0.1)
            }
        }
    }

    // MARK: - watching

    private func startWatching(sinceNow: Bool = false, since explicitSince: UInt64? = nil) {
        watcher?.stop()
        let since: UInt64
        if let explicit = explicitSince {
            since = explicit
        } else if sinceNow || lastEventID == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) {
            since = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        } else {
            since = lastEventID
        }
        IndexDatabase.trace("startWatching since=\(since) lastEventID=\(lastEventID) roots=\(scanOptions.roots)")
        let w = FSWatcher { [weak self] events, lastID in
            self?.receive(events: events, lastID: lastID)
        }
        var paths = scanOptions.roots
        if paths.isEmpty { paths = ["/"] }
        let ok = w.start(paths: paths, sinceWhen: since)
        watcher = w
        IndexDatabase.trace("watcher started ok=\(ok) err=\(w.lastError ?? "none")")
        updateStatus { $0.watching = ok }
    }

    /// Schedules one pending incremental apply (leading-edge coalescing: when a
    /// work item is already queued the events simply join that batch).
    private func scheduleApply(after delay: TimeInterval) {
        pendingLock.lock()
        if applyWork != nil {
            pendingLock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingLock.lock()
            self.applyWork = nil
            self.pendingLock.unlock()
            self.applyPending()
        }
        applyWork = work
        pendingLock.unlock()
        updateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receive(events: [FSWatcher.Event], lastID: UInt64) {
        if lastID != 0 { lastEventID = lastID }
        pendingLock.lock()
        pendingEvents.append(contentsOf: events)
        // Bound the backlog: keep the newest events, they supersede older ones.
        if pendingEvents.count > 8_000 {
            pendingEvents.removeFirst(pendingEvents.count - 8_000)
        }
        let overflow = pendingEvents.count >= 8_000
        pendingLock.unlock()
        IndexDatabase.trace("receive \(events.count) events lastID=\(lastID) pending=\(pendingEvents.count)")
        scheduleApply(after: 0.6)
        if overflow && !isScanning {
            rebuild()
        }
    }

    private func applyPending() {
        if isScanning {
            // A full scan is rebuilding the index. Keep the events and apply
            // them on top of the fresh index instead of losing them.
            IndexDatabase.trace("applyPending deferred (scan in progress)")
            scheduleApply(after: 1.0)
            return
        }
        pendingLock.lock()
        let events = pendingEvents
        pendingEvents.removeAll()
        pendingLock.unlock()
        guard !events.isEmpty else { return }

        var rescan = false
        var paths: [String] = []
        if IndexDatabase.debugLogURL != nil {
            for e in events.prefix(4) { IndexDatabase.trace("  event: \(e.path) flags=\(e.flags)") }
        }
        for e in events {
            if FSWatcher.needsFullRescan(e.flags) { rescan = true; break }
            if FSWatcher.isItemChange(e.flags) || FSWatcher.needsSubdirScan(e.flags) {
                paths.append(e.path)
            }
        }
        IndexDatabase.trace("applyPending events=\(events.count) changes=\(paths.count) rescan=\(rescan)")
        if paths.count > 2_000 {
            // Cheaper to walk the tree once than to merge thousands of records.
            IndexDatabase.trace("large batch (\(paths.count)) -> full rescan")
            rebuild()
            return
        }
        if rescan {
            rebuild()
            return
        }
        applyPaths(paths)
    }

    /// Normalises an FSEvents path into the user visible namespace.
    static func normalizeEventPath(_ raw: String) -> String? {
        var s = raw
        if s.hasPrefix("/System/Volumes/Data/") {
            s = String(s.dropFirst("/System/Volumes/Data".count))
        } else if s == "/System/Volumes/Data" {
            return nil
        }
        if s.hasPrefix("/System/Volumes/") || s == "/System/Volumes" { return nil }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty || s == "/" || s == "/dev" || s == "/net" || s == "/home" { return nil }
        return s
    }

    private func isExcluded(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        for ex in scanOptions.excludedPaths {
            let e = Array(ex.utf8)
            if bytes.count == e.count {
                if memcmp(bytes, e, e.count) == 0 { return true }
            } else if bytes.count > e.count && bytes[e.count] == 0x2F {
                if memcmp(bytes, e, e.count) == 0 { return true }
            }
        }
        return false
    }

    /// Incremental update: stat every touched path, rescan freshly created
    /// folders, and rebuild the sorted arrays in one merge pass.
    func applyPaths(_ rawPaths: [String]) {
        let options = scanOptions
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            self.updateStatus { $0.state = .updating }

            var seen = Set<String>()
            var adds: [String] = []
            var removes: [String] = []
            for raw in rawPaths {
                guard let p = IndexDatabase.normalizeEventPath(raw) else { continue }
                if self.isExcluded(p) { continue }
                if !seen.insert(p).inserted { continue }
                var st = stat()
                if lstat(p, &st) == 0 {
                    adds.append(p)
                } else {
                    removes.append(p)
                }
            }
            if IndexDatabase.debugLogURL != nil {
                IndexDatabase.trace("applyPaths adds=\(adds.count) \(adds.prefix(3)) removes=\(removes.count) \(removes.prefix(3))")
            }
            guard !adds.isEmpty || !removes.isEmpty else {
                self.updateStatus { $0.state = .live }
                return
            }

            let old = self.currentIndex()

            // Gather the new records (recursing into created/changed folders).
            let shard = ShardBuilder()
            let mountPoints = MountTable.mountPoints()
            for p in adds {
                var bytes = Array(p.utf8)
                let before = shard.entries.count
                Self.appendSubtree(path: &bytes, options: options, mountPoints: mountPoints, into: shard)
                if IndexDatabase.debugLogURL != nil && shard.entries.count == before {
                    IndexDatabase.trace("  !! add produced no record: \(p)")
                }
            }
            shard.sortByPath()
            shard.dedupeSorted()

            var removeBytes: [[UInt8]] = removes.map { Array($0.utf8) }
            removeBytes.sort { a, b in
                if a.count != b.count { return a.count < b.count }
                return memcmp(a, b, a.count) < 0
            }

            let merged = Self.merge(old: old, additions: shard, removals: removeBytes)
            IndexDatabase.trace("merged adds=\(adds.count) shard=\(shard.entries.count) removes=\(removes.count) old=\(old.count) -> \(merged.count) objects")
            self.publish(merged)
            self.dirty = true
            self.updateStatus { s in
                s.state = .live
                s.files = merged.stats.files
                s.folders = merged.stats.folders
                s.bytes = merged.stats.totalBytes
            }
            DispatchQueue.main.async { self.onIndexChanged?() }
            self.scheduleIncrementalSave()
        }
    }

    /// Adds `path` itself and, when it is a folder, everything below it.
    private static func appendSubtree(path: inout [UInt8], options: ScanOptions,
                                      mountPoints: [[UInt8]], into shard: ShardBuilder) {
        guard appendOne(path: path, options: options, into: shard) else { return }
        var st = stat()
        guard withCString(path, { lstat($0, &st) }) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFDIR, (st.st_mode & S_IFMT) != S_IFLNK else { return }
        let queue = WorkQueue()
        queue.push(path)
        let walker = DirWalker(options: options, queue: queue, mountPoints: mountPoints,
                               excludes: options.excludedPaths.map { Array($0.utf8) },
                               rootSet: Set([path]), progress: ScanProgress(),
                               isCancelled: { false })
        walker.run(into: shard)
    }

    /// `lstat`/`open` need a NUL terminated path: a bare `[UInt8]` is not one
    /// (reading past its storage is undefined behaviour and used to drop
    /// freshly created files at random).
    static func withCString<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
        var terminated = bytes
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self))
        }
    }

    /// Records a single path (file, folder or symlink) without descending.
    @discardableResult
    static func appendOne(path: [UInt8], options: ScanOptions, into shard: ShardBuilder) -> Bool {
        guard !path.isEmpty else { return false }
        var st = stat()
        guard withCString(path, { lstat($0, &st) }) == 0 else { return false }
        var nameStart = 0
        var i = path.count - 1
        while i >= 0 {
            if path[i] == 0x2F { nameStart = i + 1; break }
            i -= 1
        }
        let nameLen = path.count - nameStart
        guard nameLen > 0 else { return false }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let isLnk = (st.st_mode & S_IFMT) == S_IFLNK
        var flags: UInt8 = 0
        if isDir { flags |= EntryFlag.isDir }
        if isLnk { flags |= EntryFlag.isSymlink }
        let hidden = path[nameStart] == 0x2E || (st.st_flags & UInt32(UF_HIDDEN)) != 0
        if hidden { flags |= EntryFlag.isHidden }
        if (st.st_mode & 0o111) != 0 { flags |= EntryFlag.isExecutable }
        guard !(options.skipHidden && hidden) else { return false }
        let isPkg = isDir && path.withUnsafeBufferPointer {
            isBundleName(UnsafeBufferPointer(start: $0.baseAddress! + nameStart, count: nameLen))
        }
        if isPkg { flags |= EntryFlag.isPackage }
        let size = isDir ? 0 : Int64(st.st_size)
        path.withUnsafeBufferPointer { pb in
            shard.add(buf: pb.baseAddress!, pathLen: path.count, nameLen: nameLen, size: size,
                      mtime: clampTime(st.st_mtimespec.tv_sec),
                      btime: clampTime(st.st_birthtimespec.tv_sec), flags: flags)
        }
        return true
    }

    /// Merges additions/removals into a brand new snapshot.
    static func merge(old: FileIndex, additions: ShardBuilder, removals: [[UInt8]]) -> FileIndex {
        let n = old.count
        let m = additions.entries.count

        // 1. mark deleted subtrees
        var deleted = [Bool](repeating: false, count: n)
        var deletedCount = 0
        if !removals.isEmpty {
            old.entries.withUnsafeBufferPointer { eb in
                old.pathBuf.withUnsafeBufferPointer { pb in
                    let base = pb.baseAddress!
                    for r in removals {
                        var lo = 0, hi = n
                        while lo < hi {
                            let mid = (lo + hi) / 2
                            if pathCompareBytes(base, eb[mid], r.withUnsafeBufferPointer { $0 }) < 0 {
                                lo = mid + 1
                            } else {
                                hi = mid
                            }
                        }
                        var i = lo
                        let rlen = r.count
                        while i < n {
                            let e = eb[i]
                            if Int(e.pathLen) < rlen { i += 1; continue }
                            if memcmp(base + Int(e.pathOff), r, rlen) != 0 { break }
                            let isSelf = Int(e.pathLen) == rlen
                            let isChild = Int(e.pathLen) > rlen && base[Int(e.pathOff) + rlen] == 0x2F
                            if isSelf || isChild {
                                if !deleted[i] { deleted[i] = true; deletedCount += 1 }
                            }
                            i += 1
                        }
                    }
                }
            }
        }

        let out = FileIndex()
        var outBuf = [UInt8]()
        outBuf.reserveCapacity(old.pathBuf.count + additions.pathBuf.count + 16)
        var outEntries = [FSEntry]()
        outEntries.reserveCapacity(n - deletedCount + m)

        old.pathBuf.withUnsafeBufferPointer { pb in
            guard let base = pb.baseAddress else { return }
            additions.pathBuf.withUnsafeBufferPointer { ab in
                let addBase = ab.baseAddress ?? base
                old.entries.withUnsafeBufferPointer { eb in
                    additions.entries.withUnsafeBufferPointer { addE in
                        @inline(__always) func emitOld(_ i: Int) {
                            let e = eb[i]
                            let off = Int(e.pathOff), len = Int(e.pathLen)
                            outBuf.append(contentsOf: UnsafeBufferPointer(start: base + off, count: len))
                            outBuf.append(0)
                            var copy = e
                            copy.pathOff = UInt32(outBuf.count - len - 1)
                            outEntries.append(copy)
                        }
                        @inline(__always) func emitNew(_ j: Int) {
                            let e = addE[j]
                            let off = Int(e.pathOff), len = Int(e.pathLen)
                            outBuf.append(contentsOf: UnsafeBufferPointer(start: addBase + off, count: len))
                            outBuf.append(0)
                            var copy = e
                            copy.pathOff = UInt32(outBuf.count - len - 1)
                            outEntries.append(copy)
                        }
                        var i = 0, j = 0
                        while i < n && j < m {
                            let c = pathCompare2(base, eb[i], addBase, addE[j])
                            if c < 0 {
                                if !deleted[i] { emitOld(i) }
                                i += 1
                            } else if c > 0 {
                                emitNew(j)
                                j += 1
                            } else {
                                emitNew(j)   // replacement wins
                                i += 1
                                j += 1
                            }
                        }
                        while i < n {
                            if !deleted[i] { emitOld(i) }
                            i += 1
                        }
                        while j < m {
                            emitNew(j)
                            j += 1
                        }
                    }
                }
            }
        }

        out.pathBuf = outBuf
        out.entries = outEntries
        out.stats = old.stats
        out.stats.roots = old.stats.roots
        out.recomputeStats()
        return out
    }

    // MARK: - search

    func search(text: String, options: QueryOptions) -> ResultSet {
        let parsed = QueryParser.compile(text, options: options)
        let idx = currentIndex()
        return SearchEngine.run(index: idx, parsed: parsed, options: options, text: text)
    }

    // MARK: - persistence

    private static let magic = "EVTHIDX1"

    func markDirty() { dirty = true }

    private var saveTimer: DispatchSourceTimer?

    private func startSaveTimer() {
        guard saveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: saveQueue)
        timer.schedule(deadline: .now() + 120, repeating: 120)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.dirty { self.saveCache() }
        }
        timer.resume()
        saveTimer = timer
    }

    private func scheduleIncrementalSave() {
        // Persist at most every ~45 s while files are churning: a full cache
        // rewrite of a multi-million entry index is a few hundred MB.
        saveQueue.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self = self else { return }
            if self.dirty { self.saveCache() }
        }
    }

    @discardableResult
    func saveCache() -> Bool {
        let idx = currentIndex()
        IndexDatabase.trace("saveCache snapshot=\(idx.count) objects")
        guard idx.count > 0 else { return false }
        do {
            try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        } catch {
            updateStatus { $0.message = "Cannot create \(self.indexDirectory.path): \(error.localizedDescription)" }
            return false
        }
        let url = cacheURL
        let tmp = url.appendingPathExtension("tmp")
        var header: [String: Any] = [
            "version": 1,
            "stride": MemoryLayout<FSEntry>.stride,
            "count": idx.count,
            "pathBytes": idx.pathBuf.count,
            // Persisted as a string: the "since now" sentinel is UInt64.max and
            // JSONSerialization cannot represent it (the save would fail).
            "lastEventID": String(lastEventID),
            "savedAt": Date().timeIntervalSince1970,
            "roots": scanOptions.roots,
            "excludes": scanOptions.excludedPaths,
            "files": idx.stats.files,
            "folders": idx.stats.folders,
            "skipped": idx.stats.skipped
        ]
        header["scanDuration"] = idx.stats.duration

        do {
            guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return false }
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let fh = try FileHandle(forWritingTo: tmp)
            defer { try? fh.close() }
            var prefix = Data()
            prefix.append(IndexDatabase.magic.data(using: .ascii)!)
            var hl = UInt32(headerData.count).littleEndian
            withUnsafeBytes(of: &hl) { prefix.append(contentsOf: $0) }
            prefix.append(headerData)
            try fh.write(contentsOf: prefix)

            let chunk = 8 << 20
            try idx.entries.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                let total = raw.count
                while offset < total {
                    let count = min(chunk, total - offset)
                    let d = Data(bytes: raw.baseAddress! + offset, count: count)
                    try fh.write(contentsOf: d)
                    offset += count
                }
            }
            try idx.pathBuf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                let total = raw.count
                while offset < total {
                    let count = min(chunk, total - offset)
                    let d = Data(bytes: raw.baseAddress! + offset, count: count)
                    try fh.write(contentsOf: d)
                    offset += count
                }
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            dirty = false
            updateStatus { $0.message = "Index cache saved (\(idx.count) objects)" }
            return true
        } catch {
            updateStatus { $0.message = "Save failed: \(error.localizedDescription)" }
            return false
        }
    }

    @discardableResult
    func loadCache() -> Bool {
        let url = cacheURL
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 12), head.count == 12 else { return false }
        let magic = String(decoding: head.prefix(8), as: UTF8.self)
        guard magic == IndexDatabase.magic else { return false }
        var hl: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &hl) { head.copyBytes(to: $0, from: 8..<12) }
        guard hl > 0, hl < 1 << 20,
              let headerData = try? fh.read(upToCount: Int(hl)),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let version = header["version"] as? Int, version == 1,
              let stride = header["stride"] as? Int, stride == MemoryLayout<FSEntry>.stride,
              let count = header["count"] as? Int,
              let pathBytes = header["pathBytes"] as? Int else { return false }

        if let roots = header["roots"] as? [String], !roots.isEmpty { scanOptions.roots = roots }
        if let excludes = header["excludes"] as? [String] { scanOptions.excludedPaths = excludes }
        if let text = header["lastEventID"] as? String, let eid = UInt64(text) {
            lastEventID = eid
        } else if let eid = header["lastEventID"] as? UInt64 {
            lastEventID = eid
        } else if let eid = header["lastEventID"] as? Int, eid > 0 {
            lastEventID = UInt64(eid)
        }

        let entryBytes = count * MemoryLayout<FSEntry>.stride
        var entries = [FSEntry]()
        entries.reserveCapacity(count)
        var remaining = entryBytes
        var scratch = Data()
        let chunk = 8 << 20
        while remaining > 0 {
            let want = min(chunk, remaining)
            guard let d = try? fh.read(upToCount: want), !d.isEmpty else { return false }
            scratch.append(d)
            remaining -= d.count
            if scratch.count >= MemoryLayout<FSEntry>.stride {
                let usable = scratch.count - (scratch.count % MemoryLayout<FSEntry>.stride)
                scratch.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let p = raw.baseAddress!.assumingMemoryBound(to: FSEntry.self)
                    for k in 0..<(usable / MemoryLayout<FSEntry>.stride) {
                        entries.append(p[k])
                    }
                }
                scratch.removeFirst(usable)
            }
        }
        guard entries.count == count else { return false }

        var pathBuf = [UInt8]()
        pathBuf.reserveCapacity(pathBytes)
        var remaining2 = pathBytes
        while remaining2 > 0 {
            let want = min(chunk, remaining2)
            guard let d = try? fh.read(upToCount: want), !d.isEmpty else { return false }
            pathBuf.append(contentsOf: d)
            remaining2 -= d.count
        }
        guard pathBuf.count == pathBytes else { return false }

        let idx = FileIndex()
        idx.entries = entries
        idx.pathBuf = pathBuf
        idx.stats.files = header["files"] as? Int ?? 0
        idx.stats.folders = header["folders"] as? Int ?? 0
        idx.stats.skipped = header["skipped"] as? Int ?? 0
        idx.stats.roots = scanOptions.roots
        idx.stats.duration = header["scanDuration"] as? TimeInterval ?? 0
        idx.recomputeStats()
        if idx.repairOrder() {
            // A cache written by an older build can contain duplicate or
            // out-of-order records; heal it instead of serving it.
            dirty = true
            repairedOnLoad = true
            updateStatus { $0.message = "Repaired cached index order" }
        }
        publish(idx)
        return true
    }
}

extension IndexDatabase {
    /// Stops watching without saving (used by the self test).
    func stopWatchingForTest() {
        watcher?.stop()
        watcher = nil
        updateStatus { $0.watching = false }
    }
}
