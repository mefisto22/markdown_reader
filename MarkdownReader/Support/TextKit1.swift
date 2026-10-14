import AppKit

/// Builds explicit TextKit 1 text view stacks. TextKit 1 is used on purpose:
/// it supports `NSTextTable`/`NSTextBlock`, non-contiguous layout for large
/// documents and cheap attribute-based highlighting.
enum TextKit1 {
    static func makeTextView(width: CGFloat = 400, storage: NSTextStorage = NSTextStorage()) -> NSTextView {
        makeTextView(NSTextView.self, width: width, storage: storage)
    }

    static func makeTextView<T: NSTextView>(_ type: T.Type, width: CGFloat = 400,
                                            storage: NSTextStorage = NSTextStorage()) -> T {
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = T(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        return textView
    }

    static func makeScrollView(documentView: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = documentView
        return scrollView
    }
}

extension NSScrollView {
    /// Y coordinate (in document view coordinates) of the first visible line,
    /// accounting for content insets under a transparent titlebar.
    var visibleDocumentTop: CGFloat {
        contentView.bounds.minY + contentInsets.top
    }

    /// Scrolls so that document coordinate `y` is at the top of the visible area.
    func scrollDocument(toTop y: CGFloat) {
        guard let documentView else { return }
        let maxY = max(documentView.frame.height - contentView.bounds.height + contentInsets.bottom, -contentInsets.top)
        let target = min(max(y - contentInsets.top, -contentInsets.top), maxY)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: target))
        reflectScrolledClipView(contentView)
    }
}

extension NSTextView {
    /// Character index of the first character visible at the top of the view.
    func topVisibleCharacterIndex(in scrollView: NSScrollView) -> Int {
        guard let layoutManager, let textContainer else { return 0 }
        let y = scrollView.visibleDocumentTop - textContainerOrigin.y + 1
        let point = NSPoint(x: textContainer.lineFragmentPadding + 1, y: max(y, 0))
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// Top Y (document coordinates) of the line containing character `index`.
    /// With `precise`, everything before the character is laid out first:
    /// non-contiguous layout otherwise only estimates the height of unlaid
    /// text above, which matters for rendered Markdown (tables, images).
    func lineTop(forCharacterAt index: Int, precise: Bool = false) -> CGFloat {
        guard let layoutManager, let textStorage else { return 0 }
        let length = textStorage.length
        guard length > 0 else { return 0 }
        let charIndex = min(max(index, 0), length - 1)
        if precise {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: charIndex + 1))
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1),
                                                  actualCharacterRange: nil)
        let glyph = min(glyphRange.location, max(layoutManager.numberOfGlyphs - 1, 0))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.minY + textContainerOrigin.y
    }
}
