import AppKit
import UniformTypeIdentifiers

/// Read-only text view for rendered Markdown. Keeps the text column centered
/// with a comfortable maximum width, opens Markdown files dropped on it,
/// hosts the horizontally scrolling views of wide code blocks and tables,
/// and handles clicks on task checkboxes and `<details>` summaries.
final class PreviewTextView: NSTextView {
    var maxReadingWidth: CGFloat? {
        didSet {
            if maxReadingWidth != oldValue { updateInsets(for: frame.width) }
        }
    }

    /// Called when the width of the text column changes.
    var onColumnWidthChange: ((CGFloat) -> Void)?
    /// Click on a task checkbox: relative source line, character index.
    var onTaskToggle: ((Int, Int) -> Void)?
    /// Click on a `<details>` summary: toggle identifier, character index.
    var onDetailsToggle: ((String, Int) -> Void)?
    /// Link handling for text inside overlays.
    weak var overlayLinkDelegate: NSTextViewDelegate?

    /// Width available to text (container width minus line fragment padding).
    var columnWidth: CGFloat {
        guard let container = textContainer else { return frame.width }
        return max(container.size.width - container.lineFragmentPadding * 2, 50)
    }

    private var lastColumnWidth: CGFloat = 0

    // MARK: User scrolling (drives the editor in Split View)

    private var lastUserScroll = Date.distantPast
    var isLiveScrolling = false

    /// True while the user scrolls this view (wheel, trackpad, scroller, keys).
    var isUserScrolling: Bool {
        isLiveScrolling || Date().timeIntervalSince(lastUserScroll) < 0.5
    }

    override func scrollWheel(with event: NSEvent) {
        lastUserScroll = Date()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        lastUserScroll = Date()
        super.keyDown(with: event)
    }

