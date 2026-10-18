import Foundation

// MARK: - Options

enum SortField: Int, CaseIterable {
    case name = 0
    case path = 1
    case size = 2
    case modified = 3
    case created = 4
    case ext = 5
    case kind = 6

    var title: String {
        switch self {
        case .name: return "Name"
        case .path: return "Path"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .ext: return "Extension"
        case .kind: return "Type"
        }
    }

    /// Column key accepted by `sort:` in the search box.
    static func from(_ key: String) -> SortField? {
        switch key.lowercased() {
        case "name", "filename", "file": return .name
        case "path", "fullpath": return .path
        case "size": return .size
        case "dm", "datemodified", "modified", "date", "mtime": return .modified
        case "dc", "datecreated", "created", "btime": return .created
        case "ext", "extension", "type", "kind": return .ext
        default: return nil
        }
    }
}

struct QueryOptions {
    var matchCase = false
    var matchWholeWord = false
    var matchPath = false
    var matchDiacritics = true
    var useRegex = false
    var filter: FilterKind = .all
    var sort: SortField = .name
    var ascending = true
    var showHidden = false
    var maxResults = 100_000
    /// Indexed root, used to make `depth:` relative (like Everything does
    /// relative to the volume root).
    var rootPath = "/"
}

// MARK: - Compiled program

enum Inst {
    case lit(term: Int32, inPath: Bool, wholeWord: Bool, anchor: UInt8)
    case glob(off: Int32, len: Int32, inPath: Bool, caseSensitive: Bool)
    case regex(idx: Int32, inPath: Bool)
    case ext(idx: Int32, negate: Bool)
    case sizeRange(min: Int64, max: Int64)
    case mtimeRange(min: Int32, max: Int32)
    case btimeRange(min: Int32, max: Int32)
    case depthRange(min: Int32, max: Int32, base: Int32)
    case isDir(Bool)
    case hidden(Bool)
    case symlink(Bool)
    case package(Bool)
    case executable(Bool)
    case andOp
    case orOp
    case notOp
}

/// One literal search pattern, compiled to one or more byte variants
/// (exact, NFC, NFD, lowercased) so that matching never allocates.
struct LitSpan {
    var off: Int32
    var len: Int32
}

struct LitTerm {
    var first: Int32
    var count: Int32
    var caseSensitive: Bool
}

/// Extension set compiled to packed 64-bit keys for branch-free lookups.
struct ExtMatcher {
    var packed: Set<UInt64> = []
    var long: [[UInt8]] = []
    var matchNoExt = false

    static func pack(_ bytes: [UInt8], length: Int) -> UInt64 {
        var key = UInt64(length) << 56
        var i = 0
        while i < min(length, 7) {
            key |= UInt64(bytes[i]) << UInt64(8 * (6 - i))
            i += 1
        }
        return key
    }

    mutating func add(_ ext: String) {
        let lower = ext.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return }
        if lower == "$noext" || lower == "-" { matchNoExt = true; return }
        var bytes = Array(lower.utf8)
        if bytes.count > 7 {
            long.append(bytes)
            return
        }
        packed.insert(ExtMatcher.pack(bytes, length: bytes.count))
        bytes.removeAll()
    }

    /// Key of the extension of `name`, or nil when the name has no extension.
    @inline(__always)
    static func keyOf(name: UnsafePointer<UInt8>, nameLen: Int) -> UInt64? {
        guard nameLen > 1 else { return nil }
        var i = nameLen - 1
        while i > 0 {
            if name[i] == 0x2E {
                let extLen = nameLen - i - 1
                if extLen == 0 || extLen > 7 { return nil }
                var key = UInt64(extLen) << 56
                var k = 0
                while k < extLen {
                    let b = asciiLower(name[i + 1 + k])
                    key |= UInt64(b) << UInt64(8 * (6 - k))
                    k += 1
                }
                return key
            }
            i -= 1
        }
        return nil
    }

    @inline(__always)
    func matches(name: UnsafePointer<UInt8>, nameLen: Int) -> Bool {
        if let key = ExtMatcher.keyOf(name: name, nameLen: nameLen) {
            if packed.contains(key) { return true }
            if !long.isEmpty {
                var i = nameLen - 1
                var dot = -1
                while i > 0 {
                    if name[i] == 0x2E { dot = i; break }
                    i -= 1
                }
                if dot > 0 {
                    let extLen = nameLen - dot - 1
                    for candidate in long {
                        if candidate.count != extLen { continue }
                        var k = 0
                        var ok = true
                        while k < extLen {
                            if asciiLower(name[dot + 1 + k]) != candidate[k] { ok = false; break }
                            k += 1
                        }
                        if ok { return true }
                    }
                }
            }
            return false
        }
        return matchNoExt
    }
}

