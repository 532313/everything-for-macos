import Foundation
import AppKit

/// What caused a search. Background index updates must never move the user's
/// scroll position or selection, unlike an explicit query change.
enum SearchTrigger {
    /// The query, sort or filter changed: the list starts over from the top.
    case user
    /// The index changed underneath us: never disturb the viewport.
    case index
    /// Explicit refresh (⌘L): pick up changes without losing the position.
    case manual
}

/// Application state and actions. Plain AppKit friendly: no property wrappers,
/// no macros — just callbacks the window controllers subscribe to.
final class AppController: NSObject {
    static let shared = AppController()

    let db = IndexDatabase()

    // MARK: observable-ish state

    private(set) var results = ResultSet()
    private(set) var status = IndexStatus()
    private(set) var isSearching = false
    private(set) var searchTime: TimeInterval = 0
    var selectedRows = IndexSet()

    var onViewModeChanged: (() -> Void)?
    var onResultsChanged: (() -> Void)?
    var onStatusChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: search options

    var query: String = "" { didSet { search() } }
    var matchCase = false { didSet { optionChanged() } }
    var matchWholeWord = false { didSet { optionChanged() } }
    var matchPath = false { didSet { optionChanged() } }
    var matchDiacritics = true { didSet { optionChanged() } }
    var useRegex = false { didSet { optionChanged() } }
    var showHidden = false { didSet { optionChanged() } }
    var filter: FilterKind = .all { didSet { optionChanged() } }
    var sortField: SortField = .name { didSet { optionChanged() } }
    var sortAscending = true { didSet { optionChanged() } }
    var maxResults = 100_000 { didSet { optionChanged() } }

    /// Presentation mode shared by the window, the View menu and the toolbar.
    var viewMode: ViewMode = .details {
        didSet {
            guard viewMode != oldValue else { return }
            viewMode.save()
            onViewModeChanged?()
        }
    }
    /// Use Quick Look thumbnails instead of plain file type icons in grid views.
    var useThumbnails = true {
        didSet {
            guard useThumbnails != oldValue else { return }
            UserDefaults.standard.set(useThumbnails, forKey: "useThumbnails")
            onViewModeChanged?()
        }
    }

    private let searchQueue = DispatchQueue(label: "everything.search", qos: .userInteractive)
    private var generation = 0
    private var started = false

    /// Trigger of the result set currently published.
    private(set) var lastTrigger: SearchTrigger = .user
    private var lastFingerprint = ""
    private var indexRefreshQueued = false
    private var pendingIndexRefresh = false
    private var scrolling = false
    private var scrollActivity = Date.distantPast

