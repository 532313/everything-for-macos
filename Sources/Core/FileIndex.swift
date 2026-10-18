import Foundation

/// Result of one full or partial scan, reported to the UI.
struct IndexStats {
    var files: Int = 0
    var folders: Int = 0
    var skipped: Int = 0
    var started: Date = Date()
    var duration: TimeInterval = 0
    var roots: [String] = []
    var totalBytes: Int64 = 0
}

/// The in-memory database.
///
/// * `pathBuf` holds every full path, NUL terminated, back to back.
/// * `entries` is sorted lexicographically by path, which makes subtree
///   deletion a pair of binary searches and point lookup an O(log n) compare.
final class FileIndex {
    var pathBuf: [UInt8] = []
    var entries: [FSEntry] = []
    var stats = IndexStats()

    var count: Int { entries.count }

    init() {}

    // MARK: - Byte access

    @inline(__always)
    func pathRange(_ i: Int) -> (Int, Int) {
        let e = entries[i]
        return (Int(e.pathOff), Int(e.pathLen))
    }

    @inline(__always)
    func nameRange(_ i: Int) -> (Int, Int) {
        let e = entries[i]
        return (Int(e.pathOff) + Int(e.pathLen) - Int(e.nameLen), Int(e.nameLen))
    }

    func pathString(_ i: Int) -> String {
        let (off, len) = pathRange(i)
        return stringFrom(bytes: pathBuf, offset: off, length: len)
    }

    func nameString(_ i: Int) -> String {
        let (off, len) = nameRange(i)
        return stringFrom(bytes: pathBuf, offset: off, length: len)
    }

    func url(_ i: Int) -> URL {
        URL(fileURLWithPath: pathString(i))
    }

    func parentPath(_ i: Int) -> String {
        let p = pathString(i)
        guard let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return "/" }
        return String(p[p.startIndex..<slash])
    }

    /// File extension, lowercased. Empty when the name has no dot or is a dot file.
    func extString(_ i: Int) -> String {
        let (off, len) = nameRange(i)
        guard len > 0 else { return "" }
        return stringFrom(bytes: pathBuf, offset: off, length: len).extensionLower
    }

    private func stringFrom(bytes: [UInt8], offset: Int, length: Int) -> String {
        guard length > 0 else { return "" }
        return bytes.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress! + offset
            return String(decoding: UnsafeBufferPointer(start: p, count: length), as: UTF8.self)
        }
    }

    // MARK: - Ordering

    /// -1 / 0 / 1 lexicographic comparison of two indexed paths.
    @inline(__always)
    func comparePaths(_ a: Int, _ b: Int) -> Int {
        entries.withUnsafeBufferPointer { eb in
            pathBuf.withUnsafeBufferPointer { pb in
                pathCompare(pb.baseAddress!, eb[a], eb[b])
            }
        }
    }

    /// First entry whose path is >= `key` (a C string without NUL).
    func lowerBound(_ key: UnsafeBufferPointer<UInt8>) -> Int {
        var lo = 0, hi = entries.count
        entries.withUnsafeBufferPointer { eb in
            pathBuf.withUnsafeBufferPointer { pb in
                let base = pb.baseAddress!
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if pathCompareBytes(base, eb[mid], key) < 0 { lo = mid + 1 } else { hi = mid }
                }
            }
        }
        return lo
    }

    func lowerBound(_ key: [UInt8]) -> Int {
        key.withUnsafeBufferPointer { lowerBound($0) }
    }

    func range(ofPrefix prefix: [UInt8]) -> Range<Int> {
        let lo = lowerBound(prefix)
        var hi = lo
        entries.withUnsafeBufferPointer { eb in
            pathBuf.withUnsafeBufferPointer { pb in
                let base = pb.baseAddress!
                while hi < eb.count {
                    let e = eb[hi]
                    if !pathHasPrefix(base, e, prefix) { break }
                    hi += 1
                }
            }
        }
        return lo..<hi
    }

    func indexOfPath(_ path: [UInt8]) -> Int? {
        let i = lowerBound(path)
        guard i < entries.count else { return nil }
        let hit = entries.withUnsafeBufferPointer { eb in
            pathBuf.withUnsafeBufferPointer { pb in
                pathCompareBytes(pb.baseAddress!, eb[i], path.withUnsafeBufferPointer { $0 }) == 0
            }
        }
        return hit ? i : nil
    }

    func sortEntries() {
        pathBuf.withUnsafeBufferPointer { pb in
            let base = pb.baseAddress!
            entries.sort { pathCompare(base, $0, $1) < 0 }
        }
    }

    /// Linear integrity check used when a cached index is loaded: the whole
    /// engine depends on entries being strictly ascending by path.
    /// Returns true when a repair was applied.
    @discardableResult
    func repairOrder() -> Bool {
        guard entries.count > 1 else { return false }
        var ordered = true
        pathBuf.withUnsafeBufferPointer { pb in
            guard let base = pb.baseAddress else { return }
            var i = 1
            while i < entries.count {
                if pathCompare(base, entries[i - 1], entries[i]) >= 0 { ordered = false; break }
                i += 1
            }
        }
        if ordered { return false }
        sortEntries()
        _ = dedupeAdjacentEntries(pathBuf: &pathBuf, entries: &entries)
        recomputeStats()
        return true
    }

    func recomputeStats() {
        var files = 0, folders = 0
        var bytes: Int64 = 0
        for e in entries {
            if e.isDir { folders += 1 } else { files += 1; bytes += e.size }
        }
        stats.files = files
        stats.folders = folders
        stats.totalBytes = bytes
    }

    // MARK: - Mutation

    /// Append one record. `path` must be NUL terminated at `pathLen`.
    @inline(__always)
    func append(path: UnsafePointer<UInt8>, pathLen: Int, nameLen: Int, size: Int64,
                mtime: Int32, btime: Int32, flags: UInt8) {
        var e = FSEntry()
        e.pathOff = UInt32(pathBuf.count)
        e.pathLen = UInt32(pathLen)
        e.nameLen = UInt16(min(nameLen, Int(UInt16.max)))
        e.flags = flags
        e.size = size
        e.mtime = mtime
        e.btime = btime
        pathBuf.append(contentsOf: UnsafeBufferPointer(start: path, count: pathLen))
        pathBuf.append(0)
        entries.append(e)
    }
}

