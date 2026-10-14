import AppKit

/// Draws an image scaled down to fit the available line width, so images
/// adapt when the window is resized instead of overflowing the text view.
final class ImageAttachmentCell: NSTextAttachmentCell {
    private let picture: NSImage
    private let preferredWidth: CGFloat?

    init(image: NSImage, preferredWidth: CGFloat? = nil) {
        self.picture = image
        self.preferredWidth = preferredWidth
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var naturalSize: NSSize {
        var size = picture.size
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 16, height: 16) }
        if let preferredWidth, preferredWidth > 0, preferredWidth < size.width {
            size = NSSize(width: preferredWidth, height: size.height * preferredWidth / size.width)
        }
        return size
    }

    override func cellSize() -> NSSize { naturalSize }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var size = naturalSize
        let available = max(lineFrag.width - 4, 16)
        if size.width > available {
            size = NSSize(width: available, height: size.height * available / size.width)
        }
        return NSRect(origin: .zero, size: size)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// A full-width horizontal rule drawn with the current separator color.
final class HorizontalRuleCell: NSTextAttachmentCell {
    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func cellSize() -> NSSize { NSSize(width: 1, height: height) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(lineFrag.width - position.x - 2, 1), height: height)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let lineRect = NSRect(x: cellFrame.minX, y: cellFrame.midY.rounded(.down), width: cellFrame.width, height: 1)
        RenderColors.rule.setFill()
        lineRect.fill()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// Small cache for decoded local images, keyed by path and modification date,
/// so live preview updates do not re-read image files on every keystroke.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 64
    }

    func image(at url: URL) -> NSImage? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Text block whose background is drawn inside its margins (TextKit fills the
/// whole block rect including margins, which merges adjacent blocks), with
/// optional rounded corners. Borders are still drawn by `NSTextBlock`.
final class MarkdownTextBlock: NSTextBlock {
    var fillColor: NSColor?
    var cornerRadius: CGFloat = 0

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        if let fillColor {
            let minX = width(for: .margin, edge: .minX)
            let maxX = width(for: .margin, edge: .maxX)
            let minY = width(for: .margin, edge: .minY)
            let maxY = width(for: .margin, edge: .maxY)
            let rect = NSRect(x: frameRect.minX + minX, y: frameRect.minY + minY,
                              width: frameRect.width - minX - maxX, height: frameRect.height - minY - maxY)
            if rect.width > 0, rect.height > 0 {
                fillColor.setFill()
                if cornerRadius > 0 {
                    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
                } else {
                    rect.fill()
                }
            }
        }
        super.drawBackground(withFrame: frameRect, in: controlView, characterRange: charRange, layoutManager: layoutManager)
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let block = copy as? MarkdownTextBlock {
            block.fillColor = fillColor
            block.cornerRadius = cornerRadius
        }
        return copy
    }
}
