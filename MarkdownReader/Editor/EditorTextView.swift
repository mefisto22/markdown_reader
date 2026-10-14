import AppKit

/// Markdown source editor: list/quote continuation on Return, list
/// indentation with Tab / Shift-Tab, and simple formatting commands.
final class EditorTextView: NSTextView {
    weak var highlighter: SyntaxHighlighter?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private var text: NSString { textStorage?.mutableString ?? "" }

    private func currentLine() -> (range: NSRange, beforeCursor: String)? {
        guard selectedRanges.count == 1 else { return nil }
        let sel = selectedRange()
        let ns = text
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        return (lineRange, before)
    }

    // MARK: Return

    override func insertNewline(_ sender: Any?) {
        guard isEditable, let (lineRange, before) = currentLine() else {
            super.insertNewline(sender)
            return
        }
        let sel = selectedRange()
        if highlighter?.isInsideFence(at: sel.location) == true {
            let indent = String(before.prefix(while: { $0 == " " || $0 == "\t" }))
            if indent.isEmpty { super.insertNewline(sender) } else { insertText("\n" + indent, replacementRange: sel) }
            return
        }
        switch ListContinuation.action(forLineBeforeCursor: before) {
        case .insert(let s)?:
            insertText(s, replacementRange: sel)
        case .replaceLine(let s)? where sel.length == 0:
            insertText(s, replacementRange: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        default:
            super.insertNewline(sender)
        }
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Tab / Shift-Tab on list items

    private func currentListItem() -> (lineStart: Int, marker: ListContinuation.Marker)? {
        guard selectedRanges.count == 1 else { return nil }
        let sel = selectedRange()
        let ns = text
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        guard NSMaxRange(sel) <= NSMaxRange(lineRange) else { return nil }
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let marker = ListContinuation.parse(line) else { return nil }
        if highlighter?.isInsideFence(at: sel.location) == true { return nil }
        return (lineRange.location, marker)
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable, let (lineStart, marker) = currentListItem() else {
            super.insertTab(sender)
            return
        }
        let sel = selectedRange()
        let width = ListContinuation.indentWidth(for: marker)
        let insertAt = lineStart + (marker.quotePrefix as NSString).length
        insertText(String(repeating: " ", count: width), replacementRange: NSRange(location: insertAt, length: 0))
        setSelectedRange(NSRange(location: sel.location + width, length: sel.length))
    }

    override func insertBacktab(_ sender: Any?) {
        guard isEditable, let (lineStart, marker) = currentListItem() else {
            super.insertBacktab(sender)
            return
        }
        let indentLength = (marker.indent as NSString).length
        guard indentLength > 0 else { return }
        let sel = selectedRange()
        let remove = min(indentLength, ListContinuation.indentWidth(for: marker))
        let removeAt = lineStart + (marker.quotePrefix as NSString).length
        insertText("", replacementRange: NSRange(location: removeAt, length: remove))
        setSelectedRange(NSRange(location: max(sel.location - remove, removeAt), length: sel.length))
    }

    // MARK: Formatting commands

    private func toggleWrap(_ prefix: String, _ suffix: String) {
        guard isEditable, selectedRanges.count == 1 else { NSSound.beep(); return }
        let sel = selectedRange()
        let ns = text
        let p = (prefix as NSString).length
        let s = (suffix as NSString).length
        if sel.location >= p, NSMaxRange(sel) + s <= ns.length,
           ns.substring(with: NSRange(location: sel.location - p, length: p)) == prefix,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: s)) == suffix {
            let outer = NSRange(location: sel.location - p, length: sel.length + p + s)
            insertText(ns.substring(with: sel), replacementRange: outer)
            setSelectedRange(NSRange(location: outer.location, length: sel.length))
        } else {
            let inner = ns.substring(with: sel)
            insertText(prefix + inner + suffix, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + p, length: sel.length))
        }
    }

    @IBAction func toggleBold(_ sender: Any?) { toggleWrap("**", "**") }
    @IBAction func toggleItalic(_ sender: Any?) { toggleWrap("*", "*") }
    @IBAction func toggleInlineCode(_ sender: Any?) { toggleWrap("`", "`") }
    @IBAction func toggleStrikethrough(_ sender: Any?) { toggleWrap("~~", "~~") }

    @IBAction func insertMarkdownLink(_ sender: Any?) {
        guard isEditable, selectedRanges.count == 1 else { NSSound.beep(); return }
        let sel = selectedRange()
        let label = text.substring(with: sel)
        let placeholder = "url"
        insertText("[\(label)](\(placeholder))", replacementRange: sel)
        let urlStart = sel.location + (label as NSString).length + 3
        setSelectedRange(NSRange(location: urlStart, length: (placeholder as NSString).length))
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleInlineCode(_:)),
             #selector(toggleStrikethrough(_:)), #selector(insertMarkdownLink(_:)):
            return isEditable
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    // MARK: Dropping Markdown files opens them

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