    override init() {
        super.init()
        db.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            self.status = status
            self.onStatusChanged?()
        }
        db.onIndexChanged = { [weak self] in
            DispatchQueue.main.async { self?.search(trigger: .index) }
        }
    }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadPreferences()
        applyPreferences()
        // Loading a multi-hundred-MB cache (and possibly repairing it) happens
        // off the main thread so the window appears immediately; searches run
        // against an empty index until it lands, then onIndexChanged refreshes.
        searchQueue.async { [weak self] in
            guard let self = self else { return }
            self.db.start()
            DispatchQueue.main.async {
                self.onStatusChanged?()
                self.search()
            }
        }
        onStatusChanged?()
    }

    func shutdown() {
        savePreferences()
        db.stop()
    }

    private func applyPreferences() {
        let d = UserDefaults.standard
        if let roots = d.stringArray(forKey: "roots"), !roots.isEmpty {
            db.scanOptions.roots = roots
        }
        if d.object(forKey: "descendPackages") != nil {
            db.scanOptions.descendPackages = d.bool(forKey: "descendPackages")
        }
        if d.object(forKey: "indexMountedVolumes") != nil {
            db.scanOptions.indexMountedVolumes = d.bool(forKey: "indexMountedVolumes")
        }
        var excludes = ScanOptions.defaultExcludes
        if let extra = d.stringArray(forKey: "excludedPaths") { excludes.append(contentsOf: extra) }
        db.scanOptions.excludedPaths = excludes
    }

    func loadPreferences() {
        let d = UserDefaults.standard
        if d.object(forKey: "matchCase") != nil { matchCase = d.bool(forKey: "matchCase") }
        if d.object(forKey: "matchWholeWord") != nil { matchWholeWord = d.bool(forKey: "matchWholeWord") }
        if d.object(forKey: "matchPath") != nil { matchPath = d.bool(forKey: "matchPath") }
        if d.object(forKey: "matchDiacritics") != nil { matchDiacritics = d.bool(forKey: "matchDiacritics") }
        if d.object(forKey: "useRegex") != nil { useRegex = d.bool(forKey: "useRegex") }
        if d.object(forKey: "showHidden") != nil { showHidden = d.bool(forKey: "showHidden") }
        if d.object(forKey: "maxResults") != nil { maxResults = d.integer(forKey: "maxResults") }
        if d.object(forKey: "sortField") != nil {
            sortField = SortField(rawValue: d.integer(forKey: "sortField")) ?? .name
        }
        if d.object(forKey: "sortAscending") != nil { sortAscending = d.bool(forKey: "sortAscending") }
        viewMode = ViewMode.saved
        if d.object(forKey: "useThumbnails") != nil { useThumbnails = d.bool(forKey: "useThumbnails") }
    }

    func savePreferences() {
        let d = UserDefaults.standard
        d.set(matchCase, forKey: "matchCase")
        d.set(matchWholeWord, forKey: "matchWholeWord")
        d.set(matchPath, forKey: "matchPath")
        d.set(matchDiacritics, forKey: "matchDiacritics")
        d.set(useRegex, forKey: "useRegex")
        d.set(showHidden, forKey: "showHidden")
        d.set(maxResults, forKey: "maxResults")
        d.set(sortField.rawValue, forKey: "sortField")
        d.set(sortAscending, forKey: "sortAscending")
        d.set(db.scanOptions.roots, forKey: "roots")
        d.set(db.scanOptions.descendPackages, forKey: "descendPackages")
        d.set(db.scanOptions.indexMountedVolumes, forKey: "indexMountedVolumes")
        let extra = db.scanOptions.excludedPaths.filter { !ScanOptions.defaultExcludes.contains($0) }
        d.set(extra, forKey: "excludedPaths")
    }

    // MARK: searching

    private func optionChanged() {
        savePreferences()
        search()
    }

    /// Entry point for every refresh. Index driven refreshes are coalesced and
    /// deferred while the user is scrolling, so the list never jumps under them.
    func search(trigger: SearchTrigger = .user) {
        guard trigger == .index else {
            performSearch(trigger: trigger)
            return
        }
        deferIndexRefresh()
    }

    /// Coalesces index updates and waits out user scrolling. Re-checks itself, so
    /// a missed "scroll ended" notification can never stall refreshes for good.
    private func deferIndexRefresh() {
        pendingIndexRefresh = true
        guard !indexRefreshQueued else { return }
        indexRefreshQueued = true
        let delay: TimeInterval = scrolling ? 0.6 : 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.indexRefreshQueued = false
            if self.scrolling || Date().timeIntervalSince(self.scrollActivity) < 0.9 {
                if self.pendingIndexRefresh { self.deferIndexRefresh() }
                return
            }
            self.pendingIndexRefresh = false
            self.performSearch(trigger: .index)
        }
    }

    // MARK: scroll awareness

    func beginScrolling() {
        scrolling = true
        scrollActivity = Date()
    }

    func noteScrollActivity() {
        scrollActivity = Date()
    }

    func endScrolling() {
        scrolling = false
        scrollActivity = Date()
    }

    /// Cheap identity of a result set: enough to tell "the list the user is
    /// looking at changed" from "an unrelated file appeared somewhere else".
    private func fingerprint(_ result: ResultSet) -> String {
        let first = result.count > 0 ? result.path(0) : ""
        let last = result.count > 0 ? result.path(result.count - 1) : ""
        return "\(result.totalMatches)|\(result.count)|\(first)|\(last)"
    }

    private func performSearch(trigger: SearchTrigger) {
        generation += 1
        let gen = generation
        let text = query
        let options = currentOptions()
        isSearching = true
        DispatchQueue.main.async { self.onStatusChanged?() }
        searchQueue.async { [weak self] in
            guard let self = self else { return }
            let result = self.db.search(text: text, options: options)
            let print = self.fingerprint(result)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if trigger == .index && print == self.lastFingerprint {
                    // Nothing the user can see changed: do not touch the list at
                    // all (no reload, no scroll, no selection reset).
                    self.isSearching = false
                    self.onStatusChanged?()
                    return
                }
                self.lastFingerprint = print
                self.results = result
                self.searchTime = result.duration
                self.isSearching = false
                self.lastTrigger = trigger
                if trigger == .user {
                    self.selectedRows = IndexSet()
                }
                self.onResultsChanged?()
                self.onStatusChanged?()
            }
        }
    }

    func currentOptions() -> QueryOptions {
        var o = QueryOptions()
        o.matchCase = matchCase
        o.matchWholeWord = matchWholeWord
        o.matchPath = matchPath
        o.matchDiacritics = matchDiacritics
        o.useRegex = useRegex
        o.showHidden = showHidden
        o.filter = filter
        o.sort = sortField
        o.ascending = sortAscending
        o.maxResults = maxResults
        o.rootPath = db.scanOptions.roots.first ?? "/"
        return o
    }

    // MARK: row accessors

    func name(_ row: Int) -> String { results.name(row) }
    func path(_ row: Int) -> String { results.path(row) }
    func parent(_ row: Int) -> String { results.parentPath(row) }
    func ext(_ row: Int) -> String { results.ext(row) }

    func sizeText(_ row: Int) -> String {
        guard row >= 0 && row < results.count else { return "" }
        let e = results.entries[row]
        if e.isDir { return "" }
        return ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)
    }

    func modifiedText(_ row: Int) -> String {
        guard row >= 0 && row < results.count else { return "" }
        let t = results.entries[row].mtime
        return t > 0 ? AppController.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(t))) : ""
    }

    func createdText(_ row: Int) -> String {
        guard row >= 0 && row < results.count else { return "" }
        let t = results.entries[row].btime
        return t > 0 ? AppController.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(t))) : ""
    }

    func kindText(_ row: Int) -> String {
        guard row >= 0 && row < results.count else { return "" }
        let e = results.entries[row]
        if e.isDir { return e.isPackage ? "Bundle" : "Folder" }
        let ext = results.ext(row)
        return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
    }

    var selectedURLs: [URL] {
        selectedRows.compactMap { $0 < results.count ? results.url($0) : nil }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    // MARK: derived text

    var statusSummary: String {
        let total = results.totalMatches
        if results.count < total {
            return "\(results.count.formatted()) of \(total.formatted()) objects"
        }
        return "\(total.formatted()) object\(total == 1 ? "" : "s")"
    }

    var indexSummary: String {
        switch status.state {
        case .empty: return "no index yet"
        case .scanning: return "indexing… \(status.scanned.formatted()) objects"
        case .updating: return "updating index…"
        case .live: return "\(db.currentIndex().count.formatted()) objects indexed"
        case .failed(let m): return "index error: \(m)"
        }
    }

    var searchTimeText: String { String(format: "%.0f ms", searchTime * 1000) }
}