struct ParsedQuery {
    var insts: [Inst] = []
    var litBuf: [UInt8] = []
    var litSpans: [LitSpan] = []
    var litTerms: [LitTerm] = []
    var extMatchers: [ExtMatcher] = []
    var regexes: [NSRegularExpression] = []
    var sort: SortField?
    var ascending: Bool?
    var explicitHidden = false
    var explicitHiddenValue = false
    var isEmpty: Bool { insts.isEmpty }

    /// Scratch space reused while matching (max expression depth).
    var stackDepth: Int = 32

    /// Appends the byte variants of `pattern` and returns the term index.
    ///
    /// Everything compares canonically insensitive by default, so a non-ASCII
    /// pattern gets both its NFC and NFD encodings. All comparisons below are
    /// done on raw bytes because Swift's `String ==` treats NFC and NFD as
    /// equal and would silently drop one of the variants.
    mutating func addLiteral(_ pattern: String, caseSensitive: Bool, diacritics: Bool)
        -> (LitTerm, Int32, Int32) {
        var candidates: [String] = [pattern]
        if diacritics && pattern.utf8.contains(where: { $0 >= 0x80 }) {
            candidates.append(pattern.precomposedStringWithCanonicalMapping)
            candidates.append(pattern.decomposedStringWithCanonicalMapping)
        }
        var base: [[UInt8]] = []
        var seenBase = Set<[UInt8]>()
        for candidate in candidates {
            let bytes = Array(candidate.utf8)
            if seenBase.insert(bytes).inserted { base.append(bytes) }
        }
        var all: [[UInt8]] = caseSensitive ? base : base.map { bytes in bytes.map(asciiLower) }
        var seen = Set<[UInt8]>()
        all = all.filter { seen.insert($0).inserted }

        let first = Int32(litSpans.count)
        var firstOff: Int32 = Int32(litBuf.count)
        var firstLen: Int32 = 0
        for (i, bytes) in all.enumerated() {
            let off = Int32(litBuf.count)
            litBuf.append(contentsOf: bytes)
            litSpans.append(LitSpan(off: off, len: Int32(bytes.count)))
            if i == 0 { firstOff = off; firstLen = Int32(bytes.count) }
        }
        let term = LitTerm(first: first, count: Int32(all.count), caseSensitive: caseSensitive)
        litTerms.append(term)
        return (term, firstOff, firstLen)
    }

    /// ANDs another program onto this one (no-op when either side is empty).
    mutating func combine(_ sub: ParsedQuery) {
        guard !sub.insts.isEmpty else { return }
        let empty = insts.isEmpty
        merge(from: sub)
        if !empty { insts.append(.andOp) }
    }

    /// Appends another program, remapping its table indices.
    mutating func merge(from sub: ParsedQuery) {
        let litBase = Int32(litTerms.count)
        let spanBase = Int32(litSpans.count)
        let byteBase = Int32(litBuf.count)
        let extBase = Int32(extMatchers.count)
        let regexBase = Int32(regexes.count)
        for inst in sub.insts {
            switch inst {
            case .lit(let t, let inPath, let ww, let anchor):
                insts.append(.lit(term: t + litBase, inPath: inPath, wholeWord: ww, anchor: anchor))
            case .glob(let off, let len, let inPath, let cs):
                insts.append(.glob(off: off + byteBase, len: len, inPath: inPath, caseSensitive: cs))
            case .ext(let i, let n):
                insts.append(.ext(idx: i + extBase, negate: n))
            case .regex(let i, let p):
                insts.append(.regex(idx: i + regexBase, inPath: p))
            default:
                insts.append(inst)
            }
        }
        for s in sub.litSpans { litSpans.append(LitSpan(off: s.off + byteBase, len: s.len)) }
        for t in sub.litTerms {
            litTerms.append(LitTerm(first: t.first + spanBase, count: t.count,
                                    caseSensitive: t.caseSensitive))
        }
        litBuf.append(contentsOf: sub.litBuf)
        extMatchers.append(contentsOf: sub.extMatchers)
        regexes.append(contentsOf: sub.regexes)
        if let s = sub.sort { sort = s }
        if let a = sub.ascending { ascending = a }
        explicitHidden = explicitHidden || sub.explicitHidden
    }
}

