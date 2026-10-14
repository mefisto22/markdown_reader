import AppKit

/// Hosts the reader, the editor or both side by side, plus the status bar.
/// Reader and editor are created lazily, so opening a file in Reader mode
/// never pays for the editor (and vice versa).
final class DocumentContentViewController: NSViewController, NSSplitViewDelegate {
    let document: MarkdownDocument
    let statusBar = StatusBarView()
    var onHeadingsChanged: (([OutlineHeading]) -> Void)?

    private(set) var mode: ViewMode?
    private var preview: PreviewController?
    private var editor: EditorController?
    private let container = NSView()
    private let splitView = NSSplitView()
    private var backgroundWork: DispatchWorkItem?
    private var cursorWork: DispatchWorkItem?
    private var isSyncing = false
    private var isApplyingSplitPosition = false
    private var lastHeadings: [OutlineHeading] = []

    init(document: MarkdownDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        backgroundWork?.cancel()
        cursorWork?.cancel()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false
        let status = statusBar
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
        ])

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        view = root
        statusBar.encoding = TextDecoding.displayName(document.encoding)

        NotificationCenter.default.addObserver(self, selector: #selector(documentTextDidChange(_:)),
                                               name: NSTextStorage.didProcessEditingNotification,
                                               object: document.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange),
                                               name: Preferences.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(encodingDidChange),
                                               name: MarkdownDocument.encodingDidChangeNotification, object: document)
        scheduleBackgroundWork(delay: 0)
    }

    // MARK: - Lazily created panes

    private func previewController() -> PreviewController {
        if let preview { return preview }
        let controller = PreviewController(document: document)
        controller.onHeadingsChanged = { [weak self] headings in self?.publishHeadings(headings) }
        controller.onRenderProgress = { [weak self] in self?.syncPreviewToEditor() }
        controller.scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(previewDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: controller.scrollView.contentView)
        preview = controller
        return controller
    }

    private func editorController() -> EditorController {
        if let editor { return editor }
        let controller = EditorController(document: document)
        controller.onSelectionChange = { [weak self] in self?.scheduleCursorUpdate() }
        controller.scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: controller.scrollView.contentView)
        editor = controller
        return controller
    }

    var editorTextView: NSTextView? { editor?.textView }
    var previewTextView: NSTextView? { preview?.textView }

    /// Called when the window closes.
    func tearDown() {
        editor?.detach()
        backgroundWork?.cancel()
        cursorWork?.cancel()
    }

    // MARK: - Modes

    private func install(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// Fractional source line at the top of the primary pane.
    private func currentTopLine() -> Double? {
        switch mode {
        case .reader?: return preview?.topSourceLine()
        case .editor?, .split?: return editor?.topSourceLine()
        case nil: return nil
        }
    }

    func setMode(_ newMode: ViewMode) {
        _ = view
        guard newMode != mode else { return }
        let line = currentTopLine()
        let previous = mode
        mode = newMode

        for subview in container.subviews { subview.removeFromSuperview() }
        for subview in splitView.arrangedSubviews { subview.removeFromSuperview() }

        switch newMode {
        case .reader:
            let p = previewController()
            install(p.scrollView)
            p.isActive = true
        case .editor:
            let e = editorController()
            install(e.scrollView)
            preview?.isActive = false
        case .split:
            let e = editorController()
            let p = previewController()
            e.scrollView.translatesAutoresizingMaskIntoConstraints = true
            p.scrollView.translatesAutoresizingMaskIntoConstraints = true
            splitView.addArrangedSubview(e.scrollView)
            splitView.addArrangedSubview(p.scrollView)
            install(splitView)
            container.layoutSubtreeIfNeeded()
            applySplitFraction()
            DispatchQueue.main.async { [weak self] in self?.applySplitFraction() }
            p.isActive = true
        }
        statusBar.cursor = newMode == .reader ? nil : editor?.cursorPosition()
        if newMode == .editor { scheduleBackgroundWork(delay: 0) }

        // Keep the reading position when switching.
        if let line, previous != nil {
            container.layoutSubtreeIfNeeded()
            switch newMode {
            case .reader: preview?.scrollToSourceLine(line)
            case .editor: editor?.scrollToSourceLine(line)
            case .split:
                editor?.scrollToSourceLine(line)
                if Preferences.shared.syncScrolling || previous == .reader { preview?.scrollToSourceLine(line) }
            }
        }
        focusPrimaryPane()
    }

    func focusPrimaryPane() {
        guard let window = view.window else { return }
        switch mode {
        case .reader?: if let tv = preview?.textView { window.makeFirstResponder(tv) }
        case .editor?, .split?: if let tv = editor?.textView { window.makeFirstResponder(tv) }
        case nil: break
        }
    }

    // MARK: - Split view

    private func applySplitFraction() {
        let width = splitView.bounds.width
        guard width > 0, splitView.arrangedSubviews.count == 2 else { return }
        isApplyingSplitPosition = true
        splitView.setPosition((width * Preferences.shared.splitFraction).rounded(), ofDividerAt: 0)
        isApplyingSplitPosition = false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 180)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 180)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // Keep the divider proportional when the window is resized.
        guard splitView.arrangedSubviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let left = splitView.arrangedSubviews[0]
        // Freshly installed (no meaningful old size yet): use the remembered ratio.
        let fraction = oldSize.width > 1 && left.frame.width > 1
            ? left.frame.width / max(oldSize.width - splitView.dividerThickness, 1)
            : Preferences.shared.splitFraction
        let available = splitView.bounds.width - splitView.dividerThickness
        let leftWidth = (available * fraction).rounded()
        left.frame = NSRect(x: 0, y: 0, width: leftWidth, height: splitView.bounds.height)
        splitView.arrangedSubviews[1].frame = NSRect(x: leftWidth + splitView.dividerThickness, y: 0,
                                                     width: available - leftWidth, height: splitView.bounds.height)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only remember positions the user chose by dragging the divider
        // (AppKit includes the divider index only for divider drags).
        guard !isApplyingSplitPosition, splitView.arrangedSubviews.count == 2,
              notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        let width = splitView.bounds.width
        guard width > 0 else { return }
        Preferences.shared.splitFraction = splitView.arrangedSubviews[0].frame.width / width
    }

    // MARK: - Synchronized scrolling (both directions)

    @objc private func editorDidScroll() {
        syncPreviewToEditor()
    }

    /// Only scrolling the user does in the preview drives the editor;
    /// re-rendering and the editor's own sync must not move the editor.
    @objc private func previewDidScroll() {
        guard let preview, preview.textView.isUserScrolling else { return }
        syncEditorToPreview()
    }

    private func syncPreviewToEditor() {
        guard mode == .split, Preferences.shared.syncScrolling, !isSyncing,
              let editor, let preview, !preview.textView.isUserScrolling else { return }
        isSyncing = true
        preview.scrollToSourceLine(editor.topSourceLine())
        isSyncing = false
    }

    private func syncEditorToPreview() {
        guard mode == .split, Preferences.shared.syncScrolling, !isSyncing,
              let editor, let preview else { return }
        isSyncing = true
        editor.scrollToSourceLine(preview.topSourceLine())
        isSyncing = false
    }

    @objc private func encodingDidChange() {
        statusBar.encoding = TextDecoding.displayName(document.encoding)
    }

    // MARK: - Outline navigation

    func reveal(_ heading: OutlineHeading) {
        switch mode {
        case .reader?:
            preview?.scrollToHeading(heading)
        case .editor?:
            editor?.reveal(line: heading.line)
        case .split?:
            editor?.reveal(line: heading.line)
            preview?.scrollToHeading(heading)
        case nil:
            break
        }
    }

    private func publishHeadings(_ headings: [OutlineHeading]) {
        guard headings != lastHeadings else { return }
        lastHeadings = headings
        onHeadingsChanged?(headings)
    }

    // MARK: - Statistics, outline (editor mode) and cursor

    @objc private func documentTextDidChange(_ note: Notification) {
        guard document.textStorage.editedMask.contains(.editedCharacters) else { return }
        let length = document.textStorage.length
        scheduleBackgroundWork(delay: length < 200_000 ? 0.3 : 0.8)
    }

    @objc private func preferencesDidChange() {
        syncPreviewToEditor()
    }

    private func scheduleBackgroundWork(delay: TimeInterval) {
        backgroundWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runBackgroundWork() }
        backgroundWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runBackgroundWork() {
        let text = String(document.textStorage.string)
        // The preview produces the outline whenever it is active.
        let needsOutline = mode == .editor || preview == nil
        statusBar.encoding = TextDecoding.displayName(document.encoding)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = TextStatistics.compute(text)
            let headings = needsOutline ? OutlineBuilder.headings(MarkdownParser.parse(text)) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusBar.statistics = stats
                if let headings, self.mode == .editor || self.preview == nil { self.publishHeadings(headings) }
            }
        }
        scheduleCursorUpdate()
    }

    private func scheduleCursorUpdate() {
        cursorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode != .reader, let editor = self.editor else { return }
            let position = editor.cursorPosition()
            if self.statusBar.cursor?.line != position.line || self.statusBar.cursor?.column != position.column {
                self.statusBar.cursor = position
            }
        }
        cursorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
