import AppKit
import UniformTypeIdentifiers

/// The main Everything window: filter popup, instant search field, results
/// table and status bar.
final class MainWindowController: NSWindowController, NSTableViewDataSource,
                                  NSTableViewDelegate, NSSearchFieldDelegate {

    static let shared = MainWindowController()
    private let app = AppController.shared

    private let searchField = NSSearchField()
    private let filterPopUp = NSPopUpButton()
    private let tableView = ResultsTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let indexBanner = NSView()
    private let indexBannerLabel = NSTextField(labelWithString: "")
    private let indexBannerSpinner = NSProgressIndicator()

    private let modeControl = NSSegmentedControl()
    private let gridScrollView = NSScrollView()
    private let collectionView = ResultsCollectionView()
    private let gridController = IconGridController()
    private var savedColumnWidths: [String: CGFloat] = [:]
    private var optionButtons: [NSButton] = []
    private var lastRevision = -1
    private var localMonitor: Any?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Everything"
        window.minSize = NSSize(width: 720, height: 360)
        window.center()
        window.setFrameAutosaveName("EverythingMainWindow")
        window.titlebarAppearsTransparent = false
        self.init(window: window)
        window.delegate = self
        buildUI()
        wire()
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let window = window else { return }
        let content = NSView()

        // --- top bar -------------------------------------------------------
        filterPopUp.removeAllItems()
        for kind in FilterKind.allCases { filterPopUp.addItem(withTitle: kind.rawValue) }
        filterPopUp.target = self
        filterPopUp.action = #selector(filterChanged(_:))
        filterPopUp.bezelStyle = .rounded
        filterPopUp.controlSize = .regular
        filterPopUp.translatesAutoresizingMaskIntoConstraints = false
        filterPopUp.widthAnchor.constraint(equalToConstant: 118).isActive = true
        filterPopUp.toolTip = "Filter by file kind"

        searchField.placeholderString = "Search everything…"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let optionSpecs: [(String, String, Selector)] = [
            ("Aa", "Match case", #selector(optionToggled(_:))),
            ("W", "Match whole word", #selector(optionToggled(_:))),
            ("path", "Match path", #selector(optionToggled(_:))),
            (".*", "Regular expressions", #selector(optionToggled(_:))),
            ("◐", "Show hidden files", #selector(optionToggled(_:)))
        ]
        var buttons: [NSButton] = []
        for (title, tip, action) in optionSpecs {
            let button = NSButton(title: title, target: self, action: action)
            button.setButtonType(.toggle)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
            buttons.append(button)
        }
        optionButtons = buttons

        modeControl.segmentCount = ViewMode.allCases.count
        modeControl.segmentStyle = .texturedRounded
        modeControl.trackingMode = .selectOne
        for (index, mode) in ViewMode.allCases.enumerated() {
            let image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title)
            modeControl.setImage(image, forSegment: index)
            modeControl.setToolTip(mode.title, forSegment: index)
            modeControl.setWidth(40, forSegment: index)
        }
        modeControl.selectedSegment = app.viewMode.rawValue
        modeControl.target = self
        modeControl.action = #selector(viewModeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSStackView(views: [filterPopUp, searchField] + buttons + [modeControl])
        topBar.orientation = .horizontal
        topBar.distribution = .fill
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        // --- indexing banner ------------------------------------------------
        indexBanner.translatesAutoresizingMaskIntoConstraints = false
        indexBanner.wantsLayer = true
        indexBanner.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        indexBanner.isHidden = true
        indexBannerSpinner.style = .spinning
        indexBannerSpinner.controlSize = .small
        indexBannerSpinner.translatesAutoresizingMaskIntoConstraints = false
        indexBannerSpinner.startAnimation(nil)
        indexBannerLabel.font = NSFont.systemFont(ofSize: 11)
        indexBannerLabel.textColor = .secondaryLabelColor
        indexBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        indexBanner.addSubview(indexBannerSpinner)
        indexBanner.addSubview(indexBannerLabel)
        NSLayoutConstraint.activate([
            indexBanner.heightAnchor.constraint(equalToConstant: 22),
            indexBannerSpinner.leadingAnchor.constraint(equalTo: indexBanner.leadingAnchor, constant: 12),
            indexBannerSpinner.centerYAnchor.constraint(equalTo: indexBanner.centerYAnchor),
            indexBannerLabel.leadingAnchor.constraint(equalTo: indexBannerSpinner.trailingAnchor, constant: 8),
            indexBannerLabel.centerYAnchor.constraint(equalTo: indexBanner.centerYAnchor)
        ])

        // --- results table --------------------------------------------------
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.style = .fullWidth
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))

        let columns: [(String, String, CGFloat, SortField?)] = [
            ("name", "Name", 330, .name),
            ("path", "Path", 400, .path),
            ("size", "Size", 90, .size),
            ("modified", "Date Modified", 140, .modified),
            ("created", "Date Created", 140, .created),
            ("kind", "Type", 110, .kind)
        ]
        for (identifier, title, width, field) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 60
            if field != nil {
                column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            }
            tableView.addTableColumn(column)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // --- icon grid ------------------------------------------------------
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = app.viewMode.itemSize
        flow.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        flow.minimumInteritemSpacing = 6
        flow.minimumLineSpacing = 6
        collectionView.collectionViewLayout = flow
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(ResultGridItem.self, forItemWithIdentifier: ResultGridItem.identifier)
        gridController.attach(collectionView)
        gridScrollView.documentView = collectionView
        gridScrollView.hasVerticalScroller = true
        gridScrollView.autohidesScrollers = true
        gridScrollView.borderType = .noBorder
        gridScrollView.drawsBackground = false
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false
        gridScrollView.isHidden = true

        // --- status bar -----------------------------------------------------
        for label in [statusLabel, indexLabel, timeLabel] {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = NSStackView(views: [statusLabel, NSView(), spinner, indexLabel, timeLabel])
        statusBar.orientation = .horizontal
        statusBar.spacing = 10
        statusBar.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.distribution = .fill

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(topBar)
        content.addSubview(topSeparator)
        content.addSubview(indexBanner)
        content.addSubview(scrollView)
        content.addSubview(gridScrollView)
        content.addSubview(bottomSeparator)
        content.addSubview(statusBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            topSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            indexBanner.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            indexBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            indexBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: indexBanner.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            gridScrollView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        window.contentView = content
        installScrollObservers()
        applyViewMode(reload: false)
        syncOptionButtons()
        syncSortDescriptor()
        updateStatus()
    }

    /// Watches both scroll views so background index refreshes can wait until the
    /// user stops scrolling instead of yanking the list back to the top.
    private func installScrollObservers() {
        for scrollView in [scrollView, gridScrollView] {
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(scrollWillStart(_:)),
                                                   name: NSScrollView.willStartLiveScrollNotification,
                                                   object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(scrollDidEnd(_:)),
                                                   name: NSScrollView.didEndLiveScrollNotification,
                                                   object: scrollView)
        }
    }

    @objc private func scrollBoundsChanged(_ note: Notification) {
        app.noteScrollActivity()
    }

    @objc private func scrollWillStart(_ note: Notification) {
        app.beginScrolling()
    }

    @objc private func scrollDidEnd(_ note: Notification) {
        app.endScrolling()
    }

    private func wire() {
        app.onResultsChanged = { [weak self] in self?.resultsChanged() }
        app.onStatusChanged = { [weak self] in self?.updateStatus() }
        app.onViewModeChanged = { [weak self] in self?.applyViewMode(reload: true) }
    }

    // MARK: - actions

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem, let kind = FilterKind(rawValue: title) {
            app.filter = kind
        }
    }

    @objc private func optionToggled(_ sender: NSButton) {
        guard let index = optionButtons.firstIndex(of: sender) else { return }
        let on = sender.state == .on
        switch index {
        case 0: app.matchCase = on
        case 1: app.matchWholeWord = on
        case 2: app.matchPath = on
        case 3: app.useRegex = on
        case 4: app.showHidden = on
        default: break
        }
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        app.openSelection(nil)
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        app.viewMode = ViewMode(rawValue: sender.selectedSegment) ?? .details
    }

    /// Applies `AppController.viewMode` to the window (view swap, columns, layout).
    func applyViewMode(reload: Bool) {
        let mode = app.viewMode
        modeControl.selectedSegment = mode.rawValue
        if mode.isGrid {
            gridController.mode = mode
            gridController.usePreviews = app.useThumbnails
            if let flow = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                flow.itemSize = mode.itemSize
                flow.invalidateLayout()
            }
            scrollView.isHidden = true
            gridScrollView.isHidden = false
            gridController.applySelection(app.selectedRows)
            if reload { gridController.reload() }
            window?.makeFirstResponder(collectionView)
        } else {
            scrollView.isHidden = false
            gridScrollView.isHidden = true
            tableView.rowHeight = (mode == .compact) ? 17 : 20
            if savedColumnWidths.isEmpty {
                for column in tableView.tableColumns { savedColumnWidths[column.identifier.rawValue] = column.width }
            }
            for column in tableView.tableColumns {
                let keep = (mode == .details) || column.identifier.rawValue == "name"
                if !keep { savedColumnWidths[column.identifier.rawValue] = column.width }
                column.isHidden = !keep
            }
            if mode == .compact {
                tableView.columnAutoresizingStyle = .noColumnAutoresizing
                if let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) {
                    nameColumn.width = max(240, scrollView.contentSize.width - 8)
                }
            } else {
                tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
                for column in tableView.tableColumns {
                    if let width = savedColumnWidths[column.identifier.rawValue] { column.width = width }
                }
            }
            if reload {
                tableView.reloadData()
                tableView.selectRowIndexes(app.selectedRows, byExtendingSelection: false)
            }
            window?.makeFirstResponder(tableView)
        }
    }

    private func syncOptionButtons() {
        let values = [app.matchCase, app.matchWholeWord, app.matchPath, app.useRegex, app.showHidden]
        for (index, button) in optionButtons.enumerated() where index < values.count {
            button.state = values[index] ? .on : .off
        }
        filterPopUp.selectItem(withTitle: app.filter.rawValue)
    }

    func setSearchText(_ text: String) {
        searchField.stringValue = text
    }

    // MARK: accessors used by the UI smoke test

    var tableIsVisible: Bool { !scrollView.isHidden }
    var gridIsVisible: Bool { !gridScrollView.isHidden }
    var tableRowCount: Int { tableView.numberOfRows }
    var gridItemCount: Int { collectionView.numberOfItems(inSection: 0) }
    var tableRowHeight: CGFloat { tableView.rowHeight }
    var revision: Int { lastRevision }
    var tableScrollOriginY: Double { Double(scrollView.contentView.bounds.origin.y) }
    var gridScrollOriginY: Double { Double(gridScrollView.contentView.bounds.origin.y) }

    func scrollTable(toRow row: Int) {
        guard row < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(row)
    }

    func scrollGrid(toItem item: Int) {
        guard item < collectionView.numberOfItems(inSection: 0) else { return }
        collectionView.scrollToItems(at: [IndexPath(item: item, section: 0)], scrollPosition: .top)
    }
    var visibleColumnNames: [String] {
        tableView.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }
    }

    /// Real item geometry produced by the collection view flow layout.
    var gridGeometry: [String: Any] {
        var out: [String: Any] = [:]
        if let flow = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            out["itemSize"] = ["w": Int(flow.itemSize.width), "h": Int(flow.itemSize.height)]
        }
        var frames: [[String: Any]] = []
        let gridCount = collectionView.numberOfItems(inSection: 0)
        for index in 0..<min(3, gridCount) {
            if let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
                let frame = attributes.frame
                frames.append(["w": Int(frame.width.rounded()), "h": Int(frame.height.rounded()),
                               "y": Int(frame.origin.y.rounded())])
            }
        }
        out["items"] = frames
        var cells: [[String: Any]] = []
        for index in 0..<min(2, gridCount) {
            let indexPath = IndexPath(item: index, section: 0)
            if let item = collectionView.item(at: indexPath) as? ResultGridItem {
                cells.append(item.debugState)
            }
        }
        out["cells"] = cells
        out["collectionBounds"] = ["w": Int(collectionView.bounds.width), "h": Int(collectionView.bounds.height)]
        return out
    }

    /// Frames of the top bar controls, in window coordinates.
    var topBarFrames: [[String: Any]] {
        var out: [[String: Any]] = []
        func describe(_ view: NSView, _ name: String) {
            let frame = view.convert(view.bounds, to: nil)
            out.append([
                "name": name,
                "x": Int(frame.origin.x.rounded()),
                "y": Int(frame.origin.y.rounded()),
                "w": Int(frame.width.rounded()),
                "h": Int(frame.height.rounded()),
                "hidden": view.isHidden
            ])
        }
        describe(filterPopUp, "filter")
        describe(searchField, "search")
        for (index, button) in optionButtons.enumerated() { describe(button, "option\(index)") }
        describe(modeControl, "viewMode")
        describe(statusLabel, "status")
        describe(indexLabel, "indexLabel")
        return out
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.moveToEndOfLine(nil)
    }

    func selectAllRows() {
        if app.viewMode.isGrid {
            gridController.selectAll()
        } else {
            tableView.selectAll(nil)
            app.selectedRows = tableView.selectedRowIndexes
        }
    }

    func typeIntoSearch(_ text: String) {
        searchField.stringValue += text
        app.query = searchField.stringValue
        focusSearchField()
    }

    private func syncSortDescriptor() {
        let key = MainWindowController.key(for: app.sortField)
        let current = tableView.sortDescriptors.first
        if current?.key != key || current?.ascending != app.sortAscending {
            tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: app.sortAscending)]
        }
    }

    static func key(for field: SortField) -> String {
        switch field {
        case .name: return "name"
        case .path: return "path"
        case .size: return "size"
        case .modified: return "modified"
        case .created: return "created"
        case .ext, .kind: return "kind"
        }
    }

    static func field(for key: String) -> SortField? {
        switch key {
        case "name": return .name
        case "path": return .path
        case "size": return .size
        case "modified": return .modified
        case "created": return .created
        case "kind": return .kind
        default: return nil
        }
    }

    // MARK: - refresh

    private func resultsChanged() {
        lastRevision &+= 1
        // Only an explicit query/sort change may move the viewport: a background
        // index refresh must leave the user exactly where they were.
        let resetPosition = (app.lastTrigger == .user)
        if app.viewMode.isGrid {
            gridController.reload()
            if resetPosition && collectionView.numberOfItems(inSection: 0) > 0 {
                collectionView.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
            }
        } else {
            tableView.reloadData()
            if resetPosition && app.results.count > 0 { tableView.scrollRowToVisible(0) }
        }
        syncSortDescriptor()
        syncOptionButtons()
        updateStatus()
    }

    private func updateStatus() {
        guard let window = window else { return }
        statusLabel.stringValue = app.statusSummary
        indexLabel.stringValue = app.indexSummary + (app.results.truncated ? "  ·  list truncated" : "")
        timeLabel.stringValue = app.searchTimeText
        let busy = app.isSearching || app.status.state == .scanning || app.status.state == .updating
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        let scanning = app.status.state == .scanning
        indexBanner.isHidden = !scanning
        if scanning {
            indexBannerLabel.stringValue = "Indexing \(app.status.scanned.formatted()) objects in \(app.db.scanOptions.roots.joined(separator: ", "))…"
        }
        window.title = app.query.isEmpty ? "Everything" : "Everything — \(app.query)"
        NSApp.mainMenu?.update()
    }

    // MARK: - table data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        app.results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < app.results.count else { return nil }
        let identifier = column.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = NSFont.systemFont(ofSize: 12)
            cell.addSubview(text)
            cell.textField = text
            if identifier.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4).isActive = true
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        }

        let entry = app.results.entries[row]
        switch identifier.rawValue {
        case "name":
            if app.viewMode == .compact {
                let name = NSMutableAttributedString(string: app.name(row), attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: entry.isHidden ? NSColor.secondaryLabelColor : NSColor.labelColor
                ])
                var suffix = "    " + app.parent(row)
                let size = app.sizeText(row)
                if !size.isEmpty { suffix += "  ·  " + size }
                suffix += "  ·  " + app.modifiedText(row)
                name.append(NSAttributedString(string: suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
                cell.textField?.attributedStringValue = name
            } else {
                cell.textField?.stringValue = app.name(row)
                cell.textField?.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
            }
            cell.imageView?.image = IconCache.shared.icon(extension: app.ext(row),
                                                          isDirectory: entry.isDir,
                                                          isPackage: entry.isPackage)
        case "path":
            cell.textField?.stringValue = app.parent(row)
            cell.textField?.textColor = .secondaryLabelColor
        case "size":
            cell.textField?.stringValue = app.sizeText(row)
            cell.textField?.alignment = .right
            cell.textField?.textColor = .labelColor
        case "modified":
            cell.textField?.stringValue = app.modifiedText(row)
            cell.textField?.textColor = .labelColor
        case "created":
            cell.textField?.stringValue = app.createdText(row)
            cell.textField?.textColor = .labelColor
        case "kind":
            cell.textField?.stringValue = app.kindText(row)
            cell.textField?.textColor = .secondaryLabelColor
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let field = MainWindowController.field(for: key) else { return }
        if app.sortField == field && app.sortAscending == descriptor.ascending { return }
        app.sortField = field
        app.sortAscending = descriptor.ascending
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        app.selectedRows = tableView.selectedRowIndexes
        NSApp.mainMenu?.update()
    }

    // MARK: - search field

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        app.query = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            app.query = ""
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if !app.selectedRows.isEmpty {
                app.openSelection(nil)
                return true
            }
            // Move focus into the table so arrows/space work immediately.
            if app.results.count > 0 {
                window?.makeFirstResponder(tableView)
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                return true
            }
        }
        if selector == #selector(NSResponder.moveDown(_:)) {
            window?.makeFirstResponder(tableView)
            if app.results.count > 0 {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            return true
        }
        return false
    }

}

