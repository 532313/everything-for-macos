import Foundation

// everything-cli — command line front end for the same index engine the GUI uses.

func stderr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func humanSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes) / 1024.0
    var idx = 0
    while value >= 1024 && idx < units.count - 1 { value /= 1024; idx += 1 }
    return String(format: "%.1f %@", value, units[idx])
}

func formatDate(_ seconds: Int32) -> String {
    guard seconds > 0 else { return "" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

struct CLIOptions {
    var query = ""
    var indexDir: URL?
    var roots: [String] = []
    var limit = 100
    var sort: SortField?
    var ascending = true
    var json = false
    var print0 = false
    var matchCase = false
    var wholeWord = false
    var matchPath = false
    var regex = false
    var showHidden = false
    var filter: FilterKind = .all
    var rebuild = false
    var noCache = false
    var foldersOnly = false
    var filesOnly = false
    var countOnly = false
    var fullPath = true
    var watchSeconds = 0.0
    var verbose = false
}

func parseArgs(_ args: [String]) -> CLIOptions {
    var o = CLIOptions()
    var i = 0
    var queryParts: [String] = []
    while i < args.count {
        let a = args[i]
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        switch a {
        case "--index", "--index-dir": if let v = next() { o.indexDir = URL(fileURLWithPath: v) }
        case "--root", "-r": if let v = next() { o.roots.append(v) }
        case "--limit", "-n": if let v = next() { o.limit = Int(v) ?? o.limit }
        case "--sort", "-s": if let v = next() { o.sort = SortField.from(v) }
        case "--desc": o.ascending = false
        case "--asc": o.ascending = true
        case "--json": o.json = true
        case "--print0", "-0": o.print0 = true
        case "--case", "-c": o.matchCase = true
        case "--whole-word", "-w": o.wholeWord = true
        case "--path", "-p": o.matchPath = true
        case "--regex", "-e": o.regex = true
        case "--hidden": o.showHidden = true
        case "--filter":
            if let v = next() {
                // Match by keyword: FilterKind raw values are display names
                // ("Source code"), keywords are lowercase tokens ("source").
                if let f = FilterKind.allCases.first(where: { $0.keyword == v.lowercased() }) {
                    o.filter = f
                } else {
                    stderr("unknown filter '\(v)' (try: all, audio, compressed, document, executable, folder, picture, video, source)")
                }
            }
        case "--folders": o.foldersOnly = true
        case "--files": o.filesOnly = true
        case "--count": o.countOnly = true
        case "--name-only": o.fullPath = false
        case "--rebuild": o.rebuild = true
        case "--no-cache": o.noCache = true
        case "--watch": if let v = next() { o.watchSeconds = Double(v) ?? 0 }
        case "--verbose", "-v": o.verbose = true
        case "--selftest": queryParts.append("\u{1}selftest")
        case "--help", "-h": queryParts.append("\u{1}help")
        default:
            if a.hasPrefix("--") {
                stderr("unknown option: \(a)")
            } else {
                queryParts.append(a)
            }
        }
        i += 1
    }
    o.query = queryParts.joined(separator: " ")
    return o
}

func usage() {
    print("""
    everything-cli — instant file search for macOS

    USAGE
      everything-cli [options] <query>

    QUERY SYNTAX
      alpha beta              AND (all terms must match)
      alpha|beta              OR
      !alpha                  NOT
      "exact phrase"          quoted phrase
      alpha* / *.png          wildcards
      <a|b> c                 grouping (parentheses work too)
      ext:png;jpg             extension list
      file: / folder:         files only / folders only
      size:>10mb  size:1kb..1mb  size:empty  size:tiny…
      dm:today  dm:>2024-01-01  dm:2024-01-01..2024-02-01
      dc:thisyear             creation date
      path:src   parent:build  match path / parent folder
      depth:2    depth:1..3    startwith:x  endwith:x  wfn:*.md
      regex:^main   case:x   wholeword:x   hidden:  package:  symlink:
      sort:size  descending:  type:audio  …

    OPTIONS
      -r, --root <dir>      index root (repeatable, default /)
      -n, --limit <n>       max results (default 100)
      -s, --sort <field>    name|path|size|modified|created|ext|kind
          --desc            sort descending
          --filter <name>   All|Audio|Compressed|Document|Executable|Folder|Picture|Video|Source
      -c, --case            match case
      -w, --whole-word      match whole words
      -p, --path            match against the full path
      -e, --regex           treat the query as a regular expression
          --hidden          include hidden files
          --count           print only the number of matches
          --json            machine readable output
      -0, --print0          NUL separated paths (for xargs -0)
          --rebuild         force a full rescan
          --no-cache        do not read/write the index cache
          --watch <secs>    stay running, print live changes
          --selftest        run the built-in test suite
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
let opts = parseArgs(args)

if opts.query.contains("\u{1}help") {
    usage()
    exit(0)
}
if opts.query.contains("\u{1}selftest") {
    exit(SelfTest.run())
}

let indexDir = opts.indexDir ?? IndexDatabase.defaultDirectory()
let db = IndexDatabase(indexDirectory: indexDir)
if !opts.roots.isEmpty {
    db.scanOptions.roots = opts.roots
    db.scanOptions.indexMountedVolumes = opts.roots.contains("/")
}

var quiet = false
db.onStatusChange = { status in
    if opts.verbose && !status.message.isEmpty { stderr("[status] \(status.message)") }
    switch status.state {
    case .scanning:
        if !quiet { stderr("\r  indexing… \(status.scanned) objects") }
    case .live:
        if !quiet && status.message.hasPrefix("Indexed") {
            stderr("\r  \(status.message)                        ")
        }
    case .failed(let m):
        stderr("index error: \(m)")
    default:
        break
    }
}

if opts.noCache {
    db.rebuild()
} else {
    db.start(watch: opts.watchSeconds > 0, rescanIfStale: 12 * 3600)
    if opts.rebuild { db.rebuild() }
}

// Wait until an index exists and (when rebuilding) the first scan finished.
var waited = 0.0
while db.currentIndex().count == 0 && waited < 3600 {
    usleep(100_000)
    waited += 0.1
    if db.currentIndex().count == 0 && !db.isScanning && waited > 3 {
        db.rebuild()
    }
}
if db.isScanning {
    while db.isScanning && waited < 3600 {
        usleep(100_000)
        waited += 0.1
    }
}
quiet = true
if !db.status.message.isEmpty { stderr("") }

var qo = QueryOptions()
qo.matchCase = opts.matchCase
qo.matchWholeWord = opts.wholeWord
qo.matchPath = opts.matchPath
qo.useRegex = opts.regex
qo.showHidden = opts.showHidden
qo.filter = opts.filter
qo.maxResults = max(1, opts.limit)
if opts.foldersOnly { qo.filter = .folder }
if let s = opts.sort { qo.sort = s }
qo.ascending = opts.ascending

var queryText = opts.query
if opts.filesOnly {
    queryText = queryText.isEmpty ? "file:" : "file: \(queryText)"
}

var result = db.search(text: queryText, options: qo)

if opts.countOnly {
    print(result.totalMatches)
    exit(0)
}

if opts.json {
    var rows: [[String: Any]] = []
    for i in 0..<result.count {
        let e = result.entries[i]
        rows.append([
            "name": result.name(i),
            "path": result.path(i),
            "size": e.size,
            "modified": Int(e.mtime),
            "created": Int(e.btime),
            "isDir": e.isDir,
            "isHidden": e.isHidden,
            "ext": result.ext(i)
        ])
    }
    let payload: [String: Any] = [
        "query": queryText,
        "total": result.totalMatches,
        "returned": result.count,
        "truncated": result.truncated,
        "durationMs": result.duration * 1000,
        "results": rows
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}

if opts.print0 {
    for i in 0..<result.count { print(result.path(i) + "\0", terminator: "") }
    exit(0)
}

let indexed = db.currentIndex().count
stderr("\(result.totalMatches) of \(indexed) objects  (\(String(format: "%.0f", result.duration * 1000)) ms)")

let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd HH:mm"
var lines: [String] = []
for i in 0..<result.count {
    let e = result.entries[i]
    let name = opts.fullPath ? result.path(i) : result.name(i)
    let size = e.isDir ? "<DIR>" : humanSize(e.size)
    lines.append("\(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(df.string(from: Date(timeIntervalSince1970: TimeInterval(e.mtime))))  \(name)")
}
if !lines.isEmpty { print(lines.joined(separator: "\n")) }

if opts.watchSeconds > 0 {
    let deadline = Date().addingTimeInterval(opts.watchSeconds)
    defer {
        // Everything in memory is flushed on exit so the next run starts warm.
        if db.hasUnsavedChanges { _ = db.saveCache() }
    }
    // The returned row list is capped by --limit, so the *match count* (and the
    // first row) is what indicates a real change.
    var lastSeen = result.totalMatches
    var lastFirst = result.count > 0 ? result.path(0) : ""
    while Date() < deadline {
        usleep(400_000)
        let fresh = db.search(text: queryText, options: qo)
        let first = fresh.count > 0 ? fresh.path(0) : ""
        if fresh.totalMatches != lastSeen || first != lastFirst {
            lastSeen = fresh.totalMatches
            lastFirst = first
            print("\n--- update: \(fresh.totalMatches) matches ---")
            for i in 0..<min(fresh.count, 20) { print(fresh.path(i)) }
        }
    }
}
