import AppKit

/// Find bar support for the reader, including the text of wide code blocks
/// and tables. Those are shown in horizontally scrolling overlays
/// (`ScrollableBlockCell`) and are a single attachment character in the
/// reader's own text, so the standard text view finder cannot see them.
///
/// The client presents the text finder with a virtual string in which each
/// such attachment is replaced by the text of its block (as a separate
/// segment, so matches never span a block boundary), and maps ranges back
/// to the reader's text view or to the overlay's text view.
final class PreviewFindClient: NSObject, NSTextFinderClient {
    private struct Segment {
        /// Range in the virtual string.
        var range: NSRange
        /// Range in the reader's text storage; for a wide block, its attachment character.
        var source: NSRange
        var isOverlay: Bool
    }

    private unowned let textView: PreviewTextView
    private var cachedSegments: [Segment]?
    /// Attachment index of the wide block holding the finder's selection.
    private var selectedOverlay: Int?

    init(textView: PreviewTextView) {
        self.textView = textView
        super.init()
    }

    /// Call when the reader's text changes.
    func invalidate() {
        cachedSegments = nil
        selectedOverlay = nil
    }

    // MARK: Segments

    private var segments: [Segment] {
        if let cachedSegments { return cachedSegments }
        var result: [Segment] = []
        guard let storage = textView.textStorage else { return [] }
        var virtual = 0
        var mainStart = 0
        func addMain(upTo end: Int) {
            guard end > mainStart else { return }
            result.append(Segment(range: NSRange(location: virtual, length: end - mainStart),
                                  source: NSRange(location: mainStart, length: end - mainStart), isOverlay: false))
            virtual += end - mainStart
        }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? ScrollableBlockCell else { return }
            let length = cell.content.length
            for index in range.location..<NSMaxRange(range) {
                addMain(upTo: index)
                if length > 0 {
                    result.append(Segment(range: NSRange(location: virtual, length: length),
                                          source: NSRange(location: index, length: 1), isOverlay: true))
                    virtual += length
                }
                mainStart = index + 1
            }
        }
        addMain(upTo: storage.length)
        cachedSegments = result
        return result
    }

    private var virtualLength: Int { segments.last.map { NSMaxRange($0.range) } ?? 0 }

    /// The segment containing virtual index `index` (the last one at the end).
    private func segment(atVirtual index: Int) -> Segment? {
        let all = segments
        var low = 0, high = all.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if all[mid].range.location <= index { low = mid } else { high = mid - 1 }
        }
        return all.isEmpty ? nil : all[low]
    }

    /// The last segment starting at or before source index `index`.
    private func segment(atSource index: Int) -> Segment? {
        let all = segments
        var low = 0, high = all.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if all[mid].source.location <= index { low = mid } else { high = mid - 1 }
        }
        return all.isEmpty ? nil : all[low]
    }

    /// Virtual position of source index `index`. A wide block's attachment
    /// character maps to the start of its text, or with `end` to its end.
    private func virtualIndex(forSource index: Int, end: Bool = false) -> Int {
        guard let s = segment(atSource: index), index >= s.source.location else { return 0 }
        if s.isOverlay { return end && index == s.source.location ? NSMaxRange(s.range) : s.range.location }
        return s.range.location + min(index - s.source.location, s.range.length)
    }

    private func virtualRange(forSource range: NSRange) -> NSRange {
        let start = virtualIndex(forSource: range.location)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = virtualIndex(forSource: NSMaxRange(range) - 1, end: true)
        let last = segment(atSource: NSMaxRange(range) - 1)
        return NSRange(location: start, length: max((last?.isOverlay == true ? end : end + 1) - start, 0))
    }

    /// The text view showing virtual `range` and the range within it. Ranges
    /// are clipped to the segment containing their start.
    private func locate(_ range: NSRange) -> (NSTextView, NSRange)? {
        guard let s = segment(atVirtual: range.location) else { return nil }
        let offset = min(max(range.location - s.range.location, 0), s.range.length)
        let length = min(range.length, s.range.length - offset)
        if s.isOverlay {
            guard let overlay = textView.overlayTextView(forAttachmentAt: s.source.location) else {
                return (textView, s.source)
            }
            return (overlay, NSRange(location: offset, length: length))
        }
        return (textView, NSRange(location: s.source.location + offset, length: length))
    }

    private static func boundingRect(of range: NSRange, in view: NSTextView) -> NSRect? {
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    // MARK: NSTextFinderClient

    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { false }

    func stringLength() -> Int { virtualLength }

    func string(at characterIndex: Int, effectiveRange outRange: NSRangePointer,
                endsWithSearchBoundary outFlag: UnsafeMutablePointer<ObjCBool>) -> String {
        outFlag.pointee = true
        guard let s = segment(atVirtual: characterIndex), let storage = textView.textStorage else {
            outRange.pointee = NSRange(location: virtualLength, length: 0)
            return ""
        }
        outRange.pointee = s.range
        if s.isOverlay,
           let cell = (storage.attribute(.attachment, at: s.source.location, effectiveRange: nil) as? NSTextAttachment)?
               .attachmentCell as? ScrollableBlockCell {
            return cell.content.string
        }
        return (storage.string as NSString).substring(with: s.source)
    }

    var firstSelectedRange: NSRange {
        // A wide block the user selected text in, or that holds the last match.
        if let responder = textView.window?.firstResponder as? NSTextView, responder !== textView,
           let index = textView.attachmentIndex(ofOverlayTextView: responder),
           let s = segment(atSource: index), s.isOverlay, s.source.location == index {
            let selection = responder.selectedRange()
            return NSRange(location: s.range.location + min(selection.location, s.range.length), length: selection.length)
        }
        if let index = selectedOverlay, textView.selectedRange() == NSRange(location: index, length: 0),
           let overlay = textView.overlayTextView(forAttachmentAt: index, create: false),
           let s = segment(atSource: index), s.isOverlay, s.source.location == index {
            let selection = overlay.selectedRange()
            return NSRange(location: s.range.location + min(selection.location, s.range.length), length: selection.length)
        }
        return virtualRange(forSource: textView.selectedRange())
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let range = newValue.first?.rangeValue, let (view, local) = locate(range) else { return }
            if let index = selectedOverlay, let old = textView.overlayTextView(forAttachmentAt: index, create: false),
               old !== view {
                old.setSelectedRange(NSRange(location: 0, length: 0))
            }
            if view === textView {
                selectedOverlay = nil
                textView.setSelectedRange(local)
            } else if let s = segment(atVirtual: range.location) {
                selectedOverlay = s.source.location
                textView.setSelectedRange(NSRange(location: s.source.location, length: 0))
                view.setSelectedRange(local)
            }
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let (view, local) = locate(range) else { return }
        if view === textView {
            textView.scrollRangeToVisible(local)
        } else if let rect = Self.boundingRect(of: local, in: view) {
            // Horizontally inside the block, then vertically in the reader.
            view.scrollToVisible(rect.insetBy(dx: -20, dy: 0))
            textView.scrollToVisible(textView.convert(rect, from: view).insetBy(dx: 0, dy: -20))
        }
    }

    var visibleCharacterRanges: [NSValue] {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let origin = textView.textContainerOrigin
        let rect = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return [NSValue(range: virtualRange(forSource: characters))]
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let s = segment(atVirtual: index) else {
            outRange.pointee = NSRange(location: 0, length: virtualLength)
            return textView
        }
        outRange.pointee = s.range
        if s.isOverlay, let overlay = textView.overlayTextView(forAttachmentAt: s.source.location) { return overlay }
        return textView
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let (view, local) = locate(range), let layoutManager = view.layoutManager,
              let container = view.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: local, actualCharacterRange: nil)
        let origin = view.textContainerOrigin
        var rects: [NSValue] = []
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                              withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: container) { rect, _ in
            rects.append(NSValue(rect: rect.offsetBy(dx: origin.x, dy: origin.y)))
        }
        return rects
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let (target, local) = locate(range), target === view, let layoutManager = target.layoutManager else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: local, actualCharacterRange: nil)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: target.textContainerOrigin)
    }
}