// MARK: - Byte utilities used by the matcher

/// Case-insensitive (ASCII) substring search.
@inline(__always)
func byteContains(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                  _ needle: UnsafePointer<UInt8>, _ needleLen: Int,
                  caseSensitive: Bool, wholeWord: Bool, anchor: UInt8) -> Bool {
    if needleLen == 0 { return true }
    if needleLen > hayLen { return false }
    var start = 0
    let last = hayLen - needleLen
    while start <= last {
        var k = 0
        while k < needleLen {
            let h = hay[start + k]
            let n = needle[k]
            let equal = caseSensitive ? (h == n) : (h == n || asciiLower(h) == n)
            if !equal { break }
            k += 1
        }
        if k == needleLen {
            if anchor == 1 && start != 0 { return false }
            if anchor == 2 && start != last { return false }
            if anchor == 3 && start != 0 { return false }
            if !wholeWord || wordBounded(hay, hayLen, start, needleLen) { return true }
        }
        if anchor == 1 || anchor == 3 { return false }
        start += 1
    }
    return false
}

@inline(__always)
func wordBounded(_ hay: UnsafePointer<UInt8>, _ hayLen: Int, _ start: Int, _ len: Int) -> Bool {
    if start > 0 && isWordByte(hay[start - 1]) { return false }
    let end = start + len
    if end < hayLen && isWordByte(hay[end]) { return false }
    return true
}

/// Wildcard match: `*` any run, `?` one byte. Case-insensitive when asked.
func globMatch(_ pattern: UnsafePointer<UInt8>, _ plen: Int,
               _ text: UnsafePointer<UInt8>, _ tlen: Int,
               caseSensitive: Bool) -> Bool {
    var p = 0, t = 0
    var starP = -1, starT = 0
    while t < tlen {
        if p < plen && (pattern[p] == 0x3F || byteEq(pattern[p], text[t], caseSensitive)) {
            p += 1; t += 1
        } else if p < plen && pattern[p] == 0x2A {
            starP = p; starT = t; p += 1
        } else if starP >= 0 {
            p = starP + 1; starT += 1; t = starT
        } else {
            return false
        }
    }
    while p < plen && pattern[p] == 0x2A { p += 1 }
    return p == plen
}

@inline(__always)
func byteEq(_ a: UInt8, _ b: UInt8, _ caseSensitive: Bool) -> Bool {
    if caseSensitive { return a == b }
    return a == b || asciiLower(a) == b
}

// MARK: - Parser

private enum Tok {
    case word(String, quoted: Bool)
    case lparen
    case rparen
    case groupOpen
    case groupClose
    case orOp
    case notOp
}

private indirect enum Node {
    case inst(Inst)
    case and(Node, Node)
    case or(Node, Node)
    case not(Node)
    case nothing
}

enum QueryParser {

    static let modifierNames: Set<String> = [
        "ext", "file", "files", "folder", "folders", "dir", "dirs", "path", "nopath",
        "size", "dm", "datemodified", "dc", "datecreated", "da", "dateaccessed",
        "depth", "parent", "regex", "wfn", "startwith", "endwith", "case", "nocase",
        "wholeword", "nowholeword", "matchpath", "nomatchpath", "diacritics",
        "nodiacritics", "sort", "ascending", "descending", "asc", "desc", "hidden",
        "nohidden", "symlink", "nosymlink", "package", "nopackage", "exec",
        "executable", "noexec", "empty", "notempty", "type", "vol", "volume",
        "attrib", "nodiacritics", "utf8", "ansi", "len", "child", "childcount",
        "containerfile", "containerfilename", "infolder"
    ]

    static func parse(_ text: String, options: QueryOptions) -> ParsedQuery {
        var p = ParsedQuery()
        var state = State(options: options)
        let tokens = tokenize(text)
        var i = 0
        let node = parseOr(tokens, &i, &p, &state)
        if let node = node {
            emit(node, into: &p, state: &state)
        }
        p.sort = state.sort
        p.ascending = state.ascending
        p.explicitHidden = state.explicitHidden
        p.explicitHiddenValue = state.explicitHiddenValue
        p.stackDepth = max(8, depth(node) + 4)
        return p
    }

