import Foundation

/// Immutable snapshot of search results. Owns a compact copy of the matched
/// paths so the UI can render rows lazily while the live index keeps mutating.
struct ResultSet {
    var blob: [UInt8] = []
    var entries: [FSEntry] = []
    var totalMatches: Int = 0
    var truncated = false
    var duration: TimeInterval = 0
    var query = ""
    var error: String?

    var count: Int { entries.count }

    func path(_ i: Int) -> String {
        let e = entries[i]
        return decode(Int(e.pathOff), Int(e.pathLen))
    }

    func name(_ i: Int) -> String {
        let e = entries[i]
        return decode(Int(e.nameOff), Int(e.nameLen))
    }

    func parentPath(_ i: Int) -> String {
        let e = entries[i]
        var end = Int(e.pathOff) + Int(e.pathLen) - Int(e.nameLen)
        if end > Int(e.pathOff) && blob[end - 1] == 0x2F { end -= 1 }
        if end <= Int(e.pathOff) { return "/" }
        return decode(Int(e.pathOff), end - Int(e.pathOff))
    }

    func ext(_ i: Int) -> String {
        let e = entries[i]
        let nameStart = Int(e.nameOff)
        let nameLen = Int(e.nameLen)
        guard nameLen > 1 else { return "" }
        var i2 = nameStart + nameLen - 1
        while i2 > nameStart {
            if blob[i2] == 0x2E {
                return decode(i2 + 1, nameStart + nameLen - i2 - 1).lowercased()
            }
            i2 -= 1
        }
        return ""
    }

    func url(_ i: Int) -> URL {
        URL(fileURLWithPath: path(i))
    }

    private func decode(_ offset: Int, _ length: Int) -> String {
        guard length > 0 else { return "" }
        return blob.withUnsafeBufferPointer { buf in
            String(decoding: UnsafeBufferPointer(start: buf.baseAddress! + offset, count: length),
                   as: UTF8.self)
        }
    }

    /// Re-sorts in place (the blob is untouched, so offsets stay valid).
    mutating func sortInPlace(field: SortField, ascending: Bool) {
        blob.withUnsafeBufferPointer { pb in
            guard let base = pb.baseAddress else { return }
            entries.sort { a, b in
                let c = compareEntries(base, a, b, field: field)
                return ascending ? c < 0 : c > 0
            }
        }
    }
}

@inline(__always)
func compareEntries(_ pb: UnsafePointer<UInt8>, _ a: FSEntry, _ b: FSEntry, field: SortField) -> Int {
    switch field {
    case .size:
        if a.size != b.size { return a.size < b.size ? -1 : 1 }
    case .modified:
        if a.mtime != b.mtime { return a.mtime < b.mtime ? -1 : 1 }
    case .created:
        if a.btime != b.btime { return a.btime < b.btime ? -1 : 1 }
    case .kind:
        let ad = a.isDir ? 0 : 1, bd = b.isDir ? 0 : 1
        if ad != bd { return ad < bd ? -1 : 1 }
    case .name, .ext, .path:
        break
    }
    if field == .ext {
        let c = compareExt(pb, a, b)
        if c != 0 { return c }
    }
    let useName = (field == .name || field == .ext || field == .kind)
    let c = useName ? compareName(pb, a, b) : pathCompare(pb, a, b)
    if c != 0 { return c }
    if field != .path {
        let p = pathCompare(pb, a, b)
        if p != 0 { return p }
    }
    return 0
}

@inline(__always)
func compareName(_ pb: UnsafePointer<UInt8>, _ a: FSEntry, _ b: FSEntry) -> Int {
    let la = Int(a.nameLen), lb = Int(b.nameLen)
    let n = min(la, lb)
    let pa = pb + Int(a.nameOff), pb2 = pb + Int(b.nameOff)
    var i = 0
    while i < n {
        let x = asciiLower(pa[i]), y = asciiLower(pb2[i])
        if x != y { return x < y ? -1 : 1 }
        i += 1
    }
    if la == lb { return 0 }
    return la < lb ? -1 : 1
}

@inline(__always)
func extRange(_ pb: UnsafePointer<UInt8>, _ e: FSEntry) -> (Int, Int) {
    let nameStart = Int(e.nameOff)
    let nameLen = Int(e.nameLen)
    guard nameLen > 1 else { return (0, 0) }
    var i = nameStart + nameLen - 1
    while i > nameStart {
        if pb[i] == 0x2E { return (i + 1, nameStart + nameLen - i - 1) }
        i -= 1
    }
    return (0, 0)
}