    private let minHorizontalInset: CGFloat = 28
    private let verticalInset: CGFloat = 24

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL])
        observeTextStorage()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        observeTextStorage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        updateInsets(for: newSize.width)
        super.setFrameSize(newSize)
        notifyColumnWidth()
    }

    private func updateInsets(for width: CGFloat) {
        var horizontal = minHorizontalInset
        if let maxReadingWidth {
            horizontal = max(minHorizontalInset, ((width - maxReadingWidth) / 2).rounded(.down))
        }
        let inset = NSSize(width: horizontal, height: verticalInset)
        if textContainerInset != inset {
            textContainerInset = inset
            notifyColumnWidth()
        }
    }

    private func notifyColumnWidth() {
        let width = columnWidth
        guard abs(width - lastColumnWidth) >= 1 else { return }
        lastColumnWidth = width
        onColumnWidthChange?(width)
    }

    // MARK: Clickable checkboxes and summaries

    private func characterIndex(atViewPoint point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let storage = textStorage, let index = characterIndex(atViewPoint: convert(event.locationInWindow, from: nil)),
           storage.attribute(.link, at: index, effectiveRange: nil) == nil {
            if let line = storage.attribute(.mdrTaskLine, at: index, effectiveRange: nil) as? Int {
                onTaskToggle?(line, index)
                return
            }
            if let id = storage.attribute(.mdrDetailsToggle, at: index, effectiveRange: nil) as? String {
                onDetailsToggle?(id, index)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Overlays for wide blocks

    private final class Overlay {
        weak var cell: ScrollableBlockCell?
        let view: HorizontalOverlayScrollView
        var drawn = false

        init(cell: ScrollableBlockCell, view: HorizontalOverlayScrollView) {
            self.cell = cell
            self.view = view
        }
    }

    private var overlays: [ObjectIdentifier: Overlay] = [:]

    /// Called by a `ScrollableBlockCell` while it draws: shows its scroll
    /// view at `frame`. View changes are deferred until drawing finishes.
    func placeOverlay(for cell: ScrollableBlockCell, frame: NSRect) {
        let key = ObjectIdentifier(cell)
        let target = frame.integral
        if let overlay = overlays[key], overlay.cell === cell {
            overlay.drawn = true
            if overlay.view.frame != target || overlay.view.isHidden {
                DispatchQueue.main.async {
                    overlay.view.frame = target
                    overlay.view.isHidden = false
                }
            }
            return
        }
        let view = HorizontalOverlayScrollView.make(for: cell, linkDelegate: overlayLinkDelegate)
        let overlay = Overlay(cell: cell, view: view)
        overlay.drawn = true
        overlays[key] = overlay
        view.frame = target
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overlays[key] === overlay else { return }
            self.addSubview(view)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for overlay in overlays.values { overlay.drawn = false }
        super.draw(dirtyRect)
        var removed: [ObjectIdentifier] = []
        for (key, overlay) in overlays {
            if overlay.cell == nil {
                removed.append(key)
            } else if !overlay.drawn, !overlay.view.isHidden, overlay.view.frame.intersects(dirtyRect) {
                // Its attachment moved away or was replaced.
                let view = overlay.view
                DispatchQueue.main.async { view.isHidden = true }
            }
        }
        if !removed.isEmpty {
            let views = removed.compactMap { overlays[$0]?.view }
            for key in removed { overlays[key] = nil }
            DispatchQueue.main.async { views.forEach { $0.removeFromSuperview() } }
        }
    }

    private func scrollableCell(at index: Int) -> ScrollableBlockCell? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return (storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)?
            .attachmentCell as? ScrollableBlockCell
    }

    /// Frame the wide block's attachment at `index` is drawn in.
    func attachmentFrame(at index: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        layoutManager.ensureLayout(forGlyphRange: glyphs)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        // The bounding rect also covers the line fragment padding.
        let size = layoutManager.attachmentSize(forGlyphAt: glyphs.location)
        if size.width > 0 { rect.size = size }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The text view of the overlay for the wide block at `index`. With
    /// `create`, an overlay that has not been drawn yet is placed now.
    func overlayTextView(forAttachmentAt index: Int, create: Bool = true) -> NSTextView? {
        guard let cell = scrollableCell(at: index) else { return nil }
        let key = ObjectIdentifier(cell)
        if create, overlays[key]?.cell !== cell || overlays[key]?.view.superview !== self || overlays[key]?.view.isHidden == true,
           let frame = attachmentFrame(at: index) {
            let target = cell.contentFrame(in: frame).integral
            if overlays[key]?.cell !== cell {
                overlays[key] = Overlay(cell: cell, view: HorizontalOverlayScrollView.make(for: cell, linkDelegate: overlayLinkDelegate))
            }
            if let view = overlays[key]?.view {
                view.frame = target
                view.isHidden = false
                if view.superview !== self { addSubview(view) }
            }
        }
        guard let overlay = overlays[key], overlay.cell === cell else { return nil }
        return overlay.view.documentView as? NSTextView
    }

    /// Character index of the wide block whose overlay shows `view`.
    func attachmentIndex(ofOverlayTextView view: NSTextView) -> Int? {
        guard let cell = overlays.values.first(where: { $0.view.documentView === view })?.cell,
              let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? NSTextAttachment)?.attachmentCell === cell {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: Find (including the text of wide blocks)

    private var findClientStorage: PreviewFindClient?
    private var textFinderStorage: NSTextFinder?

    var findClient: PreviewFindClient {
        if let findClientStorage { return findClientStorage }
        let client = PreviewFindClient(textView: self)
        findClientStorage = client
        return client
    }

    private var textFinder: NSTextFinder {
        if let textFinderStorage { return textFinderStorage }
        let finder = NSTextFinder()
        finder.client = findClient
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = true
        textFinderStorage = finder
        return finder
    }

    private func observeTextStorage() {
        NotificationCenter.default.addObserver(self, selector: #selector(readerTextDidChange(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: textStorage)
    }

    @objc private func readerTextDidChange(_ note: Notification) {
        findClientStorage?.invalidate()
        textFinderStorage?.noteClientStringWillChange()
    }

    private static func finderAction(_ sender: Any?) -> NSTextFinder.Action? {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? (sender as? NSControl)?.tag
        return tag.flatMap(NSTextFinder.Action.init(rawValue:))
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let action = Self.finderAction(sender) else { return }
        textFinder.findBarContainer = enclosingScrollView
        textFinder.performAction(action)
    }

    override func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)) {
            guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
            textFinder.findBarContainer = enclosingScrollView
            return textFinder.validateAction(action)
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Opening dropped files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.markdownURLs(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.markdownURLs(in: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDrop.markdownURLs(in: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        FileDrop.open(urls)
        return true
    }
}

enum FileDrop {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "text", "txt"]

    static func markdownURLs(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { markdownExtensions.contains($0.pathExtension.lowercased()) }
    }

    static func open(_ urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}

/// Opens link destinations clicked in the reader. Markdown files open in this
/// app; web and mail links open in the default app; other local files open
/// in their default app, except applications and executables, which are only
/// revealed in Finder. Unknown URL schemes require confirmation.
enum LinkOpener {
    static func open(_ destination: String, baseURL: URL?, inDocumentAnchor: (String) -> Void) {
        if destination.hasPrefix("#") {
            inDocumentAnchor(String(destination.dropFirst()).removingPercentEncoding ?? String(destination.dropFirst()))
            return
        }
        guard let url = LinkResolver.resolve(destination, relativeTo: baseURL) else {
            NSSound.beep()
            return
        }
        if url.isFileURL {
            openFile(url)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        default:
            let alert = NSAlert()
            alert.messageText = "Open this link in another application?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    private static func openFile(_ url: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            if FolderAccess.isSandboxed, !FolderAccess.isCovered(url) {
                // Sandboxed build: the file may exist but needs folder access.
                let alert = NSAlert()
                alert.messageText = "Markdown Reader needs access to the folder of the linked file."
                alert.informativeText = url.path
                alert.addButton(withTitle: "Grant Access…")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    FolderAccess.requestAccess(suggesting: url.deletingLastPathComponent(), window: nil) { granted in
                        if granted, fm.fileExists(atPath: url.path) { openFile(url) }
                    }
                }
                return
            }
            let alert = NSAlert()
            alert.messageText = "The linked file could not be found."
            alert.informativeText = url.path
            alert.runModal()
            return
        }
        if !isDirectory.boolValue, FileDrop.markdownExtensions.contains(url.pathExtension.lowercased()) {
            FileDrop.open([url])
            return
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let isApplicationLike = isDirectory.boolValue
            || type?.conforms(to: .application) == true
            || type?.conforms(to: .executable) == true
            || type?.conforms(to: .script) == true
            || fm.isExecutableFile(atPath: url.path)
        if isApplicationLike {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