    /// Parses the user text and ANDs the active filter (and hidden rule).
    static func compile(_ text: String, options: QueryOptions) -> ParsedQuery {
        var query = parse(text, options: options)
        if options.filter != .all, let fragment = options.filter.queryFragment {
            query.combine(parse(fragment, options: options))
        }
        if !query.explicitHidden && !options.showHidden {
            if query.insts.isEmpty {
                query.insts.append(.hidden(false))
            } else {
                query.insts.append(.hidden(false))
                query.insts.append(.andOp)
            }
        }
        query.stackDepth = max(8, query.insts.count + 4)
        return query
    }

    private struct State {
        var caseSensitive: Bool
        var wholeWord: Bool
        var inPath: Bool
        var diacritics: Bool
        var regex: Bool
        var sort: SortField?
        var ascending: Bool?
        var explicitHidden = false
        var explicitHiddenValue = false
        var depthBase: Int32 = 0

        init(options: QueryOptions) {
            caseSensitive = options.matchCase
            wholeWord = options.matchWholeWord
            inPath = options.matchPath
            diacritics = options.matchDiacritics
            regex = options.useRegex
            let root = options.rootPath
            var slashes: Int32 = 0
            for ch in root.utf8 where ch == 0x2F { slashes += 1 }
            depthBase = (root == "/" || root.isEmpty) ? 0 : slashes
        }
    }

    private static func depth(_ n: Node?) -> Int {
        guard let n = n else { return 0 }
        switch n {
        case .nothing, .inst: return 1
        case .not(let a): return 1 + depth(a)
        case .and(let a, let b), .or(let a, let b): return 1 + max(depth(a), depth(b))
        }
    }

    // MARK: tokenizer

