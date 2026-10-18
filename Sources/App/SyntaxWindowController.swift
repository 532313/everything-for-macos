import AppKit

/// Scrollable cheat sheet for the Everything query syntax.
final class SyntaxWindowController: NSWindowController {

    static let shared = SyntaxWindowController()

    private static let rows: [(String, String)] = [
        ("alpha beta", "AND — every term must match"),
        ("alpha|beta", "OR"),
        ("!alpha", "NOT"),
        ("(a|b) c", "grouping — angle brackets work too: <a|b> c"),
        ("\"exact phrase\"", "quoted phrase"),
        ("*.png  report?.txt", "wildcards: * any run, ? one character"),
        ("ext:png;jpg", "extension list"),
        ("ext:", "files with no extension"),
        ("file:   folder:", "files only / folders only"),
        ("size:>10mb", "size comparisons (b, kb, mb, gb, tb)"),
        ("size:1kb..1mb", "size range"),
        ("size:empty", "zero byte files"),
        ("size:tiny … gigantic", "named buckets (10 KB / 100 KB / 1 MB / 16 MB / 128 MB)"),
        ("dm:today", "modified today (yesterday, thisweek, lastmonth, thisyear…)"),
        ("dm:>2024-01-01", "modified after a date"),
        ("dm:2024-01-01..2024-02-01", "modified date range"),
        ("dc:thisyear", "date created"),
        ("path:src", "match anywhere in the full path"),
        ("parent:build", "match the parent folder name"),
        ("depth:2  depth:1..3", "depth relative to the indexed root"),
        ("startwith:log  endwith:.bak", "anchored name match"),
        ("wfn:*.md", "whole-filename wildcard (anchored, * required)"),
        ("regex:^main.*\\.swift$", "regular expression"),
        ("case:README", "match case for that term"),
        ("wholeword:cat", "whole word only for that term"),
        ("hidden:  nohidden:", "hidden attribute"),
        ("symlink:  package:  exec:", "other attributes"),
        ("type:audio  type:source", "kind filters (audio, video, document, picture…)"),
        ("sort:size  descending:", "sorting inside the query"),
        ("!ext:tmp !path:/caches/", "combine exclusions freely")
    ]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Everything Search Syntax"
        window.center()
        self.init(window: window)
        build()
    }

    private func build() {
        guard let window = window else { return }
        let text = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let body = NSFont.systemFont(ofSize: 12)
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ]

        text.append(NSAttributedString(string: "Everything Search Syntax\n", attributes: heading))
        text.append(NSAttributedString(
            string: "Space is AND, | is OR, ! is NOT. The same syntax works in the search box and in everything-cli.\n\n",
            attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))

        for (syntax, explanation) in SyntaxWindowController.rows {
            text.append(NSAttributedString(string: syntax.padding(toLength: 30, withPad: " ", startingAt: 0),
                                           attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
            text.append(NSAttributedString(string: "  " + explanation + "\n",
                                           attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
        }

        text.append(NSAttributedString(
            string: "\nTips\n",
            attributes: heading))
        let tips = [
            "Type anywhere — keystrokes in the result list are forwarded to the search box.",
            "Space shows a Quick Look preview, Return opens, ⌘R reveals in Finder, ⌘⌫ moves to the Trash.",
            "Click a column header to sort; the search runs again so the top-N selection follows the new order.",
            "While the index is being built the status bar shows progress; searches keep working on the partial index.",
            "Everything needs Full Disk Access (System Settings ▸ Privacy & Security) to index protected folders such as Mail, Messages and other apps' containers."
        ]
        for tip in tips {
            text.append(NSAttributedString(string: "• " + tip + "\n",
                                           attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
        }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = true
        textView.textStorage?.setAttributedString(text)
        textView.textContainerInset = NSSize(width: 16, height: 16)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = true

        let content = NSView()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
    }
}