@inline(__always)
func compareExt(_ pb: UnsafePointer<UInt8>, _ a: FSEntry, _ b: FSEntry) -> Int {
    let (ao, al) = extRange(pb, a)
    let (bo, bl) = extRange(pb, b)
    let n = min(al, bl)
    var i = 0
    while i < n {
        let x = asciiLower(pb[ao + i]), y = asciiLower(pb[bo + i])
        if x != y { return x < y ? -1 : 1 }
        i += 1
    }
    if al == bl { return 0 }
    return al < bl ? -1 : 1
}

// MARK: - Program evaluation

/// Runs the compiled program (RPN) against one entry.
@inline(__always)
func evalProgram(_ insts: [Inst],
                 _ pb: UnsafePointer<UInt8>,
                 _ e: FSEntry,
                 _ litBuf: UnsafePointer<UInt8>,
                 _ spans: UnsafeBufferPointer<LitSpan>,
                 _ terms: UnsafeBufferPointer<LitTerm>,
                 _ extMatchers: [ExtMatcher],
                 _ regexes: [NSRegularExpression],
                 _ stack: UnsafeMutablePointer<Bool>) -> Bool {
    var sp = 0
    for inst in insts {
        switch inst {
        case .lit(let termIdx, let inPath, let wholeWord, let anchor):
            let term = terms[Int(termIdx)]
            let nameOff = Int(e.nameOff)
            let nameLen = Int(e.nameLen)
            let pathLen = Int(e.pathLen)
            var hay: UnsafePointer<UInt8>
            var hayLen: Int
            if inPath {
                if anchor == 4 {
                    // parent: only the directory portion, without the final slash.
                    let dirLen = pathLen - nameLen
                    if dirLen <= 1 {
                        stack[sp] = false; sp += 1
                        continue
                    }
                    hay = pb + Int(e.pathOff)
                    hayLen = dirLen - 1
                } else {
                    hay = pb + Int(e.pathOff)
                    hayLen = pathLen
                }
            } else {
                hay = pb + nameOff
                hayLen = nameLen
            }
            var matched = false
            var v = term.first
            while v < term.first + term.count {
                let span = spans[Int(v)]
                if byteContains(hay, hayLen, litBuf + Int(span.off), Int(span.len),
                                caseSensitive: term.caseSensitive, wholeWord: wholeWord,
                                anchor: anchor) {
                    matched = true
                    break
                }
                v += 1
            }
            stack[sp] = matched; sp += 1
        case .glob(let off, let len, let inPath, let caseSensitive):
            let hay = inPath ? pb + Int(e.pathOff) : pb + Int(e.nameOff)
            let hayLen = inPath ? Int(e.pathLen) : Int(e.nameLen)
            let ok = globMatch(litBuf + Int(off), Int(len), hay, hayLen, caseSensitive: caseSensitive)
            stack[sp] = ok; sp += 1
        case .regex(let idx, let inPath):
            let hay = inPath ? pb + Int(e.pathOff) : pb + Int(e.nameOff)
            let hayLen = inPath ? Int(e.pathLen) : Int(e.nameLen)
            let text = String(decoding: UnsafeBufferPointer(start: hay, count: hayLen), as: UTF8.self)
            let range = NSRange(location: 0, length: (text as NSString).length)
            let ok = idx < regexes.count &&
                regexes[Int(idx)].firstMatch(in: text, options: [], range: range) != nil
            stack[sp] = ok; sp += 1
        case .ext(let idx, let negate):
            let ok: Bool
            if idx < extMatchers.count {
                ok = extMatchers[Int(idx)].matches(name: pb + Int(e.nameOff), nameLen: Int(e.nameLen))
            } else {
                ok = false
            }
            stack[sp] = negate ? !ok : ok; sp += 1
        case .sizeRange(let lo, let hi):
            stack[sp] = !e.isDir && e.size >= lo && e.size <= hi; sp += 1
        case .mtimeRange(let lo, let hi):
            stack[sp] = e.mtime >= lo && e.mtime <= hi; sp += 1
        case .btimeRange(let lo, let hi):
            stack[sp] = e.btime >= lo && e.btime <= hi; sp += 1
        case .depthRange(let lo, let hi, let depthBase):
            var slashes: Int32 = 0
            var i = 0
            let n = Int(e.pathLen)
            let basePtr = pb + Int(e.pathOff)
            while i < n {
                if basePtr[i] == 0x2F { slashes += 1 }
                i += 1
            }
            let depth = max(0, slashes - depthBase)
            stack[sp] = depth >= lo && depth <= hi; sp += 1
        case .isDir(let want):
            stack[sp] = e.isDir == want; sp += 1
        case .hidden(let want):
            stack[sp] = e.isHidden == want; sp += 1
        case .symlink(let want):
            stack[sp] = e.isSymlink == want; sp += 1
        case .package(let want):
            stack[sp] = e.isPackage == want; sp += 1
        case .executable(let want):
            stack[sp] = ((e.flags & EntryFlag.isExecutable) != 0) == want; sp += 1
        case .andOp:
            let b = stack[sp - 1], a = stack[sp - 2]
            sp -= 1
            stack[sp - 1] = a && b
        case .orOp:
            let b = stack[sp - 1], a = stack[sp - 2]
            sp -= 1
            stack[sp - 1] = a || b
        case .notOp:
            stack[sp - 1] = !stack[sp - 1]
        }
    }
    return sp > 0 ? stack[0] : true
}

