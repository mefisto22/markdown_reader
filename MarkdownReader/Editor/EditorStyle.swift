import AppKit

/// Fonts and base attributes for the Markdown source editor.
enum EditorStyle {
    static func font(size: CGFloat = Preferences.shared.editorFontSize,
                     monospaced: Bool = Preferences.shared.editorMonospaced) -> NSFont {
        monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
    }

    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        p.defaultTabInterval = max(spaceWidth * 4, 8)
        p.tabStops = []
        return p
    }

    static func baseAttributes(font: NSFont = font()) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle(for: font),
        ]
    }
}
