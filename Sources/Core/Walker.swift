import Foundation
import Darwin

/// Which locations are indexed and what is skipped.
struct ScanOptions {
    /// Absolute paths to scan, e.g. ["/"] or ["/Users", "/Applications"].
    var roots: [String] = ["/"]
    /// Absolute path prefixes that are never indexed.
    var excludedPaths: [String] = ScanOptions.defaultExcludes
    /// Descend into `.app`, `.bundle`, … when true.
    var descendPackages: Bool = true
    /// Skip hidden items entirely (and do not descend into hidden folders).
    var skipHidden: Bool = false
    /// Also index mounted volumes under /Volumes.
    var indexMountedVolumes: Bool = false

    static let defaultExcludes: [String] = [
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100",
        "/.Trashes", "/.TemporaryItems", "/.vol", "/.MobileBackups",
        "/dev", "/net", "/home", "/System/Volumes",
        // Mirrors of the whole volume root created by the OS/sandbox plumbing;
        // walking them would index every path twice.
        "/.nofollow"
    ]
}

/// Mount points, read once via `getmntinfo`. The walker stops at these so that
/// the firmlinked data volume is not indexed twice (its content is reachable
/// through the firmlinks `/Users`, `/Applications`, `/Library`, `/private` …).
enum MountTable {
    static func mountPoints() -> [[UInt8]] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let list = buf else { return [] }
        var out: [[UInt8]] = []
        for i in 0..<Int(n) {
            let name = withUnsafeBytes(of: list[i].f_mntonname) { raw -> String in
                let p = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: p)
            }
            out.append(Array(name.utf8))
        }
        return out
    }
}

/// One worker-local slice of the index. Workers never share mutable state, so
/// scanning scales with cores; slices are merged (already sorted) at the end.
final class ShardBuilder {
    var pathBuf: [UInt8] = []
    var entries: [FSEntry] = []
    var skipped: Int = 0
    var files: Int = 0
    var folders: Int = 0

    init() {
        pathBuf.reserveCapacity(1 << 22)
        entries.reserveCapacity(1 << 16)
    }

    @inline(__always)
    func add(buf: UnsafePointer<UInt8>, pathLen: Int, nameLen: Int, size: Int64,
             mtime: Int32, btime: Int32, flags: UInt8) {
        var e = FSEntry()
        e.pathOff = UInt32(pathBuf.count)
        e.pathLen = UInt32(pathLen)
        e.nameLen = UInt16(nameLen)
        e.flags = flags
        e.size = size
        e.mtime = mtime
        e.btime = btime
        pathBuf.append(contentsOf: UnsafeBufferPointer(start: buf, count: pathLen))
        pathBuf.append(0)
        entries.append(e)
        if flags & EntryFlag.isDir != 0 { folders += 1 } else { files += 1 }
    }

    func sortByPath() {
        guard entries.count > 1 else { return }
        pathBuf.withUnsafeBufferPointer { pb in
            guard let base = pb.baseAddress else { return }
            entries.sort { pathCompare(base, $0, $1) < 0 }
        }
    }

    /// Removes adjacent duplicates (the slice must already be path sorted).
    ///
    /// Incremental batches can legitimately describe the same object twice — for
    /// example a created folder is expanded recursively *and* the file inside it
    /// also arrives as its own event. Keeping the last copy means the freshest
    /// stat data wins.
    func dedupeSorted() {
        _ = dedupeAdjacentEntries(pathBuf: &pathBuf, entries: &entries)
    }
}

/// Shared work queue with completion tracking, so every core stays busy on
/// wildly unbalanced subtrees (e.g. `~/Library/Caches`).
final class WorkQueue {
    private let cond = NSCondition()
    private var items: [[UInt8]] = []
    private var inflight = 0
    private var cancelled = false

    func push(_ item: [UInt8]) {
        cond.lock()
        items.append(item)
        cond.broadcast()
        cond.unlock()
    }

    /// Blocks until a directory is available or all outstanding work is done.
    func take() -> [UInt8]? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if cancelled { return nil }
            if let last = items.popLast() {
                inflight += 1
                return last
            }
            if inflight == 0 {
                cond.broadcast()
                return nil
            }
            cond.wait()
        }
    }

    func finishItem() {
        cond.lock()
        inflight -= 1
        if inflight == 0 { cond.broadcast() }
        cond.unlock()
    }

    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }
}

