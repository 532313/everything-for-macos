import AppKit

/// Builds the menu bar in code (no XIB, no SwiftUI).
enum MainMenuBuilder {

    static func build() -> NSMenu {
        let app = AppController.shared
        let main = NSMenu()

        // MARK: Application menu
        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = "Everything"
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(AppController.showSettings(_:)), ",", app)
        appMenu.addItem(.separator())
        add(appMenu, "Search Syntax Help", #selector(AppController.showSyntax(_:)), "/", app)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // MARK: File
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        add(fileMenu, "Open", #selector(AppController.openSelection(_:)), "o", app)
        add(fileMenu, "Quick Look", #selector(AppController.quickLook(_:)), "y", app)
        add(fileMenu, "Show in Finder", #selector(AppController.revealSelection(_:)), "r", app, [.command, .shift])
        add(fileMenu, "Open in Terminal", #selector(AppController.openInTerminal(_:)), "t", app, [.command, .shift])
        fileMenu.addItem(.separator())
        add(fileMenu, "Get Info", #selector(AppController.getInfo(_:)), "i", app)
        add(fileMenu, "Move to Trash", #selector(AppController.trashSelection(_:)), "\u{8}", app)
        fileMenu.addItem(.separator())
        add(fileMenu, "Export Results…", #selector(AppController.exportResults(_:)), "e", app)

        // MARK: Edit
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        add(editMenu, "Copy Name", #selector(AppController.copyNames(_:)), "c", app)
        add(editMenu, "Copy Full Path", #selector(AppController.copyPaths(_:)), "c", app, [.command, .shift])
        add(editMenu, "Copy File", #selector(AppController.copyFiles(_:)), "c", app, [.command, .option])
        editMenu.addItem(.separator())
        add(editMenu, "Select All", #selector(AppController.selectAllResults(_:)), "a", app)

        // MARK: Search
        let searchItem = NSMenuItem()
        main.addItem(searchItem)
        let searchMenu = NSMenu(title: "Search")
        searchItem.submenu = searchMenu
        add(searchMenu, "Focus Search Field", #selector(AppController.focusSearchField(_:)), "f", app)
        add(searchMenu, "Clear Search", #selector(AppController.clearSearch(_:)), "k", app, [.command, .shift])
        searchMenu.addItem(.separator())
        addToggle(searchMenu, "Match Case", #selector(AppController.toggleMatchCase(_:)), app)
        addToggle(searchMenu, "Match Whole Word", #selector(AppController.toggleWholeWord(_:)), app)
        addToggle(searchMenu, "Match Path", #selector(AppController.toggleMatchPath(_:)), app)
        addToggle(searchMenu, "Match Diacritics", #selector(AppController.toggleDiacritics(_:)), app)
        addToggle(searchMenu, "Enable Regular Expressions", #selector(AppController.toggleRegex(_:)), app)
        searchMenu.addItem(.separator())
        let filterItem = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
        let filterMenu = NSMenu(title: "Filter")
        for kind in FilterKind.allCases {
            let item = NSMenuItem(title: kind.rawValue, action: #selector(AppController.setFilter(_:)), keyEquivalent: "")
            item.target = app
            filterMenu.addItem(item)
        }
        filterItem.submenu = filterMenu
        searchMenu.addItem(filterItem)

        // MARK: View
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let modeItem = NSMenuItem(title: "View Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "View Mode")
        let modeShortcuts = ["1", "2", "3", "4"]
        for (index, mode) in ViewMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(AppController.setViewMode(_:)),
                                  keyEquivalent: index < modeShortcuts.count ? modeShortcuts[index] : "")
            item.tag = mode.rawValue
            item.target = app
            if let image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil) {
                item.image = image
            }
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        viewMenu.addItem(modeItem)
        addToggle(viewMenu, "Use File Previews in Icon Views", #selector(AppController.toggleThumbnails(_:)), app)
        viewMenu.addItem(.separator())
        addToggle(viewMenu, "Show Hidden Files", #selector(AppController.toggleShowHidden(_:)), app, "h", [.command, .shift])
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        for field in SortField.allCases {
            let item = NSMenuItem(title: field.title, action: #selector(AppController.setSort(_:)), keyEquivalent: "")
            item.tag = field.rawValue
            item.target = app
            sortMenu.addItem(item)
        }
        sortMenu.addItem(.separator())
        let asc = NSMenuItem(title: "Ascending", action: #selector(AppController.setSortAscending(_:)), keyEquivalent: "")
        asc.target = app
        sortMenu.addItem(asc)
        let desc = NSMenuItem(title: "Descending", action: #selector(AppController.setSortDescending(_:)), keyEquivalent: "")
        desc.target = app
        sortMenu.addItem(desc)
        sortItem.submenu = sortMenu
        viewMenu.addItem(sortItem)
        viewMenu.addItem(.separator())
        add(viewMenu, "Refresh Results", #selector(AppController.refreshResults(_:)), "l", app)

        // MARK: Index
        let indexItem = NSMenuItem()
        main.addItem(indexItem)
        let indexMenu = NSMenu(title: "Index")
        indexItem.submenu = indexMenu
        add(indexMenu, "Rebuild Index Now", #selector(AppController.rebuildIndex(_:)), "b", app, [.command, .shift])
        add(indexMenu, "Save Index Cache", #selector(AppController.saveIndex(_:)), "", app)
        add(indexMenu, "Delete Index Cache", #selector(AppController.deleteCache(_:)), "", app)
        indexMenu.addItem(.separator())
        add(indexMenu, "Index Settings…", #selector(AppController.showSettings(_:)), "", app)

        // MARK: Help
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        add(helpMenu, "Everything Search Syntax", #selector(AppController.showSyntax(_:)), "?", app)

        return main
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                            _ target: AnyObject, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        menu.addItem(item)
        return item
    }

    private static func addToggle(_ menu: NSMenu, _ title: String, _ action: Selector,
                                  _ target: AnyObject,
                                  _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = add(menu, title, action, key, target, modifiers)
        item.state = .off
    }
}