    private static func tokenize(_ text: String) -> [Tok] {
        let chars = Array(text)
        var out: [Tok] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" { i += 1; continue }
            switch c {
            case "|":
                out.append(.orOp); i += 1
            case "(":
                out.append(.lparen); i += 1
            case ")":
                out.append(.rparen); i += 1
            case "<":
                out.append(.groupOpen); i += 1
            case ">":
                out.append(.groupClose); i += 1
            case "!":
                out.append(.notOp); i += 1
            case "\"":
                var s = ""
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    s.append(chars[i]); i += 1
                }
                if i < chars.count { i += 1 }
                out.append(.word(s, quoted: true))
            default:
                var s = ""
                var quoted = false
                var sawColon = false
                while i < chars.count {
                    let ch = chars[i]
                    if ch == " " || ch == "\t" || ch == "\n" { break }
                    if ch == "|" || ch == "(" || ch == ")" { break }
                    if ch == "<" && s.isEmpty { break }
                    if ch == ">" && s.isEmpty { break }
                    if ch == "\"" {
                        quoted = true
                        i += 1
                        while i < chars.count && chars[i] != "\"" {
                            if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                            s.append(chars[i]); i += 1
                        }
                        if i < chars.count { i += 1 }
                        continue
                    }
                    if ch == "\\" && i + 1 < chars.count {
                        s.append(chars[i + 1]); i += 2; continue
                    }
                    if ch == ":" { sawColon = true }
                    s.append(ch); i += 1
                }
                if !s.isEmpty {
                    out.append(.word(s, quoted: quoted && !sawColon))
                }
            }
        }
        return out
    }

    // MARK: grammar

    private static func parseOr(_ tokens: [Tok], _ i: inout Int, _ p: inout ParsedQuery,
                                _ state: inout State) -> Node? {
        var left = parseAnd(tokens, &i, &p, &state)
        while i < tokens.count, case .orOp = tokens[i] {
            i += 1
            let right = parseAnd(tokens, &i, &p, &state)
            if let l = left, let r = right {
                left = .or(l, r)
            } else if let l = left {
                left = l
            } else {
                left = right
            }
        }
        return left
    }

    private static func parseAnd(_ tokens: [Tok], _ i: inout Int, _ p: inout ParsedQuery,
                                 _ state: inout State) -> Node? {
        var left: Node?
        while i < tokens.count {
            switch tokens[i] {
            case .rparen, .groupClose, .orOp:
                return left
            default:
                let right = parseUnary(tokens, &i, &p, &state)
                if let l = left, let r = right {
                    left = .and(l, r)
                } else if right != nil {
                    left = right
                }
            }
        }
        return left
    }

    private static func parseUnary(_ tokens: [Tok], _ i: inout Int, _ p: inout ParsedQuery,
                                   _ state: inout State) -> Node? {
        guard i < tokens.count else { return nil }
        if case .notOp = tokens[i] {
            i += 1
            let inner = parseUnary(tokens, &i, &p, &state)
            if let inner = inner { return .not(inner) }
            return nil
        }
        return parsePrimary(tokens, &i, &p, &state)
    }

    private static func parsePrimary(_ tokens: [Tok], _ i: inout Int, _ p: inout ParsedQuery,
                                     _ state: inout State) -> Node? {
        guard i < tokens.count else { return nil }
        switch tokens[i] {
        case .lparen, .groupOpen:
            i += 1
            let inner = parseOr(tokens, &i, &p, &state)
            while i < tokens.count {
                if case .rparen = tokens[i] { i += 1; break }
                if case .groupClose = tokens[i] { i += 1; break }
                i += 1
            }
            return inner
        case .word(let text, let quoted):
            i += 1
            return termNode(text, quoted: quoted, p: &p, state: &state)
        default:
            i += 1
            return nil
        }
    }

    // MARK: terms

    private static func termNode(_ text: String, quoted: Bool, p: inout ParsedQuery,
                                 state: inout State) -> Node? {
        guard !text.isEmpty else { return nil }
        if !quoted, let colon = text.firstIndex(of: ":") {
            let name = String(text[text.startIndex..<colon]).lowercased()
            let value = String(text[text.index(after: colon)...])
            if modifierNames.contains(name) {
                return modifierNode(name, value, p: &p, state: &state)
            }
        }
        return literalNode(text, quoted: quoted, p: &p, state: state)
    }

    private static func literalNode(_ text: String, quoted: Bool, p: inout ParsedQuery,
                                    state: State) -> Node? {
        guard !text.isEmpty else { return nil }
        let pattern = text
        if state.regex {
            do {
                let options: NSRegularExpression.Options = state.caseSensitive ? [] : [.caseInsensitive]
                let re = try NSRegularExpression(pattern: pattern, options: options)
                p.regexes.append(re)
                return .inst(.regex(idx: Int32(p.regexes.count - 1), inPath: state.inPath))
            } catch {
                // Invalid pattern: fall through to a literal search.
            }
        }
        if !quoted && (pattern.contains("*") || pattern.contains("?")) {
            let off = p.litBuf.count
            let text = state.caseSensitive ? pattern : asciiLowerString(pattern)
            let bytes = Array(text.utf8)
            p.litBuf.append(contentsOf: bytes)
            return .inst(.glob(off: Int32(off), len: Int32(bytes.count), inPath: state.inPath,
                               caseSensitive: state.caseSensitive))
        }
        let (term, _, _) = p.addLiteral(pattern, caseSensitive: state.caseSensitive,
                                        diacritics: state.diacritics)
        return .inst(.lit(term: term.first, inPath: state.inPath, wholeWord: state.wholeWord,
                          anchor: 0))
    }

    private static func modifierNode(_ name: String, _ value: String, p: inout ParsedQuery,
                                     state: inout State) -> Node? {
        switch name {
        case "case":
            state.caseSensitive = true
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "nocase":
            state.caseSensitive = false
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "wholeword":
            state.wholeWord = true
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "nowholeword":
            state.wholeWord = false
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "path", "matchpath":
            state.inPath = true
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "nopath", "nomatchpath":
            state.inPath = false
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "diacritics", "utf8":
            state.diacritics = true
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "nodiacritics", "ansi":
            state.diacritics = false
            return value.isEmpty ? nil : literalNode(value, quoted: false, p: &p, state: state)
        case "regex":
            if value.isEmpty {
                state.regex = true
                return nil
            }
            do {
                let options: NSRegularExpression.Options = state.caseSensitive ? [] : [.caseInsensitive]
                let re = try NSRegularExpression(pattern: value, options: options)
                p.regexes.append(re)
                return .inst(.regex(idx: Int32(p.regexes.count - 1), inPath: state.inPath))
            } catch {
                return nil
            }
        case "sort":
            if let f = SortField.from(value) { state.sort = f }
            return nil
        case "ascending", "asc":
            state.ascending = true
            return nil
        case "descending", "desc":
            state.ascending = false
            return nil
        case "ext":
            var matcher = ExtMatcher()
            if value.isEmpty {
                matcher.matchNoExt = true
            } else {
                for part in value.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "|" }) {
                    matcher.add(String(part))
                }
            }
            p.extMatchers.append(matcher)
            return .inst(.ext(idx: Int32(p.extMatchers.count - 1), negate: false))
        case "type":
            if let kind = FilterKind.allCases.first(where: { $0.keyword == value.lowercased() }),
               let frag = kind.queryFragment {
                let sub = parse(frag, options: QueryOptions())
                if !sub.insts.isEmpty {
                    p.combine(sub)
                    return nil
                }
            }
            return nil
        case "file", "files":
            return .inst(.isDir(false))
        case "folder", "folders", "dir", "dirs":
            return .inst(.isDir(true))
        case "size":
            guard let range = parseSizeSpec(value) else { return nil }
            return .inst(.sizeRange(min: range.0, max: range.1))
        case "empty":
            return .inst(.sizeRange(min: 0, max: 0))
        case "notempty":
            return .inst(.sizeRange(min: 1, max: Int64.max))
        case "dm", "datemodified":
            guard let range = parseDateSpec(value) else { return nil }
            return .inst(.mtimeRange(min: range.0, max: range.1))
        case "dc", "datecreated":
            guard let range = parseDateSpec(value) else { return nil }
            return .inst(.btimeRange(min: range.0, max: range.1))
        case "da", "dateaccessed":
            guard let range = parseDateSpec(value) else { return nil }
            return .inst(.mtimeRange(min: range.0, max: range.1))
        case "depth":
            guard let range = parseDepthSpec(value) else { return nil }
            return .inst(.depthRange(min: range.0, max: range.1, base: state.depthBase))
        case "parent":
            var sub = state
            sub.inPath = true
            return parentNode(value, p: &p, state: sub)
        case "wfn", "containerfilename":
            let off = p.litBuf.count
            let bytes = Array((state.caseSensitive ? value : asciiLowerString(value)).utf8)
            p.litBuf.append(contentsOf: bytes)
            return .inst(.glob(off: Int32(off), len: Int32(bytes.count), inPath: false,
                               caseSensitive: state.caseSensitive))
        case "startwith":
            return anchoredNode(value, anchor: 1, p: &p, state: state)
        case "endwith":
            return anchoredNode(value, anchor: 2, p: &p, state: state)
        case "hidden":
            state.explicitHidden = true
            state.explicitHiddenValue = true
            return .inst(.hidden(true))
        case "nohidden":
            state.explicitHidden = true
            state.explicitHiddenValue = false
            return .inst(.hidden(false))
        case "symlink":
            return .inst(.symlink(true))
        case "nosymlink":
            return .inst(.symlink(false))
        case "package":
            return .inst(.package(true))
        case "nopackage":
            return .inst(.package(false))
        case "exec", "executable":
            return .inst(.executable(true))
        case "noexec":
            return .inst(.executable(false))
        case "vol", "volume":
            // Single-volume-per-root model: match against the indexed root path.
            return literalNode(value, quoted: false, p: &p, state: state)
        case "child", "childcount", "attrib", "len", "infolder", "containerfile":
            return nil
        default:
            return literalNode(name + ":" + value, quoted: false, p: &p, state: state)
        }
    }

    private static func anchoredNode(_ value: String, anchor: UInt8, p: inout ParsedQuery,
                                     state: State) -> Node? {
        guard !value.isEmpty else { return nil }
        if state.regex { return literalNode(value, quoted: true, p: &p, state: state) }
        let (term, _, _) = p.addLiteral(value, caseSensitive: state.caseSensitive,
                                        diacritics: state.diacritics)
        return .inst(.lit(term: term.first, inPath: state.inPath, wholeWord: false, anchor: anchor))
    }

    /// `parent:name` matches the directory part of the path.
    private static func parentNode(_ value: String, p: inout ParsedQuery, state: State) -> Node? {
        guard !value.isEmpty else { return nil }
        let (term, _, _) = p.addLiteral(value, caseSensitive: state.caseSensitive,
                                        diacritics: state.diacritics)
        return .inst(.lit(term: term.first, inPath: true, wholeWord: state.wholeWord, anchor: 4))
    }

    // MARK: emit (post-order → RPN)

    private static func emit(_ node: Node, into p: inout ParsedQuery, state: inout State) {
        switch node {
        case .nothing:
            break
        case .inst(let i):
            p.insts.append(i)
        case .not(let a):
            emit(a, into: &p, state: &state)
            p.insts.append(.notOp)
        case .and(let a, let b):
            emit(a, into: &p, state: &state)
            emit(b, into: &p, state: &state)
            p.insts.append(.andOp)
        case .or(let a, let b):
            emit(a, into: &p, state: &state)
            emit(b, into: &p, state: &state)
            p.insts.append(.orOp)
        }
    }

    static func asciiLowerString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                out.unicodeScalars.append(Unicode.Scalar(scalar.value + 32)!)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