// MARK: - Engine

enum SearchEngine {

    /// Scans the whole index and returns the best `maxResults` matching rows.
    static func run(index: FileIndex, parsed: ParsedQuery, options: QueryOptions,
                    text: String) -> ResultSet {
        let t0 = Date()
        var result = ResultSet()
        result.query = text

        let count = index.count
        guard count > 0 else {
            result.duration = Date().timeIntervalSince(t0)
            return result
        }

        let depth = max(8, parsed.stackDepth)
        let stack = UnsafeMutablePointer<Bool>.allocate(capacity: depth)
        defer { stack.deallocate() }

        let insts = parsed.insts
        let emptyProgram = insts.isEmpty
        var hits = [Int32]()
        hits.reserveCapacity(min(count, 4096))

        let sortField = parsed.sort ?? options.sort
        let ascending = parsed.ascending ?? options.ascending
        let limit = max(1, options.maxResults)

        index.pathBuf.withUnsafeBufferPointer { pbBuf in
            guard let pb = pbBuf.baseAddress else { return }
            index.entries.withUnsafeBufferPointer { eb in
                parsed.litBuf.withUnsafeBufferPointer { lit in
                    parsed.litSpans.withUnsafeBufferPointer { spans in
                        parsed.litTerms.withUnsafeBufferPointer { terms in
                            let litBase = lit.baseAddress ?? pb
                            for i in 0..<eb.count {
                                if emptyProgram {
                                    hits.append(Int32(i))
                                    continue
                                }
                                if evalProgram(insts, pb, eb[i], litBase, spans, terms,
                                               parsed.extMatchers, parsed.regexes, stack) {
                                    hits.append(Int32(i))
                                }
                            }
                        }
                    }
                }
                result.totalMatches = hits.count

                @inline(__always) func less(_ a: Int32, _ b: Int32) -> Bool {
                    let c = compareEntries(pb, eb[Int(a)], eb[Int(b)], field: sortField)
                    return ascending ? c < 0 : c > 0
                }

                var selected: [Int32]
                if sortField == .path && ascending && hits.count > limit {
                    selected = Array(hits[0..<limit])
                    result.truncated = true
                } else if hits.count <= limit {
                    selected = hits
                    if selected.count > 1 { selected.sort(by: less) }
                } else {
                    result.truncated = true
                    selected = topK(hits, limit, pb, eb, less)
                }

                var blob = [UInt8]()
                blob.reserveCapacity(selected.count * 64)
                var rows = [FSEntry]()
                rows.reserveCapacity(selected.count)
                for idx in selected {
                    var e = eb[Int(idx)]
                    let start = Int(e.pathOff)
                    let len = Int(e.pathLen)
                    e.pathOff = UInt32(blob.count)
                    blob.append(contentsOf: UnsafeBufferPointer(start: pb + start, count: len))
                    blob.append(0)
                    rows.append(e)
                }
                result.blob = blob
                result.entries = rows
            }
        }
        result.duration = Date().timeIntervalSince(t0)
        return result
    }

    /// Bounded selection of the best `k` hits (avoids sorting millions of rows).
    static func topK(_ hits: [Int32], _ k: Int, _ pb: UnsafePointer<UInt8>,
                     _ eb: UnsafeBufferPointer<FSEntry>, _ less: (Int32, Int32) -> Bool) -> [Int32] {
        guard k < hits.count else {
            var all = hits
            all.sort(by: less)
            return all
        }
        var heap = Array(hits[0..<k])
        func siftDown(_ start: Int, _ n: Int) {
            var root = start
            while true {
                let left = 2 * root + 1
                if left >= n { return }
                var swapIdx = root
                if less(heap[swapIdx], heap[left]) { swapIdx = left }
                if left + 1 < n && less(heap[swapIdx], heap[left + 1]) { swapIdx = left + 1 }
                if swapIdx == root { return }
                heap.swapAt(root, swapIdx)
                root = swapIdx
            }
        }
        var i = k / 2 - 1
        while i >= 0 {
            siftDown(i, k)
            i -= 1
        }
        for j in k..<hits.count where less(hits[j], heap[0]) {
            heap[0] = hits[j]
            siftDown(0, k)
        }
        heap.sort(by: less)
        return heap
    }
}
