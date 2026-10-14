import AppKit

/// CSS color values: the named colors of CSS Color Level 4, `#rgb`,
/// `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()` and `hsl()/hsla()`.
enum CSSColor {
    static func parse(_ raw: String) -> NSColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { return hex(String(s.dropFirst())) }
        if s.hasPrefix("rgb") || s.hasPrefix("hsl"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") {
            let parts = s[s.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func component(_ p: String, scale: Double) -> Double {
                p.hasSuffix("%") ? (Double(p.dropLast()) ?? 0) / 100 : (Double(p) ?? 0) / scale
            }
            let alpha = parts.count >= 4 ? component(parts[3], scale: 1) : 1
            if s.hasPrefix("rgb") {
                return NSColor(srgbRed: component(parts[0], scale: 255), green: component(parts[1], scale: 255),
                               blue: component(parts[2], scale: 255), alpha: alpha)
            }
            let hue = (Double(parts[0].replacingOccurrences(of: "deg", with: "")) ?? 0) / 360
            return hsl(hue, component(parts[1], scale: 100), component(parts[2], scale: 100), alpha)
        }
        if s == "transparent" { return .clear }
        if s == "currentcolor" { return nil }
        return named[s].flatMap { hex($0) }
    }

    private static func hex(_ h: String) -> NSColor? {
        var digits = h
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double) -> NSColor {
        func f(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            let amount = s * min(l, 1 - l)
            return l - amount * max(-1, min(k - 3, 9 - k, 1))
        }
        return NSColor(srgbRed: f(0), green: f(8), blue: f(4), alpha: a)
    }

    private static let named: [String: String] = {
        var result: [String: String] = [:]
        let table = """
        aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 \
        black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 \
        cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc \
        crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 \
        darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f \
        darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f \
        darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 \
        deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 \
        floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 \
        goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4 \
        indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 \
        lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff \
        lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 \
        lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 \
        lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff \
        maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db \
        mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc \
        mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 \
        navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 \
        orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee \
        palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd \
        powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 \
        saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d \
        silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa \
        springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 \
        turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 \
        yellowgreen 9acd32
        """
        let words = table.split(separator: " ")
        var k = 0
        while k + 1 < words.count {
            result[String(words[k])] = String(words[k + 1])
            k += 2
        }
        return result
    }()
}

/// The subset of inline CSS (`style="…"`) that maps onto text attributes.
struct CSSStyle: Equatable {
    var color: NSColor?
    var background: NSColor?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var mono: Bool?
    var alignment: NSTextAlignment?
    /// Multiplier for the font size.
    var fontScale: CGFloat?
    var hidden = false
    var verticalShift: Int?
    var smallCaps = false
    var uppercase: Bool?

    var isEmpty: Bool { self == CSSStyle() }

    static func parse(_ style: String) -> CSSStyle {
        var result = CSSStyle()
        for declaration in style.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            value = value.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            let lower = value.lowercased()
            switch property {
            case "color":
                result.color = CSSColor.parse(value)
            case "background-color", "background":
                result.background = CSSColor.parse(value.split(separator: " ").first.map(String.init) ?? value)
            case "font-weight":
                if let n = Int(lower) { result.bold = n >= 600 } else { result.bold = lower == "bold" || lower == "bolder" }
            case "font-style":
                result.italic = lower == "italic" || lower == "oblique"
            case "text-decoration", "text-decoration-line":
                result.underline = lower.contains("underline")
                result.strike = lower.contains("line-through")
            case "text-align":
                switch lower {
                case "center": result.alignment = .center
                case "right", "end": result.alignment = .right
                case "left", "start": result.alignment = .left
                case "justify": result.alignment = .justified
                default: break
                }
            case "font-family":
                if lower.contains("mono") || lower.contains("courier") || lower.contains("menlo") || lower.contains("consolas") {
                    result.mono = true
                }
            case "font-size":
                result.fontScale = fontScale(lower)
            case "display", "visibility":
                if lower == "none" || lower == "hidden" { result.hidden = true }
            case "vertical-align":
                if lower == "super" { result.verticalShift = 1 } else if lower == "sub" { result.verticalShift = -1 }
            case "font-variant":
                result.smallCaps = lower.contains("small-caps")
            case "text-transform":
                if lower == "uppercase" { result.uppercase = true }
            case "font":
                if lower.contains("bold") { result.bold = true }
                if lower.contains("italic") { result.italic = true }
            default:
                break
            }
        }
        return result
    }

    private static func fontScale(_ value: String) -> CGFloat? {
        let keywords: [String: CGFloat] = [
            "xx-small": 0.6, "x-small": 0.75, "small": 0.89, "medium": 1, "large": 1.2, "x-large": 1.5,
            "xx-large": 2, "xxx-large": 3, "smaller": 0.83, "larger": 1.2,
        ]
        if let k = keywords[value] { return k }
        let number = CGFloat(Double(value.prefix(while: { $0.isNumber || $0 == "." })) ?? 0)
        guard number > 0 else { return nil }
        if value.hasSuffix("%") { return number / 100 }
        if value.hasSuffix("em") || value.hasSuffix("rem") { return number }
        if value.hasSuffix("px") { return number / 16 }
        if value.hasSuffix("pt") { return number / 12 }
        return nil
    }

    /// Legacy `<font color size face>` attributes.
    static func fontTag(_ tag: String) -> CSSStyle {
        var result = CSSStyle()
        if let color = HTMLScanner.attribute("color", in: tag) { result.color = CSSColor.parse(color) }
        if let size = HTMLScanner.attribute("size", in: tag) {
            let scales: [CGFloat] = [0.63, 0.82, 1, 1.13, 1.5, 2, 3]
            var n = Int(size.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) ?? 3
            if size.hasPrefix("+") { n += 3 } else if size.hasPrefix("-") { n = 3 - n }
            result.fontScale = scales[max(1, min(7, n)) - 1]
        }
        if let face = HTMLScanner.attribute("face", in: tag)?.lowercased(),
           face.contains("mono") || face.contains("courier") {
            result.mono = true
        }
        return result
    }
}