// MARK: - value parsing helpers

func parseSizeSpec(_ raw: String) -> (Int64, Int64)? {
    let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !value.isEmpty else { return nil }
    switch value {
    case "tiny": return (0, 10 * 1024)
    case "small": return (10 * 1024, 100 * 1024)
    case "medium": return (100 * 1024, 1024 * 1024)
    case "large": return (1024 * 1024, 16 * 1024 * 1024)
    case "huge": return (16 * 1024 * 1024, 128 * 1024 * 1024)
    case "gigantic": return (128 * 1024 * 1024, Int64.max)
    case "empty": return (0, 0)
    default: break
    }
    var body = value
    var op = "="
    if body.hasPrefix(">=") { op = ">="; body.removeFirst(2) }
    else if body.hasPrefix("<=") { op = "<="; body.removeFirst(2) }
    else if body.hasPrefix(">") { op = ">"; body.removeFirst() }
    else if body.hasPrefix("<") { op = "<"; body.removeFirst() }

    if body.contains("..") {
        let parts = body.components(separatedBy: "..")
        guard parts.count == 2 else { return nil }
        let lo = parseSizeValue(parts[0]) ?? 0
        let hi = parts[1].isEmpty ? Int64.max : (parseSizeValue(parts[1]) ?? Int64.max)
        return (lo, hi)
    }
    guard let v = parseSizeValue(body) else { return nil }
    switch op {
    case ">": return (v &+ 1, Int64.max)
    case ">=": return (v, Int64.max)
    case "<": return (0, v > 0 ? v - 1 : 0)
    case "<=": return (0, v)
    default: return (v, v)
    }
}

