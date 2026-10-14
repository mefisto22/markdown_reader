import AppKit

/// Semantic colors for rendered Markdown. All colors are dynamic and resolve
/// at draw time, so Light/Dark Mode switches need no re-rendering.
enum RenderColors {
    static let text = NSColor.textColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let link = NSColor.linkColor
    static let rule = NSColor.separatorColor

    static let codeBackground = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let inlineCodeBackground = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.11))
    static let tableHeaderBackground = dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.06))
    static let tableStripeBackground = dynamic(light: NSColor(white: 0, alpha: 0.018), dark: NSColor(white: 1, alpha: 0.025))
    static let tableBorder = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.16))
    static let quoteBorder = dynamic(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.22))
    static let headingRule = dynamic(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.12))
    static let mark = dynamic(light: NSColor.systemYellow.withAlphaComponent(0.35),
                              dark: NSColor.systemYellow.withAlphaComponent(0.3))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Typography and spacing for the reader. Everything scales with `fontSize`.
struct RenderStyle: Equatable {
    var fontSize: CGFloat

    static let headingScales: [CGFloat] = [1.85, 1.45, 1.22, 1.06, 1.0, 0.92]

    var lineHeightMultiple: CGFloat { 1.22 }
    var paragraphSpacing: CGFloat { (fontSize * 0.8).rounded() }
    var tightSpacing: CGFloat { (fontSize * 0.25).rounded() }
    var listMarkerWidth: CGFloat { (fontSize * 1.7).rounded() }
    var codeFontSize: CGFloat { (fontSize * 0.86).rounded() }
    var codePadding: CGFloat { (fontSize * 0.75).rounded() }

    func headingSize(_ level: Int) -> CGFloat {
        (fontSize * Self.headingScales[max(0, min(5, level - 1))]).rounded()
    }

    func headingSpacingBefore(_ level: Int) -> CGFloat {
        (fontSize * (level <= 2 ? 1.25 : 1.0)).rounded()
    }

    func headingSpacingAfter(_ level: Int) -> CGFloat {
        (fontSize * 0.5).rounded()
    }
}

/// Caches fonts by trait combination; font lookup is surprisingly costly when
/// done per text run.
final class FontCache {
    struct Key: Hashable {
        var size: CGFloat
        var bold: Bool
        var italic: Bool
        var mono: Bool
        var weight: CGFloat
    }

    private var fonts: [Key: NSFont] = [:]

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false,
              weight: NSFont.Weight = .regular) -> NSFont {
        let key = Key(size: size, bold: bold, italic: italic, mono: mono, weight: weight.rawValue)
        if let font = fonts[key] { return font }
        let resolvedWeight: NSFont.Weight = bold ? (weight.rawValue > NSFont.Weight.bold.rawValue ? weight : .bold) : weight
        var font: NSFont = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : resolvedWeight)
            : NSFont.systemFont(ofSize: size, weight: resolvedWeight)
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: descriptor, size: size) ?? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        fonts[key] = font
        return font
    }
}