/// Progress reporter that coalesces updates (≈8/s) instead of hammering the UI.
final class ScanProgress {
    private let lock = NSLock()
    private var seen = 0
    private var lastEmit = Date.distantPast
    var onUpdate: ((Int) -> Void)?

    func bump(_ n: Int) {
        lock.lock()
        seen += n
        let now = Date()
        let emit = now.timeIntervalSince(lastEmit) > 0.1
        if emit { lastEmit = now }
        let total = seen
        lock.unlock()
        if emit { onUpdate?(total) }
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}

enum Walker {
    /// Test hook: force the number of scanning threads (0 = auto).
    static var workerCountOverride: Int = 0
    /// Test hook: called with each worker slice before the merge.
    static var shardHook: ((ShardBuilder, Int) -> Void)?

    /// Scans `options.roots` in parallel and returns one globally sorted index.
    static func scan(options: ScanOptions,
                     progress: ScanProgress,
                     isCancelled: @escaping () -> Bool) -> FileIndex {
        let t0 = Date()
        let mountPoints = MountTable.mountPoints()
        let excludes = options.excludedPaths.map { Array($0.utf8) }
        var roots = options.roots
        if options.indexMountedVolumes {
            for m in mountPoints where String(decoding: m, as: UTF8.self).hasPrefix("/Volumes/") {
                roots.append(String(decoding: m, as: UTF8.self))
            }
        }

        let queue = WorkQueue()
        var rootSet = Set<[UInt8]>()
        for r in roots {
            var b = Array(r.utf8)
            while b.count > 1 && b.last == 0x2F { b.removeLast() }
            rootSet.insert(b)
            queue.push(b)
        }

        let workerCount = workerCountOverride > 0 ? min(workerCountOverride, 16)
            : max(1, min(ProcessInfo.processInfo.activeProcessorCount, 16))
        var shards = [ShardBuilder?](repeating: nil, count: workerCount)
        let shardLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            let shard = ShardBuilder()
            let walker = DirWalker(options: options, queue: queue, mountPoints: mountPoints,
                                   excludes: excludes, rootSet: rootSet, progress: progress,
                                   isCancelled: isCancelled)
            walker.run(into: shard)
            shard.sortByPath()
            Walker.shardHook?(shard, workerIndex)
            shardLock.lock()
            shards[workerIndex] = shard
            shardLock.unlock()
        }

        let merged = mergeAll(shards.compactMap { $0 })
        let index = FileIndex()
        index.pathBuf = merged.pathBuf
        index.entries = merged.entries
        index.stats.started = t0
        index.stats.duration = Date().timeIntervalSince(t0)
        index.stats.files = merged.files
        index.stats.folders = merged.folders
        index.stats.skipped = merged.skipped
        index.stats.roots = roots
        return index
    }

    /// Straight two-cursor merge of two path-sorted slices.
    static func mergePair(_ a: ShardBuilder, _ b: ShardBuilder) -> ShardBuilder {
        if a.entries.isEmpty { return b }
        if b.entries.isEmpty { return a }
        let out = ShardBuilder()
        out.files = a.files + b.files
        out.folders = a.folders + b.folders
        out.skipped = a.skipped + b.skipped

        var outBuf = [UInt8]()
        outBuf.reserveCapacity(a.pathBuf.count + b.pathBuf.count + 8)
        var outEntries = [FSEntry]()
        outEntries.reserveCapacity(a.entries.count + b.entries.count)
        a.pathBuf.withUnsafeBufferPointer { pa in
            b.pathBuf.withUnsafeBufferPointer { pb in
                let ba = pa.baseAddress!, bb = pb.baseAddress!
                var i = 0, j = 0
                let na = a.entries.count, nb = b.entries.count
                a.entries.withUnsafeBufferPointer { ea in
                    b.entries.withUnsafeBufferPointer { eb in
                        @inline(__always) func emit(_ bytes: UnsafePointer<UInt8>,
                                                    _ off: Int, _ len: Int, _ e: FSEntry) {
                            outBuf.append(contentsOf: UnsafeBufferPointer(start: bytes + off, count: len))
                            outBuf.append(0)
                            var copy = e
                            copy.pathOff = UInt32(outBuf.count - len - 1)
                            outEntries.append(copy)
                        }
                        while i < na && j < nb {
                            if pathCompare2(ba, ea[i], bb, eb[j]) <= 0 {
                                let e = ea[i]
                                emit(ba, Int(e.pathOff), Int(e.pathLen), e)
                                i += 1
                            } else {
                                let e = eb[j]
                                emit(bb, Int(e.pathOff), Int(e.pathLen), e)
                                j += 1
                            }
                        }
                        while i < na {
                            let e = ea[i]; emit(ba, Int(e.pathOff), Int(e.pathLen), e); i += 1
                        }
                        while j < nb {
                            let e = eb[j]; emit(bb, Int(e.pathOff), Int(e.pathLen), e); j += 1
                        }
                    }
                }
            }
        }
        out.pathBuf = outBuf
        out.entries = outEntries
        return out
    }