extension MainWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        guard app.viewMode == .compact else { return }
        if let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) {
            nameColumn.width = max(240, scrollView.contentSize.width - 8)
        }
    }
}

// MARK: - UI smoke test

/// Headless-ish verification used by the build: walks every view mode, checks the
/// view hierarchy actually swapped, and writes a PNG of each state. Enabled with
/// EVERYTHING_UI_SMOKE=<output dir>.
final class UISmokeTest {
    private let outputDirectory: URL
    private var report: [[String: Any]] = []

    init?(outputDirectory: String) {
        guard !outputDirectory.isEmpty else { return nil }
        self.outputDirectory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: self.outputDirectory, withIntermediateDirectories: true)
    }

    func start(controller: MainWindowController) {
        if let query = ProcessInfo.processInfo.environment["EVERYTHING_UI_SMOKE_QUERY"], !query.isEmpty {
            AppController.shared.query = query
        }
        let modes = ViewMode.allCases
        var remaining = modes.map { $0 }
        func step() {
            guard let mode = remaining.first else {
                runScrollChecks(controller: controller) { self.finish() }
                return
            }
            remaining.removeFirst()
            AppController.shared.viewMode = mode
            // Give the run loop a few turns so cells and thumbnails materialise.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.capture(controller: controller, mode: mode)
                step()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { step() }
    }

    /// Regression check: background index refreshes must never move the viewport,
    /// and refreshes during an active scroll must be deferred.
    private func runScrollChecks(controller: MainWindowController, done: @escaping () -> Void) {
        let app = AppController.shared
        app.viewMode = .details
        var steps: [[String: Any]] = []
        func snapshot(_ label: String) -> [String: Any] {
            ["step": label,
             "scrollY": controller.tableScrollOriginY,
             "revision": controller.revision,
             "rows": app.results.count]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            controller.scrollTable(toRow: 2000)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                let baseline = controller.tableScrollOriginY
                steps.append(snapshot("scrolled down"))
                for _ in 0..<3 { app.search(trigger: .index) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    steps.append(snapshot("after 3 background refreshes"))
                    app.beginScrolling()
                    app.search(trigger: .index)
                    app.noteScrollActivity()
                    app.search(trigger: .index)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        steps.append(snapshot("while user is scrolling"))
                        app.endScrolling()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            steps.append(snapshot("after scrolling stopped"))
                            // A change that really is visible (a new file the query
                            // matches) must reload the list but still not move it.
                            let marker = FileManager.default.currentDirectoryPath + "/.scroll-marker.txt"
                            try? "1".write(toFile: marker, atomically: true, encoding: .utf8)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                                steps.append(snapshot("after a real index change"))
                                try? FileManager.default.removeItem(atPath: marker)
                                let moved = steps.contains { abs(($0["scrollY"] as? Double ?? 0) - baseline) > 0.5 }
                                let reloadedAfterChange = (steps.last?["revision"] as? Int ?? 0)
                                    > (steps[steps.count - 2]["revision"] as? Int ?? 0)
                                self.report.append([
                                    "mode": "scroll-stability",
                                    "baselineScrollY": baseline,
                                    "scrollMoved": moved,
                                    "reloadedOnRealChange": reloadedAfterChange,
                                    "steps": steps
                                ])
                                print("smoke: scroll baseline=\(baseline) moved=\(moved) reloaded=\(reloadedAfterChange)")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Renders a view through the PDF drawing path: a real drawing pass with the
    /// view's appearance, unlike `cacheDisplay` which ignores it (and would draw
    /// a dark-mode window with a light background).
    static func pngData(for view: NSView) -> Data? {
        let pdf = view.dataWithPDF(inside: view.bounds)
        guard let image = NSImage(data: pdf),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func capture(controller: MainWindowController, mode: ViewMode) {
        let app = AppController.shared
        var entry: [String: Any] = [
            "mode": mode.title,
            "rawValue": mode.rawValue,
            "results": app.results.count,
            "tableVisible": controller.tableIsVisible,
            "gridVisible": controller.gridIsVisible,
            "tableRows": controller.tableRowCount,
            "gridItems": controller.gridItemCount,
            "visibleColumns": controller.visibleColumnNames,
            "rowHeight": controller.tableRowHeight,
            "filename": "view-\(mode.rawValue)-\(mode.title.replacingOccurrences(of: " ", with: "-").lowercased()).png",
            "topBar": controller.topBarFrames,
            "grid": controller.gridGeometry
        ]
        // Capture the theme frame (not just the content view): the window
        // background lives there, and without it a dark-mode window would be
        // rendered on a white page.
        if let window = controller.window, let content = window.contentView,
           let view = content.superview ?? Optional(content),
           let data = UISmokeTest.pngData(for: view) {
            if true {
                let url = outputDirectory.appendingPathComponent(entry["filename"] as! String)
                try? data.write(to: url)
                entry["pngBytes"] = data.count
            }
        }
        report.append(entry)
        print("smoke: \(entry)")
    }

    private func finish() {
        let url = outputDirectory.appendingPathComponent("smoke-report.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}

/// Cached workspace icons keyed by extension (icons are expensive to fetch).
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func icon(extension ext: String, isDirectory: Bool, isPackage: Bool) -> NSImage? {
        let key = isDirectory ? (isPackage ? "::pkg" : "::dir") : (ext.isEmpty ? "::file" : ext)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let image: NSImage
        if isDirectory {
            image = NSWorkspace.shared.icon(for: isPackage ? .bundle : .folder)
        } else if ext.isEmpty {
            image = NSWorkspace.shared.icon(for: .data)
        } else if let type = UTType(filenameExtension: ext) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        image.size = NSSize(width: 16, height: 16)
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }
}

/// NSTableView subclass with Everything's keyboard behaviour.
final class ResultsTableView: NSTableView {
    weak var controller: MainWindowController?
    private var retainedMenuTarget: MenuTarget?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard !AppController.shared.selectedRows.isEmpty else { return nil }
        let target = MenuTarget()
        retainedMenuTarget = target
        return ResultsContextMenu.build(target: target)
    }

    override func keyDown(with event: NSEvent) {
        if ResultsKeyboard.handle(event) { return }
        super.keyDown(with: event)
    }
}