func parseSizeValue(_ raw: String) -> Int64? {
    var s = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "")
    guard !s.isEmpty else { return nil }
    var multiplier: Int64 = 1
    let units: [(String, Int64)] = [("kib", 1024), ("mib", 1024 * 1024), ("gib", 1024 * 1024 * 1024),
                                    ("tib", 1024 * 1024 * 1024 * 1024),
                                    ("kb", 1024), ("mb", 1024 * 1024), ("gb", 1024 * 1024 * 1024),
                                    ("tb", 1024 * 1024 * 1024 * 1024),
                                    ("k", 1024), ("m", 1024 * 1024), ("g", 1024 * 1024 * 1024),
                                    ("t", 1024 * 1024 * 1024 * 1024), ("b", 1)]
    for (suffix, mult) in units where s.hasSuffix(suffix) {
        s.removeLast(suffix.count)
        multiplier = mult
        break
    }
    s = s.trimmingCharacters(in: .whitespaces)
    guard let base = Double(s) else { return nil }
    return Int64(base * Double(multiplier))
}

func parseDepthSpec(_ raw: String) -> (Int32, Int32)? {
    let v = raw.trimmingCharacters(in: .whitespaces)
    guard !v.isEmpty else { return nil }
    if v.contains("..") {
        let parts = v.components(separatedBy: "..")
        let lo = Int32(parts[0]) ?? 0
        let hi = parts.count > 1 ? (Int32(parts[1]) ?? Int32.max) : Int32.max
        return (max(0, lo), hi)
    }
    if v.hasPrefix(">") { return ((Int32(v.dropFirst()) ?? 0) + 1, Int32.max) }
    if v.hasPrefix("<") { return (0, max(0, (Int32(v.dropFirst()) ?? 0) - 1)) }
    if let n = Int32(v) { return (n, n) }
    return nil
}