// MARK: - Actions (menu + toolbar targets)

extension AppController {

    @objc func focusSearchField(_ sender: Any?) {
        (NSApp.mainWindow?.windowController as? MainWindowController)?.focusSearchField()
    }

    @objc func clearSearch(_ sender: Any?) {
        query = ""
        (NSApp.mainWindow?.windowController as? MainWindowController)?.setSearchText("")
    }

    @objc func openSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileActions.open(urls)
    }

    @objc func revealSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileActions.reveal(urls)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileActions.openInTerminal(urls)
    }

    @objc func trashSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileActions.trash(urls) { [weak self] _ in
            self?.search()
        }
    }

    @objc func quickLook(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        QuickLookController.shared.toggle(urls)
    }

    @objc func copyNames(_ sender: Any?) {
        let names = selectedRows.compactMap { $0 < results.count ? results.name($0) : nil }
        guard !names.isEmpty else { NSSound.beep(); return }
        FileActions.copyToPasteboard(names.joined(separator: "\n"))
    }

    @objc func copyPaths(_ sender: Any?) {
        let paths = selectedRows.compactMap { $0 < results.count ? results.path($0) : nil }
        guard !paths.isEmpty else { NSSound.beep(); return }
        FileActions.copyToPasteboard(paths.joined(separator: "\n"))
    }

    @objc func copyFiles(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileActions.copyFilesToPasteboard(urls)
    }

    @objc func selectAllResults(_ sender: Any?) {
        (NSApp.mainWindow?.windowController as? MainWindowController)?.selectAllRows()
    }

    @objc func getInfo(_ sender: Any?) {
        FileActions.getInfo(selectedURLs)
    }

    @objc func rebuildIndex(_ sender: Any?) {
        db.rebuild()
    }

    @objc func saveIndex(_ sender: Any?) {
        db.saveCache()
    }

    @objc func deleteCache(_ sender: Any?) {
        try? FileManager.default.removeItem(at: db.cacheURL)
        self.onStatusChanged?()
    }

    @objc func exportResults(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "everything-results.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try FileActions.exportCSV(results: self.results, to: url)
            } catch {
                self.onError?("Export failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func showSyntax(_ sender: Any?) {
        SyntaxWindowController.shared.showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc func toggleShowHidden(_ sender: Any?) {
        showHidden.toggle()
    }

    @objc func setViewMode(_ sender: NSMenuItem) {
        viewMode = ViewMode(rawValue: sender.tag) ?? .details
    }

    @objc func setViewModeDetails(_ sender: Any?) { viewMode = .details }
    @objc func setViewModeList(_ sender: Any?) { viewMode = .compact }
    @objc func setViewModeIcons(_ sender: Any?) { viewMode = .icons }
    @objc func setViewModeLargeIcons(_ sender: Any?) { viewMode = .iconsLarge }

    @objc func toggleThumbnails(_ sender: Any?) {
        useThumbnails.toggle()
    }

    // Search option toggles from the menu (state comes from the menu item).
    @objc func toggleMatchCase(_ sender: NSMenuItem) { matchCase = sender.state == .on }
    @objc func toggleWholeWord(_ sender: NSMenuItem) { matchWholeWord = sender.state == .on }
    @objc func toggleMatchPath(_ sender: NSMenuItem) { matchPath = sender.state == .on }
    @objc func toggleDiacritics(_ sender: NSMenuItem) { matchDiacritics = sender.state == .on }
    @objc func toggleRegex(_ sender: NSMenuItem) { useRegex = sender.state == .on }

    @objc func setFilter(_ sender: NSMenuItem) {
        if let kind = FilterKind(rawValue: sender.title) {
            filter = kind
        }
    }

    @objc func setSort(_ sender: NSMenuItem) {
        if let field = SortField(rawValue: sender.tag) {
            sortField = field
            sortAscending = true
        }
    }

    @objc func setSortAscending(_ sender: Any?) { sortAscending = true }
    @objc func setSortDescending(_ sender: Any?) { sortAscending = false }
    @objc func refreshResults(_ sender: Any?) { search(trigger: .manual) }

    var menuState: (matchCase: Bool, wholeWord: Bool, path: Bool, diacritics: Bool,
                    regex: Bool, hidden: Bool, filter: FilterKind,
                    sortField: SortField, sortAscending: Bool) {
        (matchCase, matchWholeWord, matchPath, matchDiacritics, useRegex, showHidden,
         filter, sortField, sortAscending)
    }
}

// MARK: - Menu validation

extension AppController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(AppController.toggleMatchCase(_:)):
            menuItem.state = matchCase ? .on : .off
        case #selector(AppController.toggleWholeWord(_:)):
            menuItem.state = matchWholeWord ? .on : .off
        case #selector(AppController.toggleMatchPath(_:)):
            menuItem.state = matchPath ? .on : .off
        case #selector(AppController.toggleDiacritics(_:)):
            menuItem.state = matchDiacritics ? .on : .off
        case #selector(AppController.toggleRegex(_:)):
            menuItem.state = useRegex ? .on : .off
        case #selector(AppController.toggleShowHidden(_:)):
            menuItem.state = showHidden ? .on : .off
        case #selector(AppController.setViewMode(_:)):
            menuItem.state = (menuItem.tag == viewMode.rawValue) ? .on : .off
        case #selector(AppController.toggleThumbnails(_:)):
            menuItem.state = useThumbnails ? .on : .off
        case #selector(AppController.setFilter(_:)):
            menuItem.state = (menuItem.title == filter.rawValue) ? .on : .off
        case #selector(AppController.setSort(_:)):
            menuItem.state = (menuItem.tag == sortField.rawValue) ? .on : .off
        case #selector(AppController.setSortAscending(_:)):
            menuItem.state = sortAscending ? .on : .off
        case #selector(AppController.setSortDescending(_:)):
            menuItem.state = sortAscending ? .off : .on
        case #selector(AppController.openSelection(_:)),
             #selector(AppController.revealSelection(_:)),
             #selector(AppController.openInTerminal(_:)),
             #selector(AppController.trashSelection(_:)),
             #selector(AppController.quickLook(_:)),
             #selector(AppController.copyNames(_:)),
             #selector(AppController.copyPaths(_:)),
             #selector(AppController.copyFiles(_:)),
             #selector(AppController.getInfo(_:)):
            return !selectedRows.isEmpty
        case #selector(AppController.exportResults(_:)):
            return results.count > 0
        default:
            break
        }
        return true
    }
}
