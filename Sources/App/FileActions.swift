import Foundation
import AppKit
import Quartz

/// File operations behind the context menu / menu bar / keyboard.
enum FileActions {

    static func open(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }

    static func open(with app: URL, urls: [URL]) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config)
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func openInTerminal(_ urls: [URL]) {
        let dirs = urls.map { url -> URL in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
            return url.deletingLastPathComponent()
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open(dirs, withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func trash(_ urls: [URL], completion: @escaping (Bool) -> Void) {
        guard !urls.isEmpty else { completion(false); return }
        var failed: [String] = []
        var done = 0
        for url in urls {
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error = error { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                done += 1
                if done == urls.count {
                    DispatchQueue.main.async {
                        if !failed.isEmpty {
                            let alert = NSAlert()
                            alert.messageText = "Some items could not be moved to the Trash"
                            alert.informativeText = failed.prefix(8).joined(separator: "\n")
                            alert.runModal()
                        }
                        completion(failed.isEmpty)
                    }
                }
            }
        }
    }

    static func getInfo(_ urls: [URL]) {
        guard let first = urls.first else { return }
        // Finder's Get Info window cannot be invoked directly; the closest
        // supported route is asking Finder to reveal the item.
        NSWorkspace.shared.activateFileViewerSelecting([first])
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copyFilesToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    static func exportCSV(results: ResultSet, to url: URL) throws {
        var out = "Name,Path,Size,Date Modified,Date Created,Extension,Type\n"
        let iso = ISO8601DateFormatter()
        for i in 0..<results.count {
            let e = results.entries[i]
            let fields = [
                results.name(i),
                results.path(i),
                e.isDir ? "" : String(e.size),
                e.mtime > 0 ? iso.string(from: Date(timeIntervalSince1970: TimeInterval(e.mtime))) : "",
                e.btime > 0 ? iso.string(from: Date(timeIntervalSince1970: TimeInterval(e.btime))) : "",
                results.ext(i),
                e.isDir ? "Folder" : "File"
            ]
            out += fields.map(csvEscape).joined(separator: ",") + "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

/// Quick Look (space bar) support.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var urls: [URL] = []

    func toggle(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}