/// Drops adjacent duplicate paths (input must be path sorted), keeping the last
/// record of each run so the freshest metadata wins. Returns how many were removed.
@discardableResult
func dedupeAdjacentEntries(pathBuf: inout [UInt8], entries: inout [FSEntry]) -> Int {
    guard entries.count > 1 else { return 0 }
    var keep = [Bool](repeating: true, count: entries.count)
    var removed = 0
    pathBuf.withUnsafeBufferPointer { pb in
        guard let base = pb.baseAddress else { return }
        var i = 0
        while i < entries.count {
            var j = i + 1
            while j < entries.count && pathCompare(base, entries[i], entries[j]) == 0 { j += 1 }
            if j - i > 1 {
                for k in i..<(j - 1) { keep[k] = false }
                removed += (j - i - 1)
            }
            i = j
        }
    }
    guard removed > 0 else { return 0 }
    var outBuf = [UInt8]()
    outBuf.reserveCapacity(pathBuf.count)
    var outEntries = [FSEntry]()
    outEntries.reserveCapacity(entries.count - removed)
    pathBuf.withUnsafeBufferPointer { pb in
        guard let base = pb.baseAddress else { return }
        for (i, e) in entries.enumerated() where keep[i] {
            let off = Int(e.pathOff), len = Int(e.pathLen)
            outBuf.append(contentsOf: UnsafeBufferPointer(start: base + off, count: len))
            outBuf.append(0)
            var copy = e
            copy.pathOff = UInt32(outBuf.count - len - 1)
            outEntries.append(copy)
        }
    }
    pathBuf = outBuf
    entries = outEntries
    return removed
}

// MARK: - Raw byte helpers (hot path, no bounds checks)

@inline(__always)
func pathCompare(_ pb: UnsafePointer<UInt8>, _ a: FSEntry, _ b: FSEntry) -> Int {
    let la = Int(a.pathLen), lb = Int(b.pathLen)
    let n = min(la, lb)
    if n > 0 {
        let r = memcmp(pb + Int(a.pathOff), pb + Int(b.pathOff), n)
        if r != 0 { return r < 0 ? -1 : 1 }
    }
    if la == lb { return 0 }
    return la < lb ? -1 : 1
}

/// Same comparison but for two entries that live in *different* buffers
/// (used by the parallel merge of worker slices).
@inline(__always)
func pathCompare2(_ ba: UnsafePointer<UInt8>, _ a: FSEntry,
                  _ bb: UnsafePointer<UInt8>, _ b: FSEntry) -> Int {
    let la = Int(a.pathLen), lb = Int(b.pathLen)
    let n = min(la, lb)
    if n > 0 {
        let r = memcmp(ba + Int(a.pathOff), bb + Int(b.pathOff), n)
        if r != 0 { return r < 0 ? -1 : 1 }
    }
    if la == lb { return 0 }
    return la < lb ? -1 : 1
}

@inline(__always)
func pathCompareBytes(_ pb: UnsafePointer<UInt8>, _ a: FSEntry, _ key: UnsafeBufferPointer<UInt8>) -> Int {    let la = Int(a.pathLen), lb = key.count
    let n = min(la, lb)
    if n > 0 {
        let r = memcmp(pb + Int(a.pathOff), key.baseAddress!, n)
        if r != 0 { return r < 0 ? -1 : 1 }
    }
    if la == lb { return 0 }
    return la < lb ? -1 : 1
}

/// True when the entry's path starts with `prefix` (byte exact).
@inline(__always)
func pathHasPrefix(_ pb: UnsafePointer<UInt8>, _ e: FSEntry, _ prefix: [UInt8]) -> Bool {
    let n = prefix.count
    if Int(e.pathLen) < n { return false }
    return prefix.withUnsafeBufferPointer { p in
        memcmp(pb + Int(e.pathOff), p.baseAddress!, n) == 0
    }
}

extension String {
    /// Lowercased file extension without the dot ("" when there is none).
    var extensionLower: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return "" }
        let e = self[index(after: dot)...]
        if e.isEmpty { return "" }
        return e.lowercased()
    }

    var pathBytes: [UInt8] { Array(utf8) }
}

/// Case insensitive ASCII byte compare used by glob/diacritic helpers.
@inline(__always)
func asciiLower(_ b: UInt8) -> UInt8 {
    (b >= 0x41 && b <= 0x5A) ? b &+ 32 : b
}

@inline(__always)
func isWordByte(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
}
