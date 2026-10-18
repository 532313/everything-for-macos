import Foundation

// verify — loads an index cache and checks its structural invariants.
// Usage: verify <index-dir> [query ...]

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let args = Array(CommandLine.arguments.dropFirst())
guard let dir = args.first else {
    log("usage: verify <index-dir> [query ...]")
    exit(2)
}
let db = IndexDatabase(indexDirectory: URL(fileURLWithPath: dir))
guard db.loadCache() else {
    log("FAILED to load cache at \(dir)")
    exit(1)
}
let index = db.currentIndex()
log("load status: \(db.status.message.isEmpty ? "(clean)" : db.status.message)")
log("loaded: \(index.count) objects (\(index.stats.files) files, \(index.stats.folders) folders), pathBuf=\(index.pathBuf.count) bytes")

var failures = 0
var checks = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        failures += 1
        log("  FAIL \(name) \(detail())")
    }
}

// 1. every record points inside the buffer with a sane layout
var badRanges = 0, badNames = 0, badNul = 0
index.pathBuf.withUnsafeBufferPointer { pb in
    let base = pb.baseAddress!
    for e in index.entries {
        let off = Int(e.pathOff), len = Int(e.pathLen), nameLen = Int(e.nameLen)
        if off < 0 || len <= 0 || off + len > pb.count || nameLen <= 0 || nameLen > len {
            badRanges += 1
            continue
        }
        if base[off] != 0x2F { badRanges += 1; continue }
        if base[off + len - 1] == 0x2F { badRanges += 1 }
        let nameStart = off + len - nameLen
        if nameStart > 0 && base[nameStart - 1] != 0x2F { badNames += 1 }
        if base[off + len] != 0 { badNul += 1 }   // NUL terminator after the path
    }
}
check("all records have in-range offsets/lengths", badRanges == 0, "(\(badRanges) bad)")
check("every name is the last path component", badNames == 0, "(\(badNames) bad)")
check("path buffer NUL terminators intact", badNul == 0, "(\(badNul) bad)")

// 2. strictly ascending by path (the invariant the whole index relies on)
var inversions = 0
var duplicates = 0
for i in 1..<max(1, index.count) {
    let c = index.comparePaths(i - 1, i)
    if c > 0 { inversions += 1 }
    if c == 0 { duplicates += 1 }
}
check("entries sorted ascending by path", inversions == 0, "(\(inversions) inversions)")
check("no duplicate paths", duplicates == 0, "(\(duplicates) duplicates)")

// 3. binary search agrees with the sorted order on random samples
var lookupMisses = 0
let sampleCount = min(2000, index.count)
for k in 0..<sampleCount {
    let i = (k * 7919) % max(1, index.count)
    let path = index.pathString(i)
    if let found = index.indexOfPath(Array(path.utf8)), found == i {
        continue
    }
    lookupMisses += 1
}
check("binary search finds sampled paths", lookupMisses == 0, "(\(lookupMisses) misses)")

// 4. subtree range lookups are contiguous and correct
var rangeBad = 0
let dirSamples = min(200, index.count)
for k in 0..<dirSamples {
    let i = (k * 104729) % max(1, index.count)
    guard index.entries[i].isDir else { continue }
    let path = Array(index.pathString(i).utf8)
    let range = index.range(ofPrefix: path)
    if range.isEmpty || range.lowerBound > i || range.upperBound <= i { rangeBad += 1 }
}
check("subtree prefix ranges contain their own record", rangeBad == 0, "(\(rangeBad) bad)")

// 5. name/path accessors never trap and never return empty paths
var emptyPaths = 0
for k in stride(from: 0, to: index.count, by: max(1, index.count / 5000)) {
    if index.pathString(k).isEmpty || index.nameString(k).isEmpty { emptyPaths += 1 }
}
check("accessors return non-empty strings", emptyPaths == 0, "(\(emptyPaths) empty)")

// 6. optional queries
var options = QueryOptions()
options.maxResults = 20
options.rootPath = "/"
for query in args.dropFirst() {
    let started = Date()
    let result = db.search(text: query, options: options)
    let ms = Date().timeIntervalSince(started) * 1000
    log(String(format: "query '%@': %d of %d matches in %.0f ms", query, result.count, result.totalMatches, ms))
    for i in 0..<min(5, result.count) {
        log("    \(result.path(i))")
    }
}

log("checks: \(checks)  failures: \(failures)")
if failures == 0 { log("INDEX OK") } else { exit(1) }
