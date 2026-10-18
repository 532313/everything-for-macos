import AppKit

/// Settings panel: indexed locations, exclusions, search defaults and about info.
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()
    private let app = AppController.shared

    private let rootsView = NSTextView()
    private let excludesView = NSTextView()
    private let descendCheck = NSButton(checkboxWithTitle: "Index into application bundles (.app, .framework, …)", target: nil, action: nil)
    private let volumesCheck = NSButton(checkboxWithTitle: "Index mounted volumes under /Volumes", target: nil, action: nil)
    private let maxResultsPopUp = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let cacheLabel = NSTextField(labelWithString: "")

    private let caseCheck = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wordCheck = NSButton(checkboxWithTitle: "Match whole word", target: nil, action: nil)
    private let pathCheck = NSButton(checkboxWithTitle: "Match path", target: nil, action: nil)
    private let diacriticsCheck = NSButton(checkboxWithTitle: "Match diacritics (accept NFC and NFD spellings)", target: nil, action: nil)
    private let regexCheck = NSButton(checkboxWithTitle: "Enable regular expressions", target: nil, action: nil)
    private let hiddenCheck = NSButton(checkboxWithTitle: "Show hidden files", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Everything Settings"
        window.center()
        self.init(window: window)
        build()
        load()
    }

    // MARK: construction

    private func build() {
        guard let window = window else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab(title: "Index", view: buildIndexTab()))
        tabs.addTabViewItem(tab(title: "Search", view: buildSearchTab()))
        tabs.addTabViewItem(tab(title: "About", view: buildAboutTab()))

        let content = NSView()
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        window.contentView = content
    }

    private func tab(title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func buildIndexTab() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12)
        ])

        stack.addArrangedSubview(header("Indexed locations — one path per line"))
        configure(textView: rootsView, height: 96)
        stack.addArrangedSubview(rootsView.enclosingScrollView!)

        let rootButtons = NSStackView(views: [
            button("Add Folder…", #selector(addFolder)),
            button("Add /Volumes", #selector(addVolumes)),
            button("Use Whole Disk (/)", #selector(useWholeDisk))
        ])
        rootButtons.orientation = .horizontal
        rootButtons.spacing = 8
        stack.addArrangedSubview(rootButtons)

        descendCheck.target = self
        descendCheck.action = #selector(markDirty)
        volumesCheck.target = self
        volumesCheck.action = #selector(markDirty)
        stack.addArrangedSubview(descendCheck)
        stack.addArrangedSubview(volumesCheck)

        stack.addArrangedSubview(header("Excluded paths — one path prefix per line"))
        configure(textView: excludesView, height: 72)
        stack.addArrangedSubview(excludesView.enclosingScrollView!)

        let actionButtons = NSStackView(views: [
            button("Apply & Rebuild Index", #selector(applyAndRebuild)),
            button("Save Cache Now", #selector(saveCache)),
            button("Delete Cache", #selector(deleteCache))
        ])
        actionButtons.orientation = .horizontal
        actionButtons.spacing = 8
        stack.addArrangedSubview(actionButtons)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        cacheLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        cacheLabel.textColor = .secondaryLabelColor
        cacheLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(cacheLabel)
        return container
    }

    private func buildSearchTab() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ])
        stack.addArrangedSubview(header("Search defaults"))
        for check in [caseCheck, wordCheck, pathCheck, diacriticsCheck, regexCheck, hiddenCheck] {
            check.target = self
            check.action = #selector(searchDefaultsChanged)
            stack.addArrangedSubview(check)
        }
        stack.addArrangedSubview(NSBox.separatorBox())
        stack.addArrangedSubview(header("Maximum number of rows materialised in the list"))
        maxResultsPopUp.addItems(withTitles: ["10,000", "50,000", "100,000", "250,000", "1,000,000"])
        maxResultsPopUp.target = self
        maxResultsPopUp.action = #selector(searchDefaultsChanged)
        stack.addArrangedSubview(maxResultsPopUp)
        let hint = NSTextField(wrappingLabelWithString:
            "Searching three million objects takes about 40 ms. This limit only caps how many rows are copied into the result list — use filters or extra terms to narrow things down, or raise the limit if you really want to scroll through everything.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(NSBox.separatorBox())
        stack.addArrangedSubview(button("Apply", #selector(applySearchDefaults)))
        return container
    }

    private func buildAboutTab() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ])
        let title = NSTextField(labelWithString: "Everything for macOS")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        stack.addArrangedSubview(title)
        let version = NSTextField(labelWithString: "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
        version.textColor = .secondaryLabelColor
        version.font = NSFont.systemFont(ofSize: 11)
        stack.addArrangedSubview(version)

        let body = NSTextField(wrappingLabelWithString:
            """
            A native re-implementation of the Windows instant file search.

            • A parallel filesystem walk (readdir + lstat) builds a compact columnar index: one 32-byte record per object plus a single UTF-8 path buffer.
            • Queries scan that buffer at memory speed — millions of rows in tens of milliseconds — through a tiny RPN evaluator that supports AND/OR/NOT, grouping, wildcards, regular expressions, size/date/depth/extension filters.
            • FSEvents with file-level granularity feeds incremental updates, merged into a fresh immutable snapshot so searches never block on writes.
            • The index is cached next to the last FSEvents id, which makes the next launch instant.
            """)
        body.font = NSFont.systemFont(ofSize: 11)
        body.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(body)

        stack.addArrangedSubview(NSBox.separatorBox())
        stack.addArrangedSubview(header("Current index"))
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statsLabel)
        stack.addArrangedSubview(button("Reveal Cache in Finder", #selector(revealCache)))
        return container
    }

    // MARK: helpers

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 12)
        return label
    }

    private func configure(textView: NSTextView, height: CGFloat) {
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = true
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 590).isActive = true
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    // MARK: state

    func load() {
        rootsView.string = app.db.scanOptions.roots.joined(separator: "\n")
        let extra = app.db.scanOptions.excludedPaths.filter { !ScanOptions.defaultExcludes.contains($0) }
        excludesView.string = extra.joined(separator: "\n")
        descendCheck.state = app.db.scanOptions.descendPackages ? .on : .off
        volumesCheck.state = app.db.scanOptions.indexMountedVolumes ? .on : .off
        caseCheck.state = app.matchCase ? .on : .off
        wordCheck.state = app.matchWholeWord ? .on : .off
        pathCheck.state = app.matchPath ? .on : .off
        diacriticsCheck.state = app.matchDiacritics ? .on : .off
        regexCheck.state = app.useRegex ? .on : .off
        hiddenCheck.state = app.showHidden ? .on : .off
        let titles = ["10,000", "50,000", "100,000", "250,000", "1,000,000"]
        let values = [10_000, 50_000, 100_000, 250_000, 1_000_000]
        if let index = values.firstIndex(where: { $0 >= app.maxResults }) {
            maxResultsPopUp.selectItem(at: index)
            _ = titles
        }
        refreshStatus()
    }

    private func refreshStatus() {
        let index = app.db.currentIndex()
        statusLabel.stringValue = "\(app.indexSummary) — \(index.stats.files.formatted()) files, \(index.stats.folders.formatted()) folders, \(index.stats.skipped.formatted()) skipped"
        cacheLabel.stringValue = "cache: \(app.db.cacheURL.path)"
        let entries = index.count * MemoryLayout<FSEntry>.stride
        var cacheSize = "none"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: app.db.cacheURL.path),
           let size = attrs[.size] as? Int64 {
            cacheSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        statsLabel.stringValue = """
        objects:      \(index.count.formatted())
        path buffer:  \(ByteCountFormatter.string(fromByteCount: Int64(index.pathBuf.count), countStyle: .memory))
        records:      \(ByteCountFormatter.string(fromByteCount: Int64(entries), countStyle: .memory))
        cache file:   \(cacheSize)
        last scan:    \(String(format: "%.1f s", index.stats.duration))
        """
    }

    @objc private func markDirty() {
        statusLabel.stringValue = "Changed — press “Apply & Rebuild Index” to use the new settings."
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Index"
        if panel.runModal() == .OK {
            var lines = rootsView.string.split(separator: "\n").map(String.init)
            for url in panel.urls where !lines.contains(url.path) { lines.append(url.path) }
            rootsView.string = lines.joined(separator: "\n")
            markDirty()
        }
    }

    @objc private func addVolumes() {
        var lines = rootsView.string.split(separator: "\n").map(String.init)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for item in items where !item.hasPrefix(".") {
                let path = "/Volumes/\(item)"
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                   !lines.contains(path) {
                    lines.append(path)
                }
            }
        }
        rootsView.string = lines.joined(separator: "\n")
        markDirty()
    }

    @objc private func useWholeDisk() {
        rootsView.string = "/"
        markDirty()
    }

    @objc private func applyAndRebuild() {
        var roots = rootsView.string.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if roots.isEmpty { roots = ["/"] }
        app.db.scanOptions.roots = roots
        app.db.scanOptions.excludedPaths = ScanOptions.defaultExcludes + excludesView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        app.db.scanOptions.descendPackages = descendCheck.state == .on
        app.db.scanOptions.indexMountedVolumes = volumesCheck.state == .on
        app.savePreferences()
        app.rebuildIndex(nil)
        statusLabel.stringValue = "Rebuilding index…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshStatus() }
    }

    @objc private func applySearchDefaults() {
        app.matchCase = caseCheck.state == .on
        app.matchWholeWord = wordCheck.state == .on
        app.matchPath = pathCheck.state == .on
        app.matchDiacritics = diacriticsCheck.state == .on
        app.useRegex = regexCheck.state == .on
        app.showHidden = hiddenCheck.state == .on
        statusLabel.stringValue = "Search defaults applied."
    }

    @objc private func searchDefaultsChanged() {
        applySearchDefaults()
    }

    @objc private func saveCache() {
        let ok = app.db.saveCache()
        statusLabel.stringValue = ok ? "Index cache saved." : "Could not write the cache."
        refreshStatus()
    }

    @objc private func deleteCache() {
        app.deleteCache(nil)
        statusLabel.stringValue = "Index cache deleted."
        refreshStatus()
    }

    @objc private func revealCache() {
        NSWorkspace.shared.activateFileViewerSelecting([app.db.cacheURL])
    }
}

extension NSBox {
    static func separatorBox() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 580).isActive = true
        return box
    }
}
