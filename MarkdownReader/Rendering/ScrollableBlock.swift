import AppKit

/// A code block or table that is wider than the reading column. Instead of
/// wrapping, its content is shown in a horizontally scrollable view that
/// `PreviewTextView` places over this attachment (TextKit cannot lay out a
/// single block wider than its text container).
final class ScrollableBlockCell: NSTextAttachmentCell {
    let content: NSAttributedString
    /// Natural size of the laid-out content.
    let contentSize: NSSize
    let padding: NSEdgeInsets
    let fillColor: NSColor?
    let cornerRadius: CGFloat
    /// Room for the horizontal scroller: overlay scrollers draw over the
    /// content, legacy (always visible) scrollers need their own space.
    static var scrollerAllowance: CGFloat { NSScroller.preferredScrollerStyle == .legacy ? 15 : 4 }

    init(content: NSAttributedString, contentSize: NSSize, padding: NSEdgeInsets, fillColor: NSColor?, cornerRadius: CGFloat) {
        self.content = content
        self.contentSize = contentSize
        self.padding = padding
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var height: CGFloat {
        ceil(contentSize.height + padding.top + padding.bottom + Self.scrollerAllowance)
    }

    override func cellSize() -> NSSize { NSSize(width: 40, height: height) }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        // Same right edge as ordinary text blocks (inside the line fragment padding).
        NSRect(x: 0, y: 0, width: max(lineFrag.width - position.x - textContainer.lineFragmentPadding, 40), height: height)
    }

    /// Frame of the scrollable content area within the cell frame.
    func contentFrame(in cellFrame: NSRect) -> NSRect {
        NSRect(x: cellFrame.minX + padding.left, y: cellFrame.minY + padding.top,
               width: max(cellFrame.width - padding.left - padding.right, 10),
               height: cellFrame.height - padding.top - padding.bottom)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let fillColor {
            fillColor.setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        if let host = controlView as? PreviewTextView {
            host.placeOverlay(for: self, frame: contentFrame(in: cellFrame))
        } else {
            // No overlay host (e.g. an offscreen view): draw the visible part.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: contentFrame(in: cellFrame)).addClip()
            content.draw(in: NSRect(origin: contentFrame(in: cellFrame).origin, size: contentSize))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }

    /// Lays out `content` without wrapping and returns its size.
    static func measure(_ content: NSAttributedString, width: CGFloat) -> NSSize {
        let storage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(max(used.width, width)), height: ceil(used.height))
    }
}

/// Horizontal-only scroll view used for overlays. Vertical scrolling is
/// passed on to the reader so the page keeps scrolling over wide blocks.
final class HorizontalOverlayScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            superview?.enclosingScrollView?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    static func make(for cell: ScrollableBlockCell, linkDelegate: NSTextViewDelegate?) -> HorizontalOverlayScrollView {
        let width = cell.contentSize.width + 2
        let textView = TextKit1.makeTextView(OverlayTextView.self, width: width,
                                             storage: NSTextStorage(attributedString: cell.content))
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.delegate = linkDelegate
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.layoutManager?.allowsNonContiguousLayout = false
        textView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: cell.contentSize.height))

        let scrollView = HorizontalOverlayScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.setAccessibilityLabel("Wide content, scrolls horizontally")
        return scrollView
    }
}

/// Text view inside an overlay. Find commands go on to the reader, whose
/// finder searches the whole document including this block.
final class OverlayTextView: NSTextView {
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(performTextFinderAction(_:)) || selector == #selector(performFindPanelAction(_:)) {
            return false
        }
        return super.responds(to: selector)
    }
}