    /// Parallel pairwise merge: log2(k) rounds, each round fully concurrent.
    static func mergeAll(_ shards: [ShardBuilder]) -> ShardBuilder {
        if shards.isEmpty { return ShardBuilder() }
        if shards.count == 1 { return shards[0] }
        if shards.count == 2 { return mergePair(shards[0], shards[1]) }
        let mid = shards.count / 2
        var left: ShardBuilder?
        var right: ShardBuilder?
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            left = mergeAll(Array(shards[0..<mid]))
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            right = mergeAll(Array(shards[mid...]))
        }
        group.wait()
        return mergePair(left!, right!)
    }
}

/// A single worker: holds its scratch buffer so that walking allocates nothing
/// per directory entry.
final class DirWalker {
    private let options: ScanOptions
    private let queue: WorkQueue
    private let mountPoints: [[UInt8]]
    private let excludes: [[UInt8]]
    private let rootSet: Set<[UInt8]>
    private let progress: ScanProgress
    private let isCancelled: () -> Bool

    /// Scratch buffer for the path currently being examined. Allocated once:
    /// no Swift array is ever mutated while a pointer into it is alive.
    private let scratch: UnsafeMutablePointer<UInt8>
    private let scratchCap = 8192


    init(options: ScanOptions, queue: WorkQueue, mountPoints: [[UInt8]], excludes: [[UInt8]],
         rootSet: Set<[UInt8]>, progress: ScanProgress, isCancelled: @escaping () -> Bool) {
        self.options = options
        self.queue = queue
        self.mountPoints = mountPoints
        self.excludes = excludes
        self.rootSet = rootSet
        self.progress = progress
        self.isCancelled = isCancelled
        self.scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
    }

    deinit {
        scratch.deallocate()
    }

    func run(into shard: ShardBuilder) {
        while let dir = queue.take() {
            scanDirectory(dir, into: shard)
            queue.finishItem()
            if isCancelled() { queue.cancel(); break }
        }
    }

    /// True when this directory must not be entered.
    @inline(__always)
    private func isPruned(_ path: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        for m in mountPoints {
            if m.count == length && memcmp(path, m, length) == 0 { return true }
        }
        for e in excludes {
            let n = e.count
            if length == n {
                if memcmp(path, e, n) == 0 { return true }
            } else if length > n && path[n] == 0x2F {
                if memcmp(path, e, n) == 0 { return true }
            }
        }
        return false
    }

    @inline(__always)
    private func isExcludedFile(_ path: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        for e in excludes {
            let n = e.count
            if length == n {
                if memcmp(path, e, n) == 0 { return true }
            } else if length > n && path[n] == 0x2F {
                if memcmp(path, e, n) == 0 { return true }
            }
        }
        return false
    }

