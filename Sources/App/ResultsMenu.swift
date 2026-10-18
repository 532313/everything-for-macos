import AppKit

/// Shared keyboard behaviour for the result views (table and icon grid), so both
/// behave exactly like Everything: space previews, return opens, plain typing is
/// forwarded to the search field.
enum ResultsKeyboard {

    /// - Returns: true when the event was consumed.
    static func handle(_ event: NSEvent) -> Bool {
        let app = AppController.shared
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if chars == " " && flags.isEmpty { app.quickLook(nil); return true }
        if (chars == "\r" || chars == "\n") && flags.isEmpty { app.openSelection(nil); return true }
        if chars == "\u{1b}" { app.clearSearch(nil); return true }
        if flags == .command && (chars == "\u{8}" || chars == "\u{7F}") {
            app.trashSelection(nil)
            return true
        }
        if flags == [.command, .shift], chars.lowercased() == "c" { app.copyPaths(nil); return true }
        if flags == [.command, .option], chars.lowercased() == "c" { app.copyFiles(nil); return true }
        if flags == .command, let scalar = chars.lowercased().first {
            switch scalar {
            case "r": app.revealSelection(nil); return true
            case "o": app.openSelection(nil); return true
            case "c": app.copyNames(nil); return true
            case "a": MainWindowController.shared.selectAllRows(); return true
            case "y": app.quickLook(nil); return true
            case "i": app.getInfo(nil); return true
            default: break
            }
        }
        // Forward plain typing to the search box so the user never has to click
        // back into it.
        if flags.isEmpty || flags == .shift,
           let first = chars.unicodeScalars.first, first.value >= 32 {
            MainWindowController.shared.typeIntoSearch(chars)
            return true
        }
        return false
    }
}

/// Target for the shared result context menu (used by both result views).
final class MenuTarget: NSObject {
    private var app: AppController { AppController.shared }

    @objc func open(_ sender: Any?) { app.openSelection(nil) }
    @objc func quickLook(_ sender: Any?) { app.quickLook(nil) }
    @objc func reveal(_ sender: Any?) { app.revealSelection(nil) }
    @objc func terminal(_ sender: Any?) { app.openInTerminal(nil) }
    @objc func copyNames(_ sender: Any?) { app.copyNames(nil) }
    @objc func copyPaths(_ sender: Any?) { app.copyPaths(nil) }
    @objc func copyFiles(_ sender: Any?) { app.copyFiles(nil) }
    @objc func trash(_ sender: Any?) { app.trashSelection(nil) }

    @objc func openWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let urls = app.selectedURLs
        guard !urls.isEmpty else { return }
        FileActions.open(with: appURL, urls: urls)
    }
}

enum ResultsContextMenu {

    /// Builds "Open / Open With / Quick Look / …" for the current selection.
    static func build(target: MenuTarget) -> NSMenu {
        let app = AppController.shared
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            menu.addItem(item)
        }
        add("Open", #selector(MenuTarget.open(_:)))
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let sample = app.selectedURLs.first ?? URL(fileURLWithPath: "/")
        for candidate in NSWorkspace.shared.urlsForApplications(toOpen: sample).prefix(12) {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: candidate.path),
                                  action: #selector(MenuTarget.openWith(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = candidate
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            submenu.addItem(NSMenuItem(title: "No applications found", action: nil, keyEquivalent: ""))
        }
        openWith.submenu = submenu
        menu.addItem(openWith)
        menu.addItem(.separator())
        add("Quick Look", #selector(MenuTarget.quickLook(_:)), " ")
        add("Show in Finder", #selector(MenuTarget.reveal(_:)))
        add("Open in Terminal", #selector(MenuTarget.terminal(_:)))
        menu.addItem(.separator())
        add("Copy Name", #selector(MenuTarget.copyNames(_:)))
        add("Copy Full Path", #selector(MenuTarget.copyPaths(_:)))
        add("Copy File", #selector(MenuTarget.copyFiles(_:)))
        menu.addItem(.separator())
        add("Move to Trash", #selector(MenuTarget.trash(_:)))
        return menu
    }
}
