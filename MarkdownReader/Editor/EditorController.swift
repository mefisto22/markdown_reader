import AppKit

/// Owns the source editor. The text view edits the document's own text
/// storage directly; undo goes through the window's (= document's) undo
/// manager, which also drives the "Edited" state.
final class EditorController: NSObject, NSTextViewDelegate {
    let textView: EditorTextView
    let scrollView: NSScrollView
    let highlighter: SyntaxHighlighter
    private unowned let document: MarkdownDocument
    private var cachedLineIndex: LineIndex?
    private var appliedFont: NSFont?
    private var appliedHighlighting: Bool?
    private var appliedWrap: Bool?

    var onSelectionChange: (() -> Void)?

    init(document: MarkdownDocument) {
        self.document = document
        textView = TextKit1.makeTextView(EditorTextView.self, storage: document.textStorage)
        scrollView = TextKit1.makeScrollView(documentView: textView)
        highlighter = SyntaxHighlighter(storage: document.textStorage)
        super.init()

        document.textStorage.delegate = highlighter
        textView.highlighter = highlighter
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 14, height: 18)
        textView.setAccessibilityLabel("Markdown source")

        applyPreferences()

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange),
                                               name: Preferences.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChangeStorage(_:)),
                                               name: NSTextStorage.didProcessEditingNotification,
                                               object: document.textStorage)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Disconnects the editor from the document's text storage (window closing).
    func detach() {
        if document.textStorage.delegate === highlighter { document.textStorage.delegate = nil }
        if let layoutManager = textView.layoutManager {
            document.textStorage.removeLayoutManager(layoutManager)
        }
    }

    @objc private func preferencesDidChange() {
        applyPreferences()
    }

    @objc private func textDidChangeStorage(_ note: Notification) {
        if document.textStorage.editedMask.contains(.editedCharacters) { cachedLineIndex = nil }
    }

    private func applyPreferences() {
        let prefs = Preferences.shared
        let font = EditorStyle.font(size: prefs.editorFontSize, monospaced: prefs.editorMonospaced)
        if font != appliedFont || prefs.syntaxHighlighting != appliedHighlighting {
            appliedFont = font
            appliedHighlighting = prefs.syntaxHighlighting
            highlighter.isEnabled = prefs.syntaxHighlighting
            highlighter.updateFonts()
            textView.typingAttributes = highlighter.typingAttributes
            highlighter.rehighlightAll()
        }
        if prefs.wrapLines != appliedWrap {
            appliedWrap = prefs.wrapLines
            setWrapping(prefs.wrapLines)
        }
    }

    private func setWrapping(_ wrap: Bool) {
        guard let container = textView.textContainer else { return }
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    // MARK: - Line mapping

    private func lineIndex() -> LineIndex {
        if let cachedLineIndex { return cachedLineIndex }
        let index = LineIndex(document.textStorage.mutableString)
        cachedLineIndex = index
        return index
    }

    /// Fractional source line at the top of the editor.
    func topSourceLine() -> Double {
        guard document.textStorage.length > 0 else { return 0 }
        let index = lineIndex()
        let char = textView.topVisibleCharacterIndex(in: scrollView)
        let line = index.line(containing: char)
        let top = textView.lineTop(forCharacterAt: index.start(ofLine: line))
        let nextStart = index.start(ofLine: line + 1)
        let bottom = nextStart < document.textStorage.length ? textView.lineTop(forCharacterAt: nextStart) : textView.frame.height
        let visibleTop = scrollView.visibleDocumentTop
        let fraction = bottom > top ? Double(min(max((visibleTop - top) / (bottom - top), 0), 1)) : 0
        return Double(line) + fraction
    }

    func scrollToSourceLine(_ value: Double) {
        let length = document.textStorage.length
        guard length > 0 else { return }
        let index = lineIndex()
        let line = min(max(Int(value), 0), index.lineCount - 1)
        let fraction = CGFloat(value - Double(line))
        let start = index.start(ofLine: line)
        guard start < length else { return }
        let top = textView.lineTop(forCharacterAt: start)
        let nextStart = index.start(ofLine: line + 1)
        let bottom = nextStart < length ? textView.lineTop(forCharacterAt: nextStart) : top
        scrollView.scrollDocument(toTop: value <= 0 ? 0 : top + fraction * (bottom - top))
    }

    /// Moves the insertion point to the start of a source line and scrolls there.
    func reveal(line: Int) {
        let index = lineIndex()
        let start = min(index.start(ofLine: line), document.textStorage.length)
        textView.setSelectedRange(NSRange(location: start, length: 0))
        scrollToSourceLine(Double(line))
    }

    /// 1-based line and column of the insertion point.
    func cursorPosition() -> (line: Int, column: Int) {
        let location = textView.selectedRange().location
        let index = lineIndex()
        let line = index.line(containing: location)
        return (line + 1, location - index.start(ofLine: line) + 1)
    }

    // MARK: - NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
    }
}
