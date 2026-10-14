import AppKit

/// One window per document: an outline sidebar plus the content area.
/// Native window tabbing is enabled (Window ▸ Merge All Windows, or the
/// system "Prefer tabs" setting).
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private var contentController: DocumentContentViewController?
    private let outlineModel = OutlineModel()
    private weak var modeGroup: NSToolbarItemGroup?
    private var sidebarObservation: NSKeyValueObservation?

    private static let modeItemIdentifier = NSToolbarItem.Identifier("ViewMode")
    /// Top-left point for the next new window (standard cascading).
    private static var cascadePoint = NSPoint.zero

    init() {
        let size = Preferences.shared.windowSize ?? NSSize(width: 980, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.minSize = NSSize(width: 460, height: 320)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "MarkdownDocumentWindow"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        // Window restoration looks up the document's window by identifier;
        // without one a restored document would reopen without a window.
        window.identifier = NSUserInterfaceItemIdentifier("MarkdownDocumentWindow")
        window.isRestorable = true
        super.init(window: window)
        shouldCascadeWindows = true
        window.delegate = self

        let toolbar = NSToolbar(identifier: "DocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    override var document: AnyObject? {
        didSet {
            if let doc = document as? MarkdownDocument, contentController == nil { build(for: doc) }
        }
    }

    private func build(for document: MarkdownDocument) {
        guard let window else { return }
        let size = window.contentRect(forFrameRect: window.frame).size

        let sidebarHost = LazyOutlineViewController(model: outlineModel)
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 170
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        sidebar.isCollapsed = !Preferences.shared.showOutline

        let content = DocumentContentViewController(document: document)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320

        splitController.addSplitViewItem(sidebar)
        splitController.addSplitViewItem(contentItem)
        splitController.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = splitController
        window.setContentSize(size)
        positionNewWindow(window)

        sidebarItem = sidebar
        contentController = content
        if !sidebar.isCollapsed { sidebarHost.loadOutlineIfNeeded() }
        sidebarObservation = sidebar.observe(\.isCollapsed, options: [.new]) { item, _ in
            Preferences.shared.showOutline = !item.isCollapsed
            if !item.isCollapsed { sidebarHost.loadOutlineIfNeeded() }
        }

        outlineModel.onSelect = { [weak content] heading in content?.reveal(heading) }
        content.onHeadingsChanged = { [weak self] headings in self?.outlineModel.headings = headings }

        setMode(document.viewMode, animated: false)
    }

    /// Cascades new windows down and to the right of the current one.
    /// `cascadeTopLeft(from:)` moves the window to the given point and returns
    /// the point for the next window.
    private func positionNewWindow(_ window: NSWindow) {
        let anchor: NSPoint
        if let current = NSApp.mainWindow ?? NSApp.keyWindow, current !== window, current.isVisible {
            anchor = window.cascadeTopLeft(from: NSPoint(x: current.frame.minX, y: current.frame.maxY))
        } else if Self.cascadePoint != .zero {
            anchor = Self.cascadePoint
        } else {
            window.center()
            Self.cascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
            return
        }
        Self.cascadePoint = window.cascadeTopLeft(from: anchor)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        LaunchTrace.mark("showWindow")
        contentController?.focusPrimaryPane()
    }

    // MARK: - Modes

    func setMode(_ mode: ViewMode, animated: Bool = true) {
        contentController?.setMode(mode)
        markdownDocument?.viewMode = mode
        Preferences.shared.viewMode = mode
        modeGroup?.selectedIndex = ViewMode.allCases.firstIndex(of: mode) ?? 0
    }

    @IBAction func showReader(_ sender: Any?) { setMode(.reader) }
    @IBAction func showEditor(_ sender: Any?) { setMode(.editor) }
    @IBAction func showSplitView(_ sender: Any?) { setMode(.split) }

    @objc private func modeGroupChanged(_ sender: NSToolbarItemGroup) {
        let index = sender.selectedIndex
        guard ViewMode.allCases.indices.contains(index) else { return }
        setMode(ViewMode.allCases[index])
    }

    @IBAction func toggleSidebar(_ sender: Any?) {
        splitController.toggleSidebar(sender)
    }

    /// Sandboxed build: lets the user grant access to the document's folder
    /// so relative images and links work.
    @IBAction func grantFolderAccess(_ sender: Any?) {
        FolderAccess.requestAccess(suggesting: markdownDocument?.baseURL, window: window)
    }

    // MARK: - Font size

    /// The editor is targeted when it has focus; otherwise the reader.
    private var editorHasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView, let editor = contentController?.editorTextView else {
            return false
        }
        return responder === editor || responder.isDescendant(of: editor)
    }

    private func adjustFontSize(_ delta: CGFloat?) {
        let prefs = Preferences.shared
        if editorHasFocus {
            prefs.editorFontSize = delta.map { prefs.editorFontSize + $0 } ?? Preferences.defaultEditorFontSize
        } else {
            prefs.readerFontSize = delta.map { prefs.readerFontSize + $0 } ?? Preferences.defaultReaderFontSize
        }
    }

    @IBAction func makeTextLarger(_ sender: Any?) { adjustFontSize(1) }
    @IBAction func makeTextSmaller(_ sender: Any?) { adjustFontSize(-1) }
    @IBAction func makeTextStandardSize(_ sender: Any?) { adjustFontSize(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let mode = markdownDocument?.viewMode
        switch menuItem.action {
        case #selector(showReader(_:)):
            menuItem.state = mode == .reader ? .on : .off
        case #selector(showEditor(_:)):
            menuItem.state = mode == .editor ? .on : .off
        case #selector(showSplitView(_:)):
            menuItem.state = mode == .split ? .on : .off
        case #selector(toggleSidebar(_:)):
            menuItem.title = sidebarItem?.isCollapsed == false ? "Hide Outline" : "Show Outline"
        case #selector(makeTextSmaller(_:)):
            let size = editorHasFocus ? Preferences.shared.editorFontSize : Preferences.shared.readerFontSize
            return size > Preferences.fontSizeRange.lowerBound
        case #selector(makeTextLarger(_:)):
            let size = editorHasFocus ? Preferences.shared.editorFontSize : Preferences.shared.readerFontSize
            return size < Preferences.fontSizeRange.upperBound
        default:
            break
        }
        return true
    }

    // MARK: - NSWindowDelegate

    /// Text views register undo with the document's undo manager, which also
    /// drives the document's edited state and the close/save prompts.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        markdownDocument?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        rememberWindowSize()
        sidebarObservation = nil
        contentController?.tearDown()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberWindowSize()
    }

    private func rememberWindowSize() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        Preferences.shared.windowSize = window.contentRect(forFrameRect: window.frame).size
    }

    func windowDidBecomeKey(_ notification: Notification) {
        markdownDocument?.checkForExternalChanges()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.modeItemIdentifier else { return nil }
        let modes = ViewMode.allCases
        let images = modes.map { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.title) ?? NSImage() }
        let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
                                       labels: modes.map(\.title), target: self,
                                       action: #selector(modeGroupChanged(_:)))
        group.label = "View"
        group.paletteLabel = "View Mode"
        group.toolTip = "Reader (⌘1) · Editor (⌘2) · Split View (⌘3)"
        for (i, item) in group.subitems.enumerated() {
            item.toolTip = "\(modes[i].title) (⌘\(i + 1))"
        }
        group.selectedIndex = modes.firstIndex(of: markdownDocument?.viewMode ?? Preferences.shared.viewMode) ?? 0
        modeGroup = group
        return group
    }
}