/// Accepts `today`, `yesterday`, `thisweek`, `lastmonth`, `2024-01-31`,
/// `>2024-01-01`, `2024-01-01..2024-02-01` … Returns an inclusive [min,max] range.
func parseDateSpec(_ raw: String) -> (Int32, Int32)? {
    let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !value.isEmpty else { return nil }
    let cal = Calendar.current
    let now = Date()
    func span(_ start: Date, _ end: Date) -> (Int32, Int32) {
        (Int32(start.timeIntervalSince1970), Int32(end.timeIntervalSince1970) - 1)
    }
    func day(_ offset: Int) -> (Int32, Int32)? {
        guard let d = cal.date(byAdding: .day, value: offset, to: now) else { return nil }
        let s = cal.startOfDay(for: d)
        return span(s, cal.date(byAdding: .day, value: 1, to: s)!)
    }
    switch value {
    case "today": return day(0)
    case "yesterday": return day(-1)
    case "tomorrow": return day(1)
    case "thisweek":
        guard let interval = cal.dateInterval(of: .weekOfYear, for: now) else { return nil }
        return span(interval.start, interval.end)
    case "lastweek":
        guard let interval = cal.dateInterval(of: .weekOfYear, for: now),
              let start = cal.date(byAdding: .weekOfYear, value: -1, to: interval.start) else { return nil }
        return span(start, interval.start)
    case "thismonth":
        guard let interval = cal.dateInterval(of: .month, for: now) else { return nil }
        return span(interval.start, interval.end)
    case "lastmonth":
        guard let interval = cal.dateInterval(of: .month, for: now),
              let start = cal.date(byAdding: .month, value: -1, to: interval.start) else { return nil }
        return span(start, interval.start)
    case "thisyear":
        guard let interval = cal.dateInterval(of: .year, for: now) else { return nil }
        return span(interval.start, interval.end)
    case "lastyear":
        guard let interval = cal.dateInterval(of: .year, for: now),
              let start = cal.date(byAdding: .year, value: -1, to: interval.start) else { return nil }
        return span(start, interval.start)
    default: break
    }
    if value.contains("..") {
        let parts = value.components(separatedBy: "..")
        let lo = parseDateBound(parts[0], isUpper: false) ?? 0
        let hi = parts.count > 1 ? (parseDateBound(parts[1], isUpper: true) ?? Int32.max) : Int32.max
        return (lo, hi)
    }
    var body = value
    var op = "="
    if body.hasPrefix(">=") { op = ">="; body.removeFirst(2) }
    else if body.hasPrefix("<=") { op = "<="; body.removeFirst(2) }
    else if body.hasPrefix(">") { op = ">"; body.removeFirst() }
    else if body.hasPrefix("<") { op = "<"; body.removeFirst() }
    guard let (lo, hi) = parseDateSpan(body) else { return nil }
    switch op {
    case ">": return (hi &+ 1, Int32.max)
    case ">=": return (lo, Int32.max)
    case "<": return (0, lo > 0 ? lo - 1 : 0)
    case "<=": return (0, hi)
    default: return (lo, hi)
    }
}

private func parseDateBound(_ s: String, isUpper: Bool) -> Int32? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return nil }
    guard let span = parseDateSpan(t) else { return nil }
    return isUpper ? span.1 : span.0
}

/// Parses `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, `YYYY-MM-DD HH:MM(:SS)`, `M/D/YYYY`.
private func parseDateSpan(_ s: String) -> (Int32, Int32)? {
    let cal = Calendar.current
    let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    let parts = cleaned.split(separator: " ").map(String.init)
    let datePart = parts.first ?? cleaned
    var timePart: String? = parts.count > 1 ? parts[1] : nil
    if timePart == nil, datePart.contains("T") {
        let split = datePart.split(separator: "T").map(String.init)
        if split.count == 2 { timePart = split[1] }
    }
    let dateOnly = datePart.contains("T") ? datePart.split(separator: "T").map(String.init)[0] : datePart
    let comps = dateOnly.split(separator: "-").map { Int($0) ?? 0 }
    guard !comps.isEmpty, comps[0] > 0 else { return nil }
    var c = DateComponents()
    c.year = comps[0]
    if comps.count > 1 { c.month = comps[1] } else { c.month = 1 }
    if comps.count > 2 { c.day = comps[2] } else { c.day = 1 }
    if let time = timePart {
        let tp = time.split(separator: ":").map { Int($0) ?? 0 }
        if tp.count > 0 { c.hour = tp[0] }
        if tp.count > 1 { c.minute = tp[1] }
        if tp.count > 2 { c.second = tp[2] }
    }
    guard let start = cal.date(from: c) else { return nil }
    var end: Date
    if comps.count <= 1 {
        end = cal.date(byAdding: .year, value: 1, to: start)!
    } else if comps.count == 2 {
        end = cal.date(byAdding: .month, value: 1, to: start)!
    } else if timePart != nil {
        end = cal.date(byAdding: .second, value: 1, to: start)!
    } else {
        end = cal.date(byAdding: .day, value: 1, to: start)!
    }
    return (Int32(start.timeIntervalSince1970), Int32(end.timeIntervalSince1970) - 1)
}