    private func scanDirectory(_ dirPath: [UInt8], into shard: ShardBuilder) {
        let dirLen = dirPath.count
        guard dirLen + 2 < scratchCap else { shard.skipped += 1; return }
        let parentLen = (dirLen > 0 && dirPath[dirLen - 1] == 0x2F) ? dirLen - 1 : dirLen
        dirPath.withUnsafeBufferPointer { src in
            _ = memcpy(scratch, src.baseAddress!, dirLen)
        }
        // The root "/" must not become "//": that would hide it from mount point
        // pruning and duplicate the whole data volume.
        var cursor = dirLen
        if dirLen == 0 || scratch[dirLen - 1] != 0x2F {
            scratch[cursor] = 0x2F
            cursor += 1
        }
        let nameStart = cursor
        scratch[nameStart] = 0
        let isRoot = rootSet.contains(dirPath)
        var added = 0

        guard let dirp = opendir(scratch) else {
            shard.skipped += 1
            progress.bump(1)
            return
        }
        defer { closedir(dirp) }
        if !isRoot && isPruned(scratch, parentLen) {
            progress.bump(1)
            return
        }

        while true {
            guard let de = readdir(dirp) else { break }
            let nameLen = readdirNameLength(de)
            if nameLen == 0 { continue }
            guard nameStart + nameLen + 1 < scratchCap else { shard.skipped += 1; continue }
            let namePtr = readdirNamePointer(de)
            if namePtr[0] == 0x2E {
                if nameLen == 1 { continue }
                if nameLen == 2 && namePtr[1] == 0x2E { continue }
            }
            memcpy(scratch + nameStart, namePtr, nameLen)
            let pathLen = nameStart + nameLen
            scratch[pathLen] = 0

            var st = stat()
            guard lstat(scratch, &st) == 0 else {
                shard.skipped += 1
                continue
            }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            let isLnk = (st.st_mode & S_IFMT) == S_IFLNK

            var flags: UInt8 = 0
            if isDir { flags |= EntryFlag.isDir }
            if isLnk { flags |= EntryFlag.isSymlink }
            let hidden = namePtr[0] == 0x2E || (st.st_flags & UInt32(UF_HIDDEN)) != 0
            if hidden { flags |= EntryFlag.isHidden }
            if (st.st_mode & 0o111) != 0 { flags |= EntryFlag.isExecutable }
            if isDir && isBundleName(UnsafeBufferPointer(start: namePtr, count: nameLen)) {
                flags |= EntryFlag.isPackage
            }
            if options.skipHidden && hidden { continue }
            if isExcludedFile(scratch, pathLen) { shard.skipped += 1; continue }

            let size = isDir ? 0 : Int64(st.st_size)
            let mtime = clampTime(st.st_mtimespec.tv_sec)
            let btime = clampTime(st.st_birthtimespec.tv_sec)

            shard.add(buf: scratch, pathLen: pathLen, nameLen: nameLen, size: size,
                      mtime: mtime, btime: btime, flags: flags)
            added += 1

            if isDir && !isLnk {
                if options.descendPackages || (flags & EntryFlag.isPackage) == 0 {
                    var child = [UInt8]()
                    child.reserveCapacity(pathLen)
                    child.append(contentsOf: UnsafeBufferPointer(start: scratch, count: pathLen))
                    queue.push(child)
                }
            }
        }
        progress.bump(added + 1)
    }
}

@inline(__always)
func clampTime(_ t: Int) -> Int32 {
    if t > Int(Int32.max) { return Int32.max }
    if t < 0 { return 0 }
    return Int32(t)
}

/// `dirent.d_name` is a fixed-size C tuple; this reads it without building a
/// Swift String. The returned pointer is valid while `de` is (until the next
/// `readdir` call on the same directory).
@inline(__always)
private func readdirNamePointer(_ de: UnsafeMutablePointer<dirent>) -> UnsafePointer<UInt8> {
    withUnsafePointer(to: &de.pointee.d_name) { p in
        UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self)
    }
}

@inline(__always)
private func readdirNameLength(_ de: UnsafeMutablePointer<dirent>) -> Int {
    let p = readdirNamePointer(de)
    var n = 0
    while p[n] != 0 { n += 1 }
    return n
}

@inline(__always)
func isBundleName(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
    var dot = -1
    var i = name.count - 1
    while i >= 0 {
        if name[i] == 0x2E { dot = i; break }
        i -= 1
    }
    guard dot >= 0, dot < name.count - 1 else { return false }
    var extBytes = [UInt8]()
    extBytes.reserveCapacity(name.count - dot - 1)
    for k in (dot + 1)..<name.count { extBytes.append(asciiLower(name[k])) }
    return BundleExtensions.all.contains(String(decoding: extBytes, as: UTF8.self))
}
