import AppKit
import Quartz
import AVFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// NSCollectionView based icon / large icon view with real Quick Look
/// thumbnails (images, PDFs, movies, …) falling back to the file type icon.
final class ResultsCollectionView: NSCollectionView {
    private var retainedMenuTarget: MenuTarget?

    override func keyDown(with event: NSEvent) {
        if ResultsKeyboard.handle(event) { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            AppController.shared.openSelection(nil)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point), !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            (delegate as? IconGridController)?.pushSelection()
        }
        guard !AppController.shared.selectedRows.isEmpty else { return nil }
        let target = MenuTarget()
        retainedMenuTarget = target
        return ResultsContextMenu.build(target: target)
    }
}

/// Container view that reports appearance changes (the item is not an NSView).
final class GridItemContainerView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// One icon cell: image + up to three lines of name, plus a small size caption
/// in the large mode.
final class ResultGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ResultGridItem")

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private var imageSide: CGFloat = 64
    private var row = -1
    private var representedPath = ""
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var labelHeight: NSLayoutConstraint!
    private var iconTop: NSLayoutConstraint!
    private var captionTop: NSLayoutConstraint!
    private var captionHeight: NSLayoutConstraint!

    override func loadView() {
        let container = GridItemContainerView()
        container.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 0

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        caption.alignment = .center
        caption.font = NSFont.systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(label)
        container.addSubview(caption)
        iconTop = iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 64)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: 64)
        labelHeight = label.heightAnchor.constraint(equalToConstant: 28)
        NSLayoutConstraint.activate([
            iconTop,
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconWidth,
            iconHeight,
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
            labelHeight,
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            caption.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -3)
        ])
        captionTop = caption.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1)
        captionHeight = caption.heightAnchor.constraint(equalToConstant: 12)
        captionTop.isActive = true
        captionHeight.isActive = true
        view = container
    }

    func configure(row: Int, mode: ViewMode, image: NSImage?, name: String,
                   path: String, captionText: String) {
        self.row = row
        // The *path* identifies the cell: the async thumbnail is only applied
        // when the cell still represents the same file.
        self.representedPath = path
        if imageSide != mode.iconSide {
            imageSide = mode.iconSide
            iconTop.constant = mode == .iconsLarge ? 10 : 6
            iconWidth.constant = mode.iconSide
            iconHeight.constant = mode.iconSide
        }
        labelHeight.constant = CGFloat(mode.labelLines) * (mode.itemFontSize + 3)
        // Keep the caption collapsed outside the large mode: otherwise the
        // required constraints exceed the item height and AppKit squashes the
        // icon instead of the (invisible) caption.
        let showsCaption = (mode == .iconsLarge)
        captionHeight.constant = showsCaption ? 12 : 0
        captionTop.constant = showsCaption ? 1 : 0
        iconView.image = image
        label.stringValue = name
        label.font = NSFont.systemFont(ofSize: mode.itemFontSize)
        label.maximumNumberOfLines = mode.labelLines
        caption.stringValue = mode == .iconsLarge ? captionText : ""
        caption.isHidden = mode != .iconsLarge
        updateSelectionAppearance()
    }

    func setImage(_ image: NSImage) {
        iconView.image = image
    }

    var path: String { representedPath }

    /// Diagnostics for the UI smoke test.
    var debugState: [String: Any] {
        let labelFrame = label.convert(label.bounds, to: view)
        let iconFrame = iconView.convert(iconView.bounds, to: view)
        return [
            "text": label.stringValue,
            "textColor": label.textColor.map { "\($0)" } ?? "nil",
            "appearance": "\(view.effectiveAppearance.name.rawValue)",
            "labelFrame": ["x": Int(labelFrame.origin.x), "y": Int(labelFrame.origin.y),
                           "w": Int(labelFrame.width), "h": Int(labelFrame.height)],
            "iconFrame": ["x": Int(iconFrame.origin.x), "y": Int(iconFrame.origin.y),
                          "w": Int(iconFrame.width), "h": Int(iconFrame.height)],
            "containerSize": ["w": Int(view.bounds.width), "h": Int(view.bounds.height)],
            "hasImage": iconView.image != nil,
            "labelHidden": label.isHidden,
            "selected": isSelected
        ]
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelectionAppearance() }
    }

    /// Explicit colours: dynamic catalog colours resolve against the item's
    /// appearance context, which inside a layer-backed collection view item can
    /// disagree with the visible background (white text on a white grid).
    private func updateSelectionAppearance() {
        let active = isSelected || highlightState == .forSelection
        view.layer?.backgroundColor = active
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.9).cgColor
            : NSColor.clear.cgColor
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let emphasized = view.window?.isKeyWindow ?? true
        if active && emphasized {
            label.textColor = .white
            caption.textColor = NSColor.white.withAlphaComponent(0.85)
        } else {
            label.textColor = isDark ? .white : .black
            caption.textColor = isDark ? NSColor.white.withAlphaComponent(0.65) : NSColor.darkGray
        }
    }

    fileprivate func appearanceChanged() {
        updateSelectionAppearance()
    }
}

/// Data source / delegate for the icon grid: lazy rows, asynchronous thumbnails
/// with a bounded cache.
final class IconGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {

    weak var collectionView: NSCollectionView?
    var mode: ViewMode = .icons {
        didSet { if mode != oldValue { cache.removeAll(); order.removeAll() } }
    }
    var usePreviews = true {
        didSet { if usePreviews != oldValue { cache.removeAll(); order.removeAll() } }
    }

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private var inflight = Set<String>()
    private let cacheLimit = 1200

    func attach(_ collectionView: NSCollectionView) {
        self.collectionView = collectionView
        collectionView.dataSource = self
        collectionView.delegate = self
    }

    // MARK: data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        AppController.shared.results.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ResultGridItem.identifier,
                                           for: indexPath)
        guard let gridItem = item as? ResultGridItem else { return item }
        let app = AppController.shared
        let row = indexPath.item
        guard row < app.results.count else { return gridItem }
        let entry = app.results.entries[row]
        let name = app.name(row)
        let caption = entry.isDir ? "Folder" : app.sizeText(row)
        let key = cacheKey(row: row)
        let image = cache[key] ?? IconCache.shared.icon(extension: app.ext(row),
                                                        isDirectory: entry.isDir,
                                                        isPackage: entry.isPackage)
        gridItem.configure(row: row, mode: mode, image: image, name: name,
                           path: app.path(row), captionText: caption)
        if usePreviews && cache[key] == nil {
            requestThumbnail(row: row, key: key, gridItem: gridItem)
        }
        return gridItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        pushSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        pushSelection()
    }

    func pushSelection() {
        let rows = collectionView?.selectionIndexPaths.map { $0.item } ?? []
        AppController.shared.selectedRows = IndexSet(rows)
    }

    func selectAll() {
        guard let collectionView = collectionView, AppController.shared.results.count > 0 else { return }
        var paths = Set<IndexPath>()
        for i in 0..<AppController.shared.results.count {
            paths.insert(IndexPath(item: i, section: 0))
        }
        collectionView.selectionIndexPaths = paths
        pushSelection()
    }

    func applySelection(_ rows: IndexSet) {
        guard let collectionView = collectionView else { return }
        collectionView.selectionIndexPaths = Set(rows.map { IndexPath(item: $0, section: 0) })
    }

    func reload() {
        collectionView?.reloadData()
    }

    // MARK: thumbnails

    private func cacheKey(row: Int) -> String {
        "\(AppController.shared.path(row))|\(Int(mode.iconSide))|\(usePreviews ? "t" : "i")"
    }

    private func requestThumbnail(row: Int, key: String, gridItem: ResultGridItem) {
        guard !inflight.contains(key) else { return }
        let app = AppController.shared
        guard row < app.results.count else { return }
        let entry = app.results.entries[row]
        let path = app.path(row)
        let side = mode.iconSide

        if entry.isDir || !usePreviews {
            store(key: key, image: IconCache.shared.icon(extension: app.ext(row),
                                                         isDirectory: entry.isDir,
                                                         isPackage: entry.isPackage),
                  gridItem: gridItem, path: path)
            return
        }

        inflight.insert(key)
        let type = UTType(filenameExtension: app.ext(row))
        if type?.conforms(to: .audiovisualContent) == true {
            // Video: Quick Look frequently returns only the generic film icon, so
            // ask AVFoundation for a real poster frame first.
            requestVideoFrame(path: path, key: key, gridItem: gridItem, side: side)
        } else {
            requestPreviewThumbnail(path: path, key: key, gridItem: gridItem, side: side)
        }
    }

    /// Poster frame for a movie (falls back to Quick Look, then to the file icon).
    private func requestVideoFrame(path: String, key: String, gridItem: ResultGridItem, side: CGFloat) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side * 2, height: side * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        Task { [weak self] in
            var frame: CGImage?
            for seconds in [1.0, 0.0] {
                if let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                    frame = result.image
                    break
                }
            }
            let image = frame.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let image = image {
                    self.store(key: key, image: image, gridItem: gridItem, path: path)
                } else {
                    self.requestPreviewThumbnail(path: path, key: key, gridItem: gridItem, side: side)
                }
            }
        }
    }

    /// Quick Look preview for everything else (documents, images, archives, …).
    private func requestPreviewThumbnail(path: String, key: String, gridItem: ResultGridItem, side: CGFloat) {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: side * 2, height: side * 2),
                                                   scale: 1,
                                                   representationTypes: [.thumbnail, .icon])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let self = self else { return }
            // QLThumbnailRepresentation.nsImage reports a 0x0 size, so build the
            // image from the CGImage it actually produced.
            let image = representation.map { NSImage(cgImage: $0.cgImage,
                                                     size: NSSize(width: $0.cgImage.width,
                                                                  height: $0.cgImage.height)) }
            DispatchQueue.main.async {
                self.store(key: key, image: image, gridItem: gridItem, path: path)
            }
        }
    }

    private func store(key: String, image: NSImage?, gridItem: ResultGridItem, path: String) {
        inflight.remove(key)
        if let image = image {
            if cache.count >= cacheLimit {
                let drop = min(300, order.count)
                for stale in order.prefix(drop) { cache.removeValue(forKey: stale) }
                order.removeFirst(drop)
            }
            cache[key] = image
            order.append(key)
        }
        // Only touch the cell if it still shows the same file (it may have been
        // recycled for another row while the request was in flight).
        if gridItem.path == path, let image = image {
            gridItem.setImage(image)
        }
    }
}
