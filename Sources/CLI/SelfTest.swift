import Foundation

/// End-to-end self test: builds a synthetic tree, indexes it, runs a battery of
/// queries and verifies both the matcher and the live-update path.
enum SelfTest {

    static func run() -> Int32 {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            checks += 1
            if condition {
                print("  PASS  \(name)")
            } else {
                let d = detail()
                print("  FAIL  \(name)\(d.isEmpty ? "" : "  — \(d)")")
                failures.append(name)
            }
        }

        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".selftest-tree")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        func mkdir(_ p: String) {
            try? fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        func mkfile(_ p: String, bytes: Int = 0, ageDays: Double = 0) -> String {
            let url = root.appendingPathComponent(p)
            let parent = (p as NSString).deletingLastPathComponent
            if !parent.isEmpty { mkdir(parent) }
            let data = Data(repeating: 0x41, count: bytes)
            fm.createFile(atPath: url.path, contents: data)
            if ageDays > 0 {
                let date = Date().addingTimeInterval(-ageDays * 86400)
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            return url.path
        }

        print("== building test tree ==")
        _ = mkfile("alpha.txt", bytes: 100)
        _ = mkfile("beta.TXT", bytes: 200)
        _ = mkfile("Gamma.md", bytes: 0)
        _ = mkfile("noext", bytes: 10)
        _ = mkfile("alpha_beta.log", bytes: 300)
        _ = mkfile("report 2024 (1).csv", bytes: 400)
        _ = mkfile("café.txt", bytes: 500)
        let nfdName = "cafe\u{0301}_nfd.txt"
        _ = mkfile(nfdName, bytes: 600)
        _ = mkfile(".hidden_alpha.txt", bytes: 700)
        let oldPath = mkfile("old_file.dat", bytes: 800)
        var oldComps = DateComponents(); oldComps.year = 2017; oldComps.month = 6; oldComps.day = 15
        oldComps.hour = 12; oldComps.minute = 30
        if let oldDate = Calendar.current.date(from: oldComps) {
            try? fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldPath)
        }
        _ = mkfile("dir1/alpha_report.pdf", bytes: 1024)
        _ = mkfile("dir1/nested/deep_file.swift", bytes: 2048)
        _ = mkfile("dir2/alpha_notes.md", bytes: 4096)
        _ = mkfile("dir2/sub/Zeta.json", bytes: 8192)
        mkdir("empty_dir")
        _ = mkfile("my_app.app/Contents/Info.plist", bytes: 512)

        print("== scanning ==")
        let options = ScanOptions(roots: [root.path], excludedPaths: [], descendPackages: true)
        func baseOptions() -> QueryOptions {
            var o = QueryOptions()
            o.rootPath = root.path
            return o
        }
        let t0 = Date()
        let index = Walker.scan(options: options, progress: ScanProgress()) { false }
        print("  indexed \(index.count) objects in \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")

        func q(_ text: String, opts: QueryOptions? = nil, showHidden: Bool = false) -> ResultSet {
            var o = opts ?? baseOptions()
            o.showHidden = showHidden
            let parsed = QueryParser.compile(text, options: o)
            return SearchEngine.run(index: index, parsed: parsed, options: o, text: text)
        }
        func names(_ set: ResultSet) -> Set<String> {
            var out = Set<String>()
            for i in 0..<set.count { out.insert(set.name(i)) }
            return out
        }
        func paths(_ set: ResultSet) -> [String] {
            (0..<set.count).map { set.path($0) }
        }

        print("== query tests ==")
        check("literal 'alpha' finds 3 visible names",
              names(q("alpha")) == ["alpha.txt", "alpha_beta.log", "alpha_report.pdf", "alpha_notes.md"],
              "got \(names(q("alpha")).sorted())")
        check("literal 'alpha' + hidden", names(q("alpha", showHidden: true)).count == 5,
              "got \(names(q("alpha", showHidden: true)).sorted())")
        check("AND: 'alpha beta'", names(q("alpha beta")) == ["alpha_beta.log"],
              "got \(names(q("alpha beta")).sorted())")
        check("OR: 'gamma|beta'", names(q("gamma|beta")) == ["Gamma.md", "beta.TXT", "alpha_beta.log"],
              "got \(names(q("gamma|beta")).sorted())")
        check("NOT: 'alpha !report'", names(q("alpha !report")) == ["alpha.txt", "alpha_beta.log", "alpha_notes.md"],
              "got \(names(q("alpha !report")).sorted())")
        check("NOT excludes hidden by default", !names(q("alpha !report")).contains(".hidden_alpha.txt"),
              "got \(names(q("alpha !report")).sorted())")
        check("grouping: 'alpha (report|notes)'",
              names(q("alpha (report|notes)")) == ["alpha_report.pdf", "alpha_notes.md"],
              "got \(names(q("alpha (report|notes)")).sorted())")
        check("ext:txt is case insensitive", names(q("ext:txt")) == ["alpha.txt", "beta.TXT", "café.txt", "cafe\u{0301}_nfd.txt"],
              "got \(names(q("ext:txt")).sorted())")
        check("ext list: ext:txt;md", names(q("ext:txt;md")).count == 6,
              "got \(names(q("ext:txt;md")).sorted())")
        check("ext: empty matches extension-less", names(q("ext:")).contains("noext"),
              "got \(names(q("ext:")).sorted())")
        check("size:0 finds zero byte file", names(q("size:0")) == ["Gamma.md"],
              "got \(names(q("size:0")).sorted())")
        check("size:>=1kb", names(q("size:>=1kb")) == ["alpha_report.pdf", "deep_file.swift", "alpha_notes.md", "Zeta.json"],
              "got \(names(q("size:>=1kb")).sorted())")
        check("size:>1kb excludes exactly 1kb", !names(q("size:>1kb")).contains("alpha_report.pdf"),
              "got \(names(q("size:>1kb")).sorted())")
        check("size range 100..300", names(q("size:100..300")) == ["alpha.txt", "beta.TXT", "alpha_beta.log"],
              "got \(names(q("size:100..300")).sorted())")
        check("folder: only folders", q("folder:").count == index.stats.folders,
              "\(q("folder:").count) vs \(index.stats.folders)")
        check("file: only files", q("file:", showHidden: true).count == index.stats.files,
              "\(q("file:", showHidden: true).count) vs \(index.stats.files)")
        check("path:dir1", paths(q("path:dir1")).allSatisfy { $0.contains("/dir1") } &&
              paths(q("path:dir1")).count == 4,
              "got \(paths(q("path:dir1")).sorted())")
        check("parent:dir2", names(q("parent:dir2")) == ["alpha_notes.md", "Zeta.json", "sub"],
              "got \(names(q("parent:dir2")).sorted())")
        check("startwith:alpha", names(q("startwith:alpha")) == ["alpha.txt", "alpha_beta.log", "alpha_report.pdf", "alpha_notes.md"],
              "got \(names(q("startwith:alpha")).sorted())")
        check("endwith:_notes.md", names(q("endwith:_notes.md")) == ["alpha_notes.md"])
        check("wfn:*.md", names(q("wfn:*.md")) == ["Gamma.md", "alpha_notes.md"],
              "got \(names(q("wfn:*.md")).sorted())")
        check("wildcard *.csv", names(q("*.csv")) == ["report 2024 (1).csv"],
              "got \(names(q("*.csv")).sorted())")
        check("regex:^gamma (case-insensitive by default)", names(q("regex:^gamma")) == ["Gamma.md"],
              "got \(names(q("regex:^gamma")).sorted())")
        check("case:Gamma is case sensitive", names(q("case:Gamma")) == ["Gamma.md"],
              "got \(names(q("case:Gamma")).sorted())")
        check("case:gamma finds nothing", names(q("case:gamma")).isEmpty,
              "got \(names(q("case:gamma")).sorted())")
        check("quoted phrase", names(q("\"report 2024\"")) == ["report 2024 (1).csv"],
              "got \(names(q("\"report 2024\"")).sorted())")
        check("wholeword", names(q("wholeword:alpha")) == ["alpha.txt"],
              "got \(names(q("wholeword:alpha")).sorted())")
        check("diacritics: NFC input finds NFC and NFD files",
              names(q("café")).isSuperset(of: ["café.txt", "cafe\u{0301}_nfd.txt"]),
              "got \(names(q("café")).sorted())")
        check("diacritics: NFD input finds both files",
              names(q("cafe\u{0301}")).isSuperset(of: ["café.txt", "cafe\u{0301}_nfd.txt"]),
              "got \(names(q("cafe\u{0301}")).sorted())")
        check("dm:today finds fresh files", q("dm:today").count >= 14, "got \(q("dm:today").count)")
        check("dm:<2000-01-01 finds nothing", q("dm:<2000-01-01").count == 0, "got \(q("dm:<2000-01-01").count)")
        check("dm:>2020-01-01 excludes the 2017 file", !names(q("dm:>2020-01-01")).contains("old_file.dat"),
              "got \(names(q("dm:>2020-01-01")).sorted())")
        check("dm:<2020-01-01 finds only old_file", names(q("dm:<2020-01-01")) == ["old_file.dat"],
              "got \(names(q("dm:<2020-01-01")).sorted())")
        check("dm:2017 finds old_file", names(q("dm:2017")).contains("old_file.dat"),
              "got \(names(q("dm:2017")).sorted())")
        check("depth:1 includes empty_dir", names(q("depth:1")).contains("empty_dir"),
              "got \(names(q("depth:1")).sorted())")
        check("depth:1 excludes nested file", !names(q("depth:1")).contains("alpha_report.pdf"))
        check("depth:3 finds deep file", names(q("depth:3")).contains("deep_file.swift"),
              "got \(names(q("depth:3")).sorted())")
        check("hidden: finds hidden", names(q("hidden:")) == [".hidden_alpha.txt"],
              "got \(names(q("hidden:")).sorted())")
        check("type:source finds swift", names(q("type:source")).contains("deep_file.swift") &&
              !names(q("type:source")).contains("alpha.txt"),
              "got \(names(q("type:source")).sorted())")
        check("type:document finds txt/md", names(q("type:document")).isSuperset(of: ["alpha.txt", "Gamma.md"]),
              "got \(names(q("type:document")).sorted())")
        check("package: finds the .app", names(q("package:")) == ["my_app.app"],
              "got \(names(q("package:")).sorted())")
        check("filter Folder = folder:", q("", opts: {
            var o = QueryOptions(); o.filter = .folder; return o
        }()).count == q("folder:").count,
              "\(q("", opts: { var o = QueryOptions(); o.filter = .folder; return o }()).count) vs \(q("folder:").count)")
        check("Document filter finds the pdf, Picture filter does not", {
            var doc = QueryOptions(); doc.filter = .document
            var pic = QueryOptions(); pic.filter = .picture
            return names(q("", opts: doc)).contains("alpha_report.pdf")
                && !names(q("", opts: pic)).contains("alpha_report.pdf")
        }(), "picture=\(names(q("", opts: { var o = QueryOptions(); o.filter = .picture; return o }())).sorted())")
        check("sort:name ascending", {
            let s = q("alpha sort:name")
            let n = (0..<s.count).map { s.name($0).lowercased() }
            return n == n.sorted()
        }())
        check("sort:size descending", {
            let s = q("alpha sort:size descending:")
            let v = (0..<s.count).map { s.entries[$0].size }
            return v == v.sorted(by: >)
        }())
        check("empty query returns everything visible", q("").count == index.count - 1,
              "\(q("").count) vs \(index.count)")
        check("empty query + hidden returns all", q("", showHidden: true).count == index.count,
              "\(q("", showHidden: true).count) vs \(index.count)")
        check("maxResults truncation", {
            var o = baseOptions(); o.maxResults = 3
            let s = q("", opts: o, showHidden: true)
            return s.count == 3 && s.totalMatches == index.count && s.truncated
        }(), {
            var o = baseOptions(); o.maxResults = 3; o.showHidden = true
            let s2 = q("", opts: o)
            return "count=\(s2.count) total=\(s2.totalMatches) index=\(index.count) truncated=\(s2.truncated)"
        }())

        print("== filter classification ==")
        var membership: [String: [String]] = [:]
        for kind in FilterKind.allCases {
            guard let fragment = kind.queryFragment, fragment.hasPrefix("ext:") else { continue }
            for ext in fragment.dropFirst(4).split(separator: ";") {
                membership[String(ext).lowercased(), default: []].append(kind.rawValue)
            }
        }
        // Dual identities that are intentional: a .md is both a document and
        // source, a .sh is both a script and executable.
        let dualIdentity: Set<String> = ["bash", "bat", "cfg", "cmd", "fish", "html", "ini", "jar",
                                         "js", "json", "md", "php", "pl", "py", "rb", "sh", "tex",
                                         "ts", "xml", "yaml", "yml", "zsh"]
        let offenders = membership.filter { $0.value.count > 1 && !dualIdentity.contains($0.key) }
        check("no extension sits in two unrelated filters", offenders.isEmpty,
              "offenders: \(offenders.keys.sorted())")
        check("pdf is a document, not a picture", membership["pdf"] == ["Document"],
              "got \(membership["pdf"] ?? [])")
        check("postscript graphics are pictures only", membership["eps"] == ["Picture"] && membership["ps"] == ["Picture"],
              "eps=\(membership["eps"] ?? []) ps=\(membership["ps"] ?? [])")
        check("ts is source, never video", membership["ts"]?.contains("Video") == false,
              "got \(membership["ts"] ?? [])")
        check("common photos map to exactly one filter",
              ["png", "jpg", "jpeg", "gif", "heic", "tiff"].allSatisfy { (membership[$0] ?? []).count == 1 },
              "png=\(membership["png"] ?? []) jpg=\(membership["jpg"] ?? [])")
        check("video containers map to Video only",
              ["mp4", "mov", "mkv", "avi", "webm"].allSatisfy { membership[$0] == ["Video"] },
              "mp4=\(membership["mp4"] ?? []) mkv=\(membership["mkv"] ?? [])")
        check("archives map to Compressed only",
              ["zip", "7z", "rar", "tar", "gz"].allSatisfy { membership[$0] == ["Compressed"] })

        print("== live update tests ==")
        let tmpIndex = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".selftest-index")
        try? fm.removeItem(at: tmpIndex)
        let db = IndexDatabase(indexDirectory: tmpIndex)
        db.scanOptions = options
        db.rebuild()
        waited = 0.0
        while db.isScanning || db.currentIndex().count == 0 {
            usleep(100_000); waited += 0.1
            if waited > 60 { break }
        }
        db.stopWatchingForTest()
        check("rebuild produced an index", db.currentIndex().count == index.count,
              "\(db.currentIndex().count) vs \(index.count)")
        // Direct incremental update (deterministic: no reliance on FSEvents timing).
        let live = mkfile("live_added.txt", bytes: 1234)
        db.applyPaths([live])
        // applyPaths is async: wait for the update to land.
        var waited = 0.0
        while waited < 5 {
            if db.currentIndex().count == index.count + 1 { break }
            usleep(50_000); waited += 0.05
        }
        let afterAdd = db.search(text: "live_added", options: QueryOptions())
        check("incremental add indexed new file", afterAdd.count == 1,
              "count=\(afterAdd.count) indexCount=\(db.currentIndex().count)")
        check("incremental add kept sorted", {
            let idx = db.currentIndex()
            for i in 1..<max(1, idx.count) where idx.comparePaths(i - 1, i) > 0 { return false }
            return true
        }())

        try? fm.removeItem(atPath: live)
        db.applyPaths([live])
        waited = 0
        while waited < 5 {
            if db.search(text: "live_added", options: QueryOptions()).count == 0 { break }
            usleep(50_000); waited += 0.05
        }
        check("incremental delete removed file",
              db.search(text: "live_added", options: QueryOptions()).count == 0)

        let folder = root.appendingPathComponent("live_dir")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fm.createFile(atPath: folder.appendingPathComponent("inner_marker.txt").path, contents: Data(repeating: 1, count: 5))
        db.applyPaths([folder.path])
        waited = 0
        while waited < 5 {
            if db.search(text: "inner_marker", options: QueryOptions()).count == 1 { break }
            usleep(50_000); waited += 0.05
        }
        check("new folder is recursed into",
              db.search(text: "inner_marker", options: QueryOptions()).count == 1)

        // Same batch describes the folder *and* the file inside it: the recursive
        // expansion and the file's own event must not produce two records.
        let dupDir = root.appendingPathComponent("dup_dir")
        try? fm.createDirectory(at: dupDir, withIntermediateDirectories: true)
        let dupFile = dupDir.appendingPathComponent("dup_inner.txt")
        fm.createFile(atPath: dupFile.path, contents: Data(repeating: 2, count: 7))
        db.applyPaths([dupDir.path, dupFile.path, dupDir.path])
        waited = 0
        while waited < 5 {
            if db.search(text: "dup_inner", options: QueryOptions()).count == 1 { break }
            usleep(50_000); waited += 0.05
        }
        check("same-batch duplicate events collapse to one record",
              db.search(text: "dup_inner", options: QueryOptions()).count == 1,
              "got \(db.search(text: "dup_inner", options: QueryOptions()).count)")
        check("index stays strictly ascending after duplicates collapse", {
            let idx = db.currentIndex()
            for i in 1..<max(1, idx.count) where idx.comparePaths(i - 1, i) >= 0 { return false }
            return true
        }())
        check("duplicate folder record not doubled", {
            let hits = db.search(text: "dup_dir", options: QueryOptions())
            let names = (0..<hits.count).map { hits.name($0) }
            return names.filter { $0 == "dup_dir" }.count == 1
        }(), "got \(db.search(text: "dup_dir", options: QueryOptions()).count)")

        // Cache round trip.
        let db2 = IndexDatabase(indexDirectory: tmpIndex)
        db.stop()
        let saved = db.saveCache()
        check("cache saved", saved)
        let loaded = db2.loadCache()
        check("cache loaded", loaded)
        check("cache round trip preserves count",
              db2.currentIndex().count == db.currentIndex().count,
              "\(db2.currentIndex().count) vs \(db.currentIndex().count)")
        check("cache round trip preserves paths", {
            let a = db.currentIndex(), b = db2.currentIndex()
            guard a.count == b.count else { return false }
            for i in stride(from: 0, to: a.count, by: max(1, a.count / 50)) where a.pathString(i) != b.pathString(i) {
                return false
            }
            return true
        }())
        let roundTrip = db2.search(text: "alpha", options: QueryOptions())
        check("search works on loaded cache", roundTrip.count == 4, "got \(roundTrip.count)")

        try? fm.removeItem(at: tmpIndex)
        try? fm.removeItem(at: root)

        print("")
        print("checks: \(checks)  failures: \(failures.count)")
        if !failures.isEmpty {
            for f in failures { print("  ✗ \(f)") }
            return 1
        }
        print("ALL TESTS PASSED")
        return 0
    }
}
