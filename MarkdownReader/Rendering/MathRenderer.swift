import AppKit
import CoreText

/// Native renderer for the TeX math subset used in Markdown documents
/// (`$…$`, `$$…$$`, ```` ```math ````): no WebKit, no JavaScript.
///
/// TeX source is parsed into `MathNode`s, laid out into boxes with TeX-like
/// metrics (styles, scripts, fractions, radicals, stretchy delimiters,
/// matrices and aligned environments) and drawn as vectors with STIX Two
/// Math, so formulas stay sharp at every size, in PDF export and in print.
/// Unknown commands are shown in red instead of failing the whole formula.
enum MathRenderer {
    /// Lays out `tex`. `fontSize` is the size of the surrounding text.
    static func layout(_ tex: String, display: Bool, fontSize: CGFloat) -> MathBox {
        var parser = MathParser(tex)
        let nodes = parser.parseAll()
        let style: MathStyle = display ? .display : .text
        var box = MathLayout(fontSize: fontSize).layoutList(nodes, style: style, color: nil)
        if let tag = parser.tag, display {
            let tagBox = MathLayout(fontSize: fontSize).layoutList([.text("(\(tag))", .roman)], style: .text, color: nil)
            box = HBox([box, SpaceBox(width: fontSize * 1.5), tagBox])
        }
        return box
    }
}

// MARK: - Syntax tree

enum MathFont: Equatable {
    case italic, roman, bold, boldItalic, blackboard, calligraphic, fraktur, sansSerif, monospace
}

enum MathStyle: Int {
    case display, text, script, scriptScript

    var smaller: MathStyle {
        switch self {
        case .display, .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }

    var fraction: MathStyle {
        switch self {
        case .display: return .text
        case .text: return .script
        default: return .scriptScript
        }
    }

    var scale: CGFloat {
        switch self {
        case .display, .text: return 1
        case .script: return 0.72
        case .scriptScript: return 0.55
        }
    }
}

enum AtomClass { case ord, op, bin, rel, open, close, punct, inner }

indirect enum MathNode {
    case atom(String, AtomClass, MathFont)
    case bigOp(String, limits: Bool?, isFunction: Bool)
    case group([MathNode])
    case fraction([MathNode], [MathNode], style: MathStyle?, rule: Bool, left: String?, right: String?)
    case radical([MathNode], index: [MathNode]?)
    case scripts(base: MathNode, sup: [MathNode]?, sub: [MathNode]?)
    case leftRight(String, [MathNode], String)
    case middle(String)
    case sizedDelimiter(String, CGFloat, AtomClass)
    case accent(String, [MathNode], stretch: Bool)
    case overline([MathNode])
    case underline([MathNode])
    case brace([MathNode], label: [MathNode]?, over: Bool)
    case stack(top: [MathNode]?, base: [MathNode], bottom: [MathNode]?)
    case text(String, MathFont)
    case space(CGFloat)
    case colored(NSColor, [MathNode])
    case styled(MathStyle, [MathNode])
    case matrix([[[MathNode]]], alignments: [NSTextAlignment], left: String?, right: String?, spacing: CGFloat)
    case boxed([MathNode])
    case negated(MathNode)
    case phantom([MathNode])
    case error(String)
}

// MARK: - Parser

struct MathParser {
    private let chars: [Character]
    private var i = 0
    private(set) var tag: String?

    init(_ source: String) {
        chars = Array(source)
    }

    mutating func parseAll() -> [MathNode] {
        var nodes = parseList(until: [])
        // Stray closing braces etc.: skip and continue.
        while i < chars.count {
            i += 1
            nodes += parseList(until: [])
        }
        return nodes
    }

    // MARK: Tokens

    private enum Token: Equatable {
        case char(Character)
        case command(String)
        case open, close, sup, sub, ampersand, newline, end
    }

    private mutating func peekToken() -> Token {
        let saved = i
        let token = nextToken()
        i = saved
        return token
    }

    private mutating func skipSpaces() {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    private mutating func nextToken() -> Token {
        skipSpaces()
        guard i < chars.count else { return .end }
        let c = chars[i]
        i += 1
        switch c {
        case "{": return .open
        case "}": return .close
        case "^": return .sup
        case "_": return .sub
        case "&": return .ampersand
        case "\\":
            guard i < chars.count else { return .char("\\") }
            let d = chars[i]
            if d == "\\" { i += 1; return .newline }
            if d.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                if name == "operatorname" || name == "operatornamewithlimits", i < chars.count, chars[i] == "*" {
                    i += 1
                }
                return .command(name)
            }
            i += 1
            return .command(String(d))
        default:
            return .char(c)
        }
    }

    // MARK: Lists

    private enum Stop: Hashable { case close, ampersand, newline, right, end, middle }

    /// Parses atoms until one of `stops` (not consumed) or the end.
    private mutating func parseList(until stops: Set<Stop>) -> [MathNode] {
        var nodes: [MathNode] = []
        while true {
            let token = peekToken()
            switch token {
            case .end: return nodes
            case .close: if stops.contains(.close) || stops.isEmpty { return nodes }
            case .ampersand: if stops.contains(.ampersand) { return nodes }
            case .newline: if stops.contains(.newline) { return nodes }
            case .command("right"): if stops.contains(.right) { return nodes }
            case .command("end"): if stops.contains(.end) { return nodes }
            case .command("middle"): if stops.contains(.middle) { return nodes }
            default: break
            }
            if case .command(let name) = token, let style = Self.styleCommands[name] {
                _ = nextToken()
                let rest = parseList(until: stops)
                nodes.append(.styled(style, rest))
                return nodes
            }
            if case .command(let name) = token, name == "over" || name == "choose" || name == "atop" {
                _ = nextToken()
                let rest = parseList(until: stops)
                let isChoose = name == "choose"
                nodes = [.fraction(nodes, rest, style: nil, rule: name == "over", left: isChoose ? "(" : nil,
                                   right: isChoose ? ")" : nil)]
                return nodes
            }
            guard let atom = parseAtom() else {
                // Unexpected token: consume it so parsing always progresses.
                let t = nextToken()
                if case .ampersand = t { nodes.append(.space(0.5)) }
                if case .newline = t { nodes.append(.space(1)) }
                continue
            }
            nodes.append(parseScripts(atom))
        }
    }

    private mutating func parseScripts(_ base: MathNode) -> MathNode {
        var sup: [MathNode]?
        var sub: [MathNode]?
        var base = base
        while true {
            let token = peekToken()
            if token == .char("'") {
                _ = nextToken()
                var primes = "′"
                while peekToken() == .char("'") { _ = nextToken(); primes.append("′") }
                sup = (sup ?? []) + [.atom(primes, .ord, .roman)]
            } else if token == .sup {
                _ = nextToken()
                sup = (sup ?? []) + parseArgument()
            } else if token == .sub {
                _ = nextToken()
                sub = (sub ?? []) + parseArgument()
            } else if case .command(let c) = token, c == "limits" || c == "nolimits" {
                _ = nextToken()
                if case .bigOp(let s, _, let f) = base { base = .bigOp(s, limits: c == "limits", isFunction: f) }
            } else {
                break
            }
        }
        if sup == nil, sub == nil { return base }
        return .scripts(base: base, sup: sup, sub: sub)
    }

    /// A braced group or a single atom.
    private mutating func parseArgument() -> [MathNode] {
        let token = peekToken()
        if token == .open {
            _ = nextToken()
            let list = parseList(until: [.close])
            if peekToken() == .close { _ = nextToken() }
            return list
        }
        if let atom = parseAtom() { return [atom] }
        return []
    }

    /// Raw text of a braced argument (for \text, \color, \begin, …).
    private mutating func parseRawArgument() -> String {
        skipSpaces()
        guard i < chars.count else { return "" }
        if chars[i] != "{" {
            let c = chars[i]
            i += 1
            return String(c)
        }
        i += 1
        var depth = 1
        var result = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                result.append(c)
                result.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { i += 1; break }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    /// Optional `[…]` argument.
    private mutating func parseOptionalArgument() -> [MathNode]? {
        skipSpaces()
        guard i < chars.count, chars[i] == "[" else { return nil }
        i += 1
        var depth = 0
        var raw = ""
        while i < chars.count {
            let c = chars[i]
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if c == "]", depth == 0 { i += 1; break }
            raw.append(c)
            i += 1
        }
        var sub = MathParser(raw)
        return sub.parseAll()
    }

    private mutating func parseDelimiter() -> String {
        let token = nextToken()
        switch token {
        case .char(let c): return c == "." ? "" : String(c)
        case .command(let name): return Self.delimiterCommands[name] ?? (name == "|" ? "‖" : name)
        default: return ""
        }
    }

    // MARK: Atoms

    private mutating func parseAtom() -> MathNode? {
        let token = peekToken()
        switch token {
        case .open:
            _ = nextToken()
            let list = parseList(until: [.close])
            if peekToken() == .close { _ = nextToken() }
            return .group(list)
        case .char(let c):
            _ = nextToken()
            return charAtom(c)
        case .command(let name):
            _ = nextToken()
            return command(name)
        case .sup, .sub:
            // A script without a base attaches to an empty atom.
            return .group([])
        default:
            return nil
        }
    }

    private mutating func charAtom(_ c: Character) -> MathNode {
        if c.isNumber || c == "." {
            // Group digits so that "3.14" is one atom.
            var number = String(c)
            while i < chars.count, chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                number.append(chars[i])
                i += 1
            }
            return .atom(number, .ord, .roman)
        }
        if c.isLetter { return .atom(String(c), .ord, .italic) }
        switch c {
        case "+": return .atom("+", .bin, .roman)
        case "-": return .atom("−", .bin, .roman)
        case "*": return .atom("∗", .bin, .roman)
        case "=", "<", ">": return .atom(String(c), .rel, .roman)
        case ":": return .atom(":", .rel, .roman)
        case ",", ";": return .atom(String(c), .punct, .roman)
        case "(", "[": return .atom(String(c), .open, .roman)
        case ")", "]": return .atom(String(c), .close, .roman)
        case "!", "?": return .atom(String(c), .close, .roman)
        case "~": return .space(0.28)
        case "|": return .atom("|", .ord, .roman)
        default: return .atom(String(c), .ord, .roman)
        }
    }

    private mutating func command(_ name: String) -> MathNode {
        if let symbol = Self.greek[name] {
            let upright = name.first!.isUppercase
            return .atom(symbol, .ord, upright ? .roman : .italic)
        }
        if let (symbol, cls) = Self.symbols[name] { return .atom(symbol, cls, .roman) }
        if let (symbol, limits) = Self.bigOperators[name] { return .bigOp(symbol, limits: limits ? nil : false, isFunction: false) }
        if Self.functions.contains(name) {
            return .bigOp(name, limits: Self.limitFunctions.contains(name) ? nil : false, isFunction: true)
        }
        if let em = Self.spaces[name] { return .space(em) }
        if let font = Self.fontCommands[name] {
            let arg = parseArgument()
            return .group(arg.map { Self.applyFont(font, $0) })
        }
        if let accent = Self.accents[name] {
            return .accent(accent.0, parseArgument(), stretch: accent.1)
        }
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let num = parseArgument()
            let den = parseArgument()
            let style: MathStyle? = name == "dfrac" || name == "cfrac" ? .display : name == "tfrac" ? .text : nil
            return .fraction(num, den, style: style, rule: true, left: nil, right: nil)
        case "binom", "dbinom", "tbinom":
            let top = parseArgument()
            let bottom = parseArgument()
            let style: MathStyle? = name == "dbinom" ? .display : name == "tbinom" ? .text : nil
            return .fraction(top, bottom, style: style, rule: false, left: "(", right: ")")
        case "genfrac":
            let left = parseRawArgument()
            let right = parseRawArgument()
            _ = parseRawArgument()
            _ = parseRawArgument()
            let num = parseArgument()
            let den = parseArgument()
            return .fraction(num, den, style: nil, rule: true, left: left, right: right)
        case "sqrt":
            let index = parseOptionalArgument()
            return .radical(parseArgument(), index: index)
        case "left":
            let left = parseDelimiter()
            var body = parseList(until: [.right, .middle])
            while peekToken() == .command("middle") {
                _ = nextToken()
                body.append(.middle(parseDelimiter()))
                body += parseList(until: [.right, .middle])
            }
            var right = ""
            if peekToken() == .command("right") {
                _ = nextToken()
                right = parseDelimiter()
            }
            return .leftRight(left, body, right)
        case "right", "middle":
            return .atom(parseDelimiter(), .ord, .roman)
        case "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl", "bigr", "Bigr", "biggr", "Biggr",
             "bigm", "Bigm", "biggm", "Biggm":
            let delimiter = parseDelimiter()
            let scale: CGFloat = name.hasPrefix("bigg") ? 2.4 : name.hasPrefix("Bigg") ? 3.0 : name.hasPrefix("Big") ? 1.8 : 1.2
            let cls: AtomClass = name.hasSuffix("l") ? .open : name.hasSuffix("r") ? .close : name.hasSuffix("m") ? .rel : .ord
            return .sizedDelimiter(delimiter, scale, cls)
        case "overline": return .overline(parseArgument())
        case "underline": return .underline(parseArgument())
        case "overbrace", "underbrace":
            let body = parseArgument()
            var label: [MathNode]?
            let next = peekToken()
            if (name == "overbrace" && next == .sup) || (name == "underbrace" && next == .sub) {
                _ = nextToken()
                label = parseArgument()
            }
            return .brace(body, label: label, over: name == "overbrace")
        case "overset", "stackrel":
            let top = parseArgument()
            let base = parseArgument()
            return .stack(top: top, base: [.styled(.text, base)], bottom: nil)
        case "underset":
            let bottom = parseArgument()
            let base = parseArgument()
            return .stack(top: nil, base: base, bottom: bottom)
        case "text", "textrm", "textnormal", "mbox", "hbox", "textup":
            return .text(parseRawArgument(), .roman)
        case "textbf": return .text(parseRawArgument(), .bold)
        case "textit", "emph": return .text(parseRawArgument(), .italic)
        case "texttt": return .text(parseRawArgument(), .monospace)
        case "textsf": return .text(parseRawArgument(), .sansSerif)
        case "operatorname", "operatornamewithlimits":
            let raw = parseRawArgument()
            return .bigOp(raw.replacingOccurrences(of: "\\", with: ""), limits: name.hasSuffix("limits") ? nil : false,
                          isFunction: true)
        case "mathop":
            let arg = parseArgument()
            return .bigOp(Self.plain(arg), limits: nil, isFunction: true)
        case "mathrel", "mathbin", "mathord", "mathpunct", "mathopen", "mathclose":
            let arg = parseArgument()
            let cls: AtomClass = ["mathrel": .rel, "mathbin": .bin, "mathpunct": .punct, "mathopen": .open,
                                  "mathclose": .close][name] ?? .ord
            if arg.count == 1, case .atom(let s, _, let f) = arg[0] { return .atom(s, cls, f) }
            return .group(arg)
        case "color":
            let color = Self.color(parseRawArgument())
            let rest = parseList(until: [.close, .ampersand, .newline, .right, .end])
            return .colored(color, rest)
        case "textcolor":
            let color = Self.color(parseRawArgument())
            return .colored(color, parseArgument())
        case "boxed", "fbox":
            return .boxed(name == "fbox" ? [.text(parseRawArgument(), .roman)] : parseArgument())
        case "not":
            guard let next = parseAtom() else { return .atom("/", .ord, .roman) }
            if case .atom(let s, _, _) = next, let negated = Self.negations[s] { return .atom(negated, .rel, .roman) }
            return .negated(next)
        case "phantom", "hphantom", "vphantom":
            return .phantom(parseArgument())
        case "pmod":
            let arg = parseArgument()
            return .group([.space(0.6), .atom("(", .open, .roman), .bigOp("mod", limits: false, isFunction: true),
                           .space(0.3), .group(arg), .atom(")", .close, .roman)])
        case "bmod", "mod":
            return .group([.space(0.2), .bigOp("mod", limits: false, isFunction: true), .space(0.2)])
        case "hspace", "kern", "mkern", "mspace":
            let raw = parseRawArgument()
            return .space(Self.length(raw))
        case "tag", "tag*":
            tag = parseRawArgument()
            return .group([])
        case "label", "nonumber", "notag", "displaybreak", "allowbreak", "nobreak":
            if name == "label" { _ = parseRawArgument() }
            return .group([])
        case "begin":
            return environment(parseRawArgument())
        case "substack":
            let raw = parseRawArgument()
            var sub = MathParser(raw)
            let rows = sub.parseRows(end: false)
            return .matrix(rows, alignments: [.center], left: nil, right: nil, spacing: 0.1)
        case "unicode":
            let raw = parseRawArgument()
            let value = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            return .atom(value.flatMap(Unicode.Scalar.init).map { String($0) } ?? "?", .ord, .roman)
        default:
            return .error("\\" + name)
        }
    }

    // MARK: Environments

    private mutating func environment(_ rawName: String) -> MathNode {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        var alignments: [NSTextAlignment] = [.center]
        if name == "array" || name == "darray" {
            let spec = parseRawArgument()
            alignments = spec.compactMap { c -> NSTextAlignment? in
                switch c {
                case "l": return .left
                case "r": return .right
                case "c": return .center
                default: return nil
                }
            }
            if alignments.isEmpty { alignments = [.center] }
        }
        let rows = parseRows(end: true)
        switch name {
        case "matrix", "matrix*", "array", "darray": return .matrix(rows, alignments: alignments, left: nil, right: nil, spacing: 1)
        case "pmatrix", "pmatrix*": return .matrix(rows, alignments: alignments, left: "(", right: ")", spacing: 1)
        case "bmatrix", "bmatrix*": return .matrix(rows, alignments: alignments, left: "[", right: "]", spacing: 1)
        case "Bmatrix", "Bmatrix*": return .matrix(rows, alignments: alignments, left: "{", right: "}", spacing: 1)
        case "vmatrix", "vmatrix*": return .matrix(rows, alignments: alignments, left: "|", right: "|", spacing: 1)
        case "Vmatrix", "Vmatrix*": return .matrix(rows, alignments: alignments, left: "‖", right: "‖", spacing: 1)
        case "smallmatrix": return .styled(.script, [.matrix(rows, alignments: alignments, left: nil, right: nil, spacing: 0.5)])
        case "cases", "dcases": return .matrix(rows, alignments: [.left, .left], left: "{", right: nil, spacing: 1)
        case "rcases": return .matrix(rows, alignments: [.left, .left], left: nil, right: "}", spacing: 1)
        case "aligned", "align", "align*", "alignat", "alignat*", "split", "eqnarray", "eqnarray*", "flalign", "flalign*":
            return .matrix(rows, alignments: [.right, .left], left: nil, right: nil, spacing: 0)
        case "gathered", "gather", "gather*", "multline", "multline*", "equation", "equation*", "displaymath":
            return .matrix(rows, alignments: [.center], left: nil, right: nil, spacing: 0)
        default:
            return .matrix(rows, alignments: alignments, left: nil, right: nil, spacing: 1)
        }
    }

    /// Rows separated by `\\`, cells by `&`, until `\end{…}` (consumed).
    mutating func parseRows(end: Bool) -> [[[MathNode]]] {
        var rows: [[[MathNode]]] = []
        var row: [[MathNode]] = []
        while true {
            let cell = parseList(until: [.ampersand, .newline, .end, .close])
            row.append(cell)
            let token = peekToken()
            if token == .ampersand {
                _ = nextToken()
            } else if token == .newline {
                _ = nextToken()
                // Optional spacing argument: \\[2pt]
                skipSpaces()
                if i < chars.count, chars[i] == "[" { _ = parseOptionalArgument() }
                rows.append(row)
                row = []
            } else {
                if token == .command("end") {
                    _ = nextToken()
                    _ = parseRawArgument()
                }
                break
            }
        }
        if !(row.count == 1 && row[0].isEmpty) || rows.isEmpty { rows.append(row) }
        return rows
    }

    // MARK: Helpers

    private static func plain(_ nodes: [MathNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .atom(let s, _, _): return s
            case .text(let s, _): return s
            case .group(let g): return plain(g)
            default: return ""
            }
        }.joined()
    }

    private static func applyFont(_ font: MathFont, _ node: MathNode) -> MathNode {
        switch node {
        case .atom(let s, let cls, let f):
            if font == .roman || font == .bold || f == .italic || font == .boldItalic { return .atom(s, cls, font) }
            if s.first?.isLetter == true || s.first?.isNumber == true { return .atom(s, cls, font) }
            return node
        case .group(let g): return .group(g.map { applyFont(font, $0) })
        case .scripts(let base, let sup, let sub): return .scripts(base: applyFont(font, base), sup: sup, sub: sub)
        default: return node
        }
    }

    static func color(_ raw: String) -> NSColor {
        let name = raw.trimmingCharacters(in: .whitespaces)
        return CSSColor.parse(name) ?? .systemRed
    }

    private static func length(_ raw: String) -> CGFloat {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let number = Double(s.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })) ?? 0
        if s.hasSuffix("mu") { return CGFloat(number / 18) }
        if s.hasSuffix("pt") || s.hasSuffix("px") { return CGFloat(number / 10) }
        if s.hasSuffix("ex") { return CGFloat(number * 0.45) }
        return CGFloat(number)
    }

    static let styleCommands: [String: MathStyle] = [
        "displaystyle": .display, "textstyle": .text, "scriptstyle": .script, "scriptscriptstyle": .scriptScript,
    ]

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "varkappa": "ϰ", "lambda": "λ",
        "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "digamma": "ϝ",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "varGamma": "𝛤", "varDelta": "𝛥", "varTheta": "𝛩", "varLambda": "𝛬", "varXi": "𝛯", "varPi": "𝛱",
        "varSigma": "𝛴", "varUpsilon": "𝛶", "varPhi": "𝛷", "varPsi": "𝛹", "varOmega": "𝛺",
    ]

    static let symbols: [String: (String, AtomClass)] = [
        // Binary operators
        "pm": ("±", .bin), "mp": ("∓", .bin), "times": ("×", .bin), "div": ("÷", .bin), "cdot": ("⋅", .bin),
        "ast": ("∗", .bin), "star": ("⋆", .bin), "circ": ("∘", .bin), "bullet": ("∙", .bin), "cap": ("∩", .bin),
        "cup": ("∪", .bin), "wedge": ("∧", .bin), "land": ("∧", .bin), "vee": ("∨", .bin), "lor": ("∨", .bin),
        "setminus": ("∖", .bin), "smallsetminus": ("∖", .bin), "oplus": ("⊕", .bin), "ominus": ("⊖", .bin),
        "otimes": ("⊗", .bin), "oslash": ("⊘", .bin), "odot": ("⊙", .bin), "dagger": ("†", .bin),
        "ddagger": ("‡", .bin), "amalg": ("⨿", .bin), "uplus": ("⊎", .bin), "sqcap": ("⊓", .bin),
        "sqcup": ("⊔", .bin), "triangleleft": ("◁", .bin), "triangleright": ("▷", .bin), "wr": ("≀", .bin),
        "diamond": ("⋄", .bin), "bigtriangleup": ("△", .bin), "bigtriangledown": ("▽", .bin), "boxplus": ("⊞", .bin),
        "boxtimes": ("⊠", .bin), "ltimes": ("⋉", .bin), "rtimes": ("⋊", .bin), "cdotp": ("⋅", .punct),
        // Relations
        "leq": ("≤", .rel), "le": ("≤", .rel), "geq": ("≥", .rel), "ge": ("≥", .rel), "neq": ("≠", .rel),
        "ne": ("≠", .rel), "equiv": ("≡", .rel), "approx": ("≈", .rel), "sim": ("∼", .rel), "simeq": ("≃", .rel),
        "cong": ("≅", .rel), "propto": ("∝", .rel), "in": ("∈", .rel), "notin": ("∉", .rel), "ni": ("∋", .rel),
        "owns": ("∋", .rel), "subset": ("⊂", .rel), "supset": ("⊃", .rel), "subseteq": ("⊆", .rel),
        "supseteq": ("⊇", .rel), "subsetneq": ("⊊", .rel), "supsetneq": ("⊋", .rel), "sqsubseteq": ("⊑", .rel),
        "sqsupseteq": ("⊒", .rel), "perp": ("⊥", .rel), "parallel": ("∥", .rel), "mid": ("∣", .rel),
        "nmid": ("∤", .rel), "models": ("⊨", .rel), "vdash": ("⊢", .rel), "dashv": ("⊣", .rel), "ll": ("≪", .rel),
        "gg": ("≫", .rel), "lll": ("⋘", .rel), "ggg": ("⋙", .rel), "prec": ("≺", .rel), "succ": ("≻", .rel),
        "preceq": ("⪯", .rel), "succeq": ("⪰", .rel), "leqslant": ("⩽", .rel), "geqslant": ("⩾", .rel),
        "lesssim": ("≲", .rel), "gtrsim": ("≳", .rel), "approxeq": ("≊", .rel), "doteq": ("≐", .rel),
        "asymp": ("≍", .rel), "bowtie": ("⋈", .rel), "smile": ("⌣", .rel), "frown": ("⌢", .rel),
        "coloneqq": ("≔", .rel), "eqqcolon": ("≕", .rel), "triangleq": ("≜", .rel), "nleq": ("≰", .rel),
        "ngeq": ("≱", .rel), "nsim": ("≁", .rel), "ncong": ("≇", .rel), "nsubseteq": ("⊈", .rel),
        "to": ("→", .rel), "rightarrow": ("→", .rel), "leftarrow": ("←", .rel), "gets": ("←", .rel),
        "leftrightarrow": ("↔", .rel), "Rightarrow": ("⇒", .rel), "Leftarrow": ("⇐", .rel),
        "Leftrightarrow": ("⇔", .rel), "iff": ("⟺", .rel), "implies": ("⟹", .rel), "impliedby": ("⟸", .rel),
        "mapsto": ("↦", .rel), "longmapsto": ("⟼", .rel), "longrightarrow": ("⟶", .rel),
        "longleftarrow": ("⟵", .rel), "longleftrightarrow": ("⟷", .rel), "Longrightarrow": ("⟹", .rel),
        "Longleftarrow": ("⟸", .rel), "Longleftrightarrow": ("⟺", .rel), "hookrightarrow": ("↪", .rel),
        "hookleftarrow": ("↩", .rel), "uparrow": ("↑", .rel), "downarrow": ("↓", .rel), "updownarrow": ("↕", .rel),
        "Uparrow": ("⇑", .rel), "Downarrow": ("⇓", .rel), "Updownarrow": ("⇕", .rel), "nearrow": ("↗", .rel),
        "searrow": ("↘", .rel), "swarrow": ("↙", .rel), "nwarrow": ("↖", .rel), "rightleftharpoons": ("⇌", .rel),
        "leftrightharpoons": ("⇋", .rel), "rightharpoonup": ("⇀", .rel), "rightharpoondown": ("⇁", .rel),
        "leftharpoonup": ("↼", .rel), "leftharpoondown": ("↽", .rel), "xrightarrow": ("⟶", .rel),
        "xleftarrow": ("⟵", .rel), "nrightarrow": ("↛", .rel), "nleftarrow": ("↚", .rel), "nRightarrow": ("⇏", .rel),
        "circlearrowleft": ("↺", .rel), "circlearrowright": ("↻", .rel), "rightrightarrows": ("⇉", .rel),
        "leftleftarrows": ("⇇", .rel), "therefore": ("∴", .rel), "because": ("∵", .rel),
        // Ordinary symbols
        "infty": ("∞", .ord), "partial": ("∂", .ord), "nabla": ("∇", .ord), "forall": ("∀", .ord),
        "exists": ("∃", .ord), "nexists": ("∄", .ord), "neg": ("¬", .ord), "lnot": ("¬", .ord),
        "emptyset": ("∅", .ord), "varnothing": ("⌀", .ord), "hbar": ("ℏ", .ord), "hslash": ("ℏ", .ord),
        "ell": ("ℓ", .ord), "Re": ("ℜ", .ord), "Im": ("ℑ", .ord), "aleph": ("ℵ", .ord), "beth": ("ℶ", .ord),
        "wp": ("℘", .ord), "angle": ("∠", .ord), "measuredangle": ("∡", .ord), "triangle": ("△", .ord),
        "square": ("□", .ord), "Box": ("□", .ord), "blacksquare": ("■", .ord), "lozenge": ("◊", .ord),
        "prime": ("′", .ord), "backslash": ("∖", .ord), "top": ("⊤", .ord), "bot": ("⊥", .ord),
        "ldots": ("…", .inner), "dots": ("…", .inner), "dotsc": ("…", .inner), "dotsb": ("⋯", .inner),
        "cdots": ("⋯", .inner), "vdots": ("⋮", .ord), "ddots": ("⋱", .inner), "colon": (":", .punct),
        "surd": ("√", .ord), "degree": ("°", .ord), "clubsuit": ("♣", .ord), "diamondsuit": ("♢", .ord),
        "heartsuit": ("♡", .ord), "spadesuit": ("♠", .ord), "flat": ("♭", .ord), "natural": ("♮", .ord),
        "sharp": ("♯", .ord), "imath": ("ı", .ord), "jmath": ("ȷ", .ord), "S": ("§", .ord), "P": ("¶", .ord),
        "dag": ("†", .ord), "ddag": ("‡", .ord), "copyright": ("©", .ord), "pounds": ("£", .ord),
        "checkmark": ("✓", .ord), "complement": ("∁", .ord), "mho": ("℧", .ord), "eth": ("ð", .ord),
        "$": ("$", .ord), "%": ("%", .ord), "&": ("&", .ord), "#": ("#", .ord), "_": ("_", .ord),
        "{": ("{", .open), "}": ("}", .close), "|": ("‖", .ord), "lbrace": ("{", .open), "rbrace": ("}", .close),
        "langle": ("⟨", .open), "rangle": ("⟩", .close), "lfloor": ("⌊", .open), "rfloor": ("⌋", .close),
        "lceil": ("⌈", .open), "rceil": ("⌉", .close), "lvert": ("|", .open), "rvert": ("|", .close),
        "lVert": ("‖", .open), "rVert": ("‖", .close), "vert": ("|", .ord), "Vert": ("‖", .ord),
        "lbrack": ("[", .open), "rbrack": ("]", .close), "ulcorner": ("⌜", .open), "urcorner": ("⌝", .close),
        "llcorner": ("⌞", .open), "lrcorner": ("⌟", .close), "lgroup": ("⟮", .open), "rgroup": ("⟯", .close),
        "ldotp": (".", .punct), "textbackslash": ("\\", .ord), "maltese": ("✠", .ord), "bigstar": ("★", .ord),
        "blacktriangle": ("▲", .ord), "circledast": ("⊛", .bin), "dotplus": ("∔", .bin),
    ]

    static let bigOperators: [String: (String, Bool)] = [
        "sum": ("∑", true), "prod": ("∏", true), "coprod": ("∐", true), "int": ("∫", false),
        "iint": ("∬", false), "iiint": ("∭", false), "oint": ("∮", false), "oiint": ("∯", false),
        "bigcup": ("⋃", true), "bigcap": ("⋂", true), "bigoplus": ("⨁", true), "bigotimes": ("⨂", true),
        "bigodot": ("⨀", true), "bigvee": ("⋁", true), "bigwedge": ("⋀", true), "bigsqcup": ("⨆", true),
        "biguplus": ("⨄", true), "intop": ("∫", true), "smallint": ("∫", false),
    ]

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "arccot", "sinh", "cosh", "tanh",
        "coth", "sech", "csch", "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf",
        "det", "dim", "ker", "deg", "gcd", "lcm", "arg", "hom", "Pr", "injlim", "projlim", "argmax", "argmin",
        "tr", "rank", "sgn", "Tr", "erf", "span",
    ]

    static let limitFunctions: Set<String> = [
        "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "lcm", "Pr", "injlim", "projlim",
        "argmax", "argmin",
    ]

    static let spaces: [String: CGFloat] = [
        ",": 3.0 / 18, "thinspace": 3.0 / 18, ":": 4.0 / 18, ">": 4.0 / 18, "medspace": 4.0 / 18,
        ";": 5.0 / 18, "thickspace": 5.0 / 18, "!": -3.0 / 18, "negthinspace": -3.0 / 18, " ": 0.28,
        "quad": 1, "qquad": 2, "enspace": 0.5, "space": 0.28, "nobreakspace": 0.28,
    ]

    static let fontCommands: [String: MathFont] = [
        "mathrm": .roman, "mathup": .roman, "rm": .roman, "mathbf": .bold, "bf": .bold, "mathit": .italic,
        "it": .italic, "mathbb": .blackboard, "Bbb": .blackboard, "mathcal": .calligraphic, "cal": .calligraphic,
        "mathscr": .calligraphic, "mathfrak": .fraktur, "frak": .fraktur, "mathsf": .sansSerif, "sf": .sansSerif,
        "mathtt": .monospace, "tt": .monospace, "boldsymbol": .boldItalic, "bm": .boldItalic, "pmb": .boldItalic,
        "mathnormal": .italic,
    ]

    /// Accent character and whether it stretches over wide content.
    static let accents: [String: (String, Bool)] = [
        "hat": ("\u{02C6}", false), "widehat": ("\u{02C6}", true), "check": ("\u{02C7}", false),
        "widecheck": ("\u{02C7}", true), "tilde": ("\u{02DC}", false), "widetilde": ("\u{02DC}", true),
        "acute": ("\u{02CA}", false), "grave": ("\u{02CB}", false), "dot": ("\u{02D9}", false),
        "ddot": ("\u{00A8}", false), "dddot": ("\u{20DB}", false), "breve": ("\u{02D8}", false),
        "bar": ("\u{00AF}", false), "vec": ("→", false), "mathring": ("\u{02DA}", false),
        "overrightarrow": ("→", true), "overleftarrow": ("←", true), "overleftrightarrow": ("↔", true),
    ]

    static let delimiterCommands: [String: String] = [
        "{": "{", "}": "}", "lbrace": "{", "rbrace": "}", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊",
        "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "vert": "|", "Vert": "‖", "lvert": "|", "rvert": "|",
        "lVert": "‖", "rVert": "‖", "|": "‖", "backslash": "∖", "uparrow": "↑", "downarrow": "↓",
        "lbrack": "[", "rbrack": "]", "lgroup": "⟮", "rgroup": "⟯",
    ]

    static let negations: [String: String] = [
        "=": "≠", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱", "∈": "∉", "⊂": "⊄", "⊃": "⊅", "⊆": "⊈", "⊇": "⊉",
        "∼": "≁", "≅": "≇", "≈": "≉", "≡": "≢", "∣": "∤", "∥": "∦", "→": "↛", "←": "↚", "⇒": "⇏",
        "⇔": "⇎", "∃": "∄",
    ]
}

// MARK: - Boxes

/// A laid-out piece of math. Coordinates are TeX-like: `x` grows to the
/// right, `y` grows upwards from the baseline.
class MathBox {
    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var atomClass: AtomClass = .ord

    var height: CGFloat { ascent + descent }

    /// Draws with the baseline origin at `(x, y)` in a y-up context.
    func draw(in ctx: CGContext, x: CGFloat, y: CGFloat, color: CGColor) {}
}

final class SpaceBox: MathBox {
    init(width: CGFloat) {
        super.init()
        self.width = width
    }
}

final class GlyphBox: MathBox {
    let line: CTLine
    let color: NSColor?
    /// Bottom of the glyph ink relative to the baseline (may be above it).
    private(set) var inkBottom: CGFloat = 0
    private let glyphOffsetX: CGFloat

    init(_ text: String, font: CTFont, color: NSColor?) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        self.color = color
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let typographic = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        glyphOffsetX = 0
        super.init()
        width = typographic
        if bounds.isNull || bounds.isEmpty {
            ascent = CTFontGetXHeight(font)
            descent = 0
        } else {
            ascent = max(bounds.maxY, 0)
            descent = max(-bounds.minY, 0)
            inkBottom = bounds.minY
            // Italic glyphs may overhang their advance; keep them inside the box.
            if bounds.maxX > width { width = bounds.maxX + 0.5 }
        }
    }

    override func draw(in ctx: CGContext, x: CGFloat, y: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(self.color?.cgColor ?? color)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x + glyphOffsetX, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

final class RuleBox: MathBox {
    let color: NSColor?

    init(width: CGFloat, thickness: CGFloat, raise: CGFloat, color: NSColor?) {
        self.color = color
        super.init()
        self.width = width
        ascent = raise + thickness
        descent = -raise
    }

    override func draw(in ctx: CGContext, x: CGFloat, y: CGFloat, color: CGColor) {
        ctx.setFillColor(self.color?.cgColor ?? color)
        ctx.fill(CGRect(x: x, y: y - descent, width: width, height: ascent + descent))
    }
}

/// Children placed at explicit offsets relative to the box origin.
final class PlacedBox: MathBox {
    struct Item {
        var box: MathBox
        var x: CGFloat
        var y: CGFloat
    }

    var items: [Item] = []
    var color: NSColor?

    init(items: [Item], width: CGFloat, color: NSColor? = nil) {
        self.items = items
        self.color = color
        super.init()
        self.width = width
        ascent = items.map { $0.y + $0.box.ascent }.max() ?? 0
        descent = items.map { $0.box.descent - $0.y }.max() ?? 0
        ascent = max(ascent, 0)
        descent = max(descent, 0)
    }

    override func draw(in ctx: CGContext, x: CGFloat, y: CGFloat, color: CGColor) {
        let c = self.color?.cgColor ?? color
        for item in items { item.box.draw(in: ctx, x: x + item.x, y: y + item.y, color: c) }
    }
}

func HBox(_ boxes: [MathBox], color: NSColor? = nil) -> PlacedBox {
    var x: CGFloat = 0
    var items: [PlacedBox.Item] = []
    for box in boxes {
        items.append(.init(box: box, x: x, y: 0))
        x += box.width
    }
    return PlacedBox(items: items, width: x, color: color)
}

/// Custom vector drawing (radical signs, stretchy delimiters, braces, boxes).
final class PathBox: MathBox {
    let draw: (CGContext, CGFloat, CGFloat) -> Void
    let color: NSColor?

    init(width: CGFloat, ascent: CGFloat, descent: CGFloat, color: NSColor?,
         draw: @escaping (CGContext, CGFloat, CGFloat) -> Void) {
        self.draw = draw
        self.color = color
        super.init()
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }

    override func draw(in ctx: CGContext, x: CGFloat, y: CGFloat, color: CGColor) {
        ctx.saveGState()
        let c = self.color?.cgColor ?? color
        ctx.setFillColor(c)
        ctx.setStrokeColor(c)
        draw(ctx, x, y)
        ctx.restoreGState()
    }
}

// MARK: - Layout

struct MathLayout {
    let fontSize: CGFloat

    private static let mathFontName: String = {
        for name in ["STIXTwoMath-Regular", "STIX Two Math", "STIXGeneral-Regular", "Cambria Math"]
        where NSFont(name: name, size: 12) != nil {
            return name
        }
        return "Times New Roman"
    }()

    private static var fontCache: [String: CTFont] = [:]
    private static let cacheLock = NSLock()

    private func font(_ size: CGFloat, name: String = MathLayout.mathFontName) -> CTFont {
        let key = "\(name)|\(size)"
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let f = Self.fontCache[key] { return f }
        let f = CTFontCreateWithName(name as CFString, size, nil)
        Self.fontCache[key] = f
        return f
    }

    private func textFont(_ size: CGFloat, _ mathFont: MathFont) -> CTFont {
        switch mathFont {
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular) as CTFont
        case .sansSerif:
            return NSFont.systemFont(ofSize: size * 0.95) as CTFont
        case .bold:
            return font(size, name: NSFont(name: "STIXTwoText-Bold", size: size) != nil ? "STIXTwoText-Bold" : "Times New Roman Bold")
        case .italic, .boldItalic:
            return font(size, name: NSFont(name: "STIXTwoText-Italic", size: size) != nil ? "STIXTwoText-Italic" : "Times New Roman Italic")
        default:
            return font(size, name: NSFont(name: "STIXTwoText", size: size) != nil ? "STIXTwoText" : "Times New Roman")
        }
    }

    private func size(_ style: MathStyle) -> CGFloat { fontSize * style.scale }
    private func em(_ style: MathStyle) -> CGFloat { size(style) }
    private func axis(_ style: MathStyle) -> CGFloat { size(style) * 0.25 }
    private func ruleThickness(_ style: MathStyle) -> CGFloat { max(size(style) * 0.055, 0.6) }

    // MARK: Lists and spacing

    func layoutList(_ nodes: [MathNode], style: MathStyle, color: NSColor?) -> MathBox {
        var boxes: [MathBox] = []
        var previous: AtomClass?
        var style = style
        var i = 0
        let flattened = nodes
        while i < flattened.count {
            let node = flattened[i]
            i += 1
            if case .styled(let s, let rest) = node {
                let box = layoutList(rest, style: s, color: color)
                appendWithSpacing(box, &boxes, &previous, style: style)
                style = s
                continue
            }
            let box = layoutNode(node, style: style, color: color)
            if case .space = node {
                boxes.append(box)
                continue
            }
            appendWithSpacing(box, &boxes, &previous, style: style)
        }
        // A trailing binary operator is ordinary.
        return HBox(boxes, color: color)
    }

    private func appendWithSpacing(_ box: MathBox, _ boxes: inout [MathBox], _ previous: inout AtomClass?, style: MathStyle) {
        var cls = box.atomClass
        if cls == .bin, previous == nil || [.bin, .op, .rel, .open, .punct].contains(previous!) { cls = .ord }
        if let prev = previous {
            let space = spacing(prev, cls, style: style)
            if space > 0 { boxes.append(SpaceBox(width: space)) }
        }
        box.atomClass = cls
        boxes.append(box)
        previous = cls
    }

    /// TeX inter-atom spacing (thin = 3mu, medium = 4mu, thick = 5mu).
    private func spacing(_ left: AtomClass, _ right: AtomClass, style: MathStyle) -> CGFloat {
        let thin = em(style) * 3 / 18, medium = em(style) * 4 / 18, thick = em(style) * 5 / 18
        let tight = style == .script || style == .scriptScript
        switch (left, right) {
        case (.ord, .op), (.op, .ord), (.op, .op), (.close, .op), (.inner, .op): return thin
        case (_, .bin) where left != .bin, (.bin, _): return tight ? 0 : medium
        case (_, .rel) where left != .rel, (.rel, _) where right != .rel: return tight ? 0 : thick
        case (.punct, _): return tight ? 0 : thin
        case (.inner, .ord), (.ord, .inner), (.inner, .open), (.close, .inner), (.inner, .inner), (.inner, .punct):
            return tight ? 0 : thin
        default: return 0
        }
    }

    // MARK: Nodes

    func layoutNode(_ node: MathNode, style: MathStyle, color: NSColor?) -> MathBox {
        switch node {
        case .atom(let text, let cls, let mathFont):
            let box = glyphs(text, mathFont, style: style, color: color)
            box.atomClass = cls
            return box
        case .bigOp(let text, let limits, let isFunction):
            return bigOperator(text, isFunction: isFunction, style: style, color: color, limits: limits)
        case .group(let nodes):
            return layoutList(nodes, style: style, color: color)
        case .fraction(let num, let den, let fracStyle, let rule, let left, let right):
            return fraction(num, den, style: fracStyle ?? style, rule: rule, left: left, right: right, color: color)
        case .radical(let body, let index):
            return radical(body, index: index, style: style, color: color)
        case .scripts(let base, let sup, let sub):
            return scripts(base, sup: sup, sub: sub, style: style, color: color)
        case .leftRight(let left, let body, let right):
            return leftRight(left, body, right, style: style, color: color)
        case .middle(let d):
            let box = delimiter(d, height: em(style), style: style, color: color)
            box.atomClass = .rel
            return box
        case .sizedDelimiter(let d, let scale, let cls):
            let box = delimiter(d, height: em(style) * scale, style: style, color: color, centered: true)
            box.atomClass = cls
            return box
        case .accent(let accent, let body, let stretch):
            return self.accent(accent, body, stretch: stretch, style: style, color: color)
        case .overline(let body):
            let inner = layoutList(body, style: style, color: color)
            let t = ruleThickness(style)
            let rule = RuleBox(width: inner.width, thickness: t, raise: inner.ascent + t * 2, color: color)
            return PlacedBox(items: [.init(box: inner, x: 0, y: 0), .init(box: rule, x: 0, y: 0)], width: inner.width)
        case .underline(let body):
            let inner = layoutList(body, style: style, color: color)
            let t = ruleThickness(style)
            let rule = RuleBox(width: inner.width, thickness: t, raise: -inner.descent - t * 3, color: color)
            return PlacedBox(items: [.init(box: inner, x: 0, y: 0), .init(box: rule, x: 0, y: 0)], width: inner.width)
        case .brace(let body, let label, let over):
            return brace(body, label: label, over: over, style: style, color: color)
        case .stack(let top, let base, let bottom):
            let box = stack(top: top, base: base, bottom: bottom, style: style, color: color)
            box.atomClass = .rel
            return box
        case .text(let text, let mathFont):
            return GlyphBox(text, font: textFont(size(style), mathFont), color: color)
        case .space(let amount):
            return SpaceBox(width: amount * em(style))
        case .colored(let c, let nodes):
            return layoutList(nodes, style: style, color: c)
        case .styled(let s, let nodes):
            return layoutList(nodes, style: s, color: color)
        case .matrix(let rows, let alignments, let left, let right, let spacing):
            return matrix(rows, alignments: alignments, left: left, right: right, spacing: spacing, style: style, color: color)
        case .boxed(let nodes):
            let inner = layoutList(nodes, style: style, color: color)
            let pad = em(style) * 0.25
            let w = inner.width + pad * 2
            let frame = PathBox(width: w, ascent: inner.ascent + pad, descent: inner.descent + pad, color: color) { ctx, x, y in
                ctx.setLineWidth(0.8)
                ctx.stroke(CGRect(x: x + 0.4, y: y - inner.descent - pad + 0.4, width: w - 0.8, height: inner.height + pad * 2 - 0.8))
            }
            return PlacedBox(items: [.init(box: frame, x: 0, y: 0), .init(box: inner, x: pad, y: 0)], width: w)
        case .negated(let inner):
            let box = layoutNode(inner, style: style, color: color)
            let slash = PathBox(width: 0, ascent: box.ascent, descent: box.descent, color: color) { ctx, x, y in
                ctx.setLineWidth(0.9)
                ctx.move(to: CGPoint(x: x + box.width * 0.75, y: y + box.ascent))
                ctx.addLine(to: CGPoint(x: x + box.width * 0.25, y: y - box.descent))
                ctx.strokePath()
            }
            let placed = PlacedBox(items: [.init(box: box, x: 0, y: 0), .init(box: slash, x: 0, y: 0)], width: box.width)
            placed.atomClass = box.atomClass
            return placed
        case .phantom(let nodes):
            let inner = layoutList(nodes, style: style, color: color)
            let space = SpaceBox(width: inner.width)
            space.ascent = inner.ascent
            space.descent = inner.descent
            return space
        case .error(let command):
            return GlyphBox(command, font: textFont(size(style), .roman), color: .systemRed)
        }
    }

    // MARK: Glyphs and fonts

    private func glyphs(_ text: String, _ mathFont: MathFont, style: MathStyle, color: NSColor?) -> MathBox {
        let mapped = MathAlphabets.map(text, mathFont)
        if mathFont == .monospace || mathFont == .sansSerif, mapped == text {
            return GlyphBox(text, font: textFont(size(style), mathFont), color: color)
        }
        return GlyphBox(mapped, font: font(size(style)), color: color)
    }

    private func bigOperator(_ text: String, isFunction: Bool, style: MathStyle, color: NSColor?, limits: Bool?) -> MathBox {
        let box: MathBox
        if isFunction {
            box = GlyphBox(text, font: textFont(size(style), .roman), color: color)
        } else {
            let isIntegral = "∫∬∭∮∯".contains(text)
            let scale: CGFloat = style == .display ? (isIntegral ? 2.0 : 1.55) : (isIntegral ? 1.3 : 1.1)
            let glyph = GlyphBox(text, font: font(size(style) * scale), color: color)
            // Center the operator on the math axis.
            let shift = axis(style) - (glyph.ascent - glyph.descent) / 2
            let placed = PlacedBox(items: [.init(box: glyph, x: 0, y: shift)], width: glyph.width)
            box = placed
        }
        box.atomClass = .op
        return box
    }

    // MARK: Fractions

    private func fraction(_ num: [MathNode], _ den: [MathNode], style: MathStyle, rule: Bool,
                          left: String?, right: String?, color: NSColor?) -> MathBox {
        let inner = style.fraction
        let n = layoutList(num, style: inner, color: color)
        let d = layoutList(den, style: inner, color: color)
        let t = rule ? ruleThickness(style) : 0
        let gap = style == .display ? t * 3 + em(style) * 0.06 : t + em(style) * 0.08
        let a = axis(style)
        let pad = em(style) * 0.08
        let width = max(n.width, d.width) + pad * 2
        let numShift = a + t / 2 + gap + n.descent
        let denShift = -(a - t / 2 - gap - d.ascent)
        var items: [PlacedBox.Item] = [
            .init(box: n, x: (width - n.width) / 2, y: numShift),
            .init(box: d, x: (width - d.width) / 2, y: -denShift),
        ]
        if rule { items.append(.init(box: RuleBox(width: width, thickness: t, raise: a - t / 2, color: color), x: 0, y: 0)) }
        let frac = PlacedBox(items: items, width: width)
        frac.atomClass = .inner
        guard left != nil || right != nil else {
            let spaced = HBox([SpaceBox(width: em(style) * 0.06), frac, SpaceBox(width: em(style) * 0.06)])
            spaced.atomClass = .inner
            return spaced
        }
        let h = max(frac.ascent - a, frac.descent + a) * 2
        var parts: [MathBox] = []
        if let left, !left.isEmpty { parts.append(delimiter(left, height: h, style: style, color: color, centered: true)) }
        parts.append(frac)
        if let right, !right.isEmpty { parts.append(delimiter(right, height: h, style: style, color: color, centered: true)) }
        let result = HBox(parts)
        result.atomClass = .inner
        return result
    }

    // MARK: Radicals

    private func radical(_ body: [MathNode], index: [MathNode]?, style: MathStyle, color: NSColor?) -> MathBox {
        let inner = layoutList(body, style: style, color: color)
        let t = ruleThickness(style)
        let gap = style == .display ? t * 2.5 + em(style) * 0.05 : t * 1.5 + em(style) * 0.04
        let ascent = max(inner.ascent, em(style) * 0.62) + gap + t
        let descent = max(inner.descent, em(style) * 0.18) + t
        let total = ascent + descent
        let signWidth = min(em(style) * 0.55 + total * 0.12, em(style) * 1.1)
        let bodyX = signWidth + em(style) * 0.04
        let width = bodyX + inner.width + em(style) * 0.08
        let sign = PathBox(width: width, ascent: ascent, descent: descent, color: color) { ctx, x, y in
            let top = y + ascent - t / 2
            let bottom = y - descent + t * 0.5
            let tickY = y + (ascent - descent) * 0.28
            ctx.setLineJoin(.round)
            ctx.setLineCap(.butt)
            ctx.setLineWidth(t)
            ctx.move(to: CGPoint(x: x + signWidth * 0.05, y: tickY))
            ctx.addLine(to: CGPoint(x: x + signWidth * 0.25, y: tickY + t * 1.2))
            ctx.strokePath()
            ctx.setLineWidth(t * 1.7)
            ctx.move(to: CGPoint(x: x + signWidth * 0.25, y: tickY + t * 0.9))
            ctx.addLine(to: CGPoint(x: x + signWidth * 0.5, y: bottom))
            ctx.strokePath()
            ctx.setLineWidth(t)
            ctx.move(to: CGPoint(x: x + signWidth * 0.5, y: bottom))
            ctx.addLine(to: CGPoint(x: x + signWidth, y: top))
            ctx.addLine(to: CGPoint(x: x + width - em(style) * 0.02, y: top))
            ctx.strokePath()
        }
        var items: [PlacedBox.Item] = [.init(box: sign, x: 0, y: 0), .init(box: inner, x: bodyX, y: 0)]
        var totalWidth = width
        if let index {
            let indexBox = layoutList(index, style: .scriptScript, color: color)
            let shift = max(indexBox.width - signWidth * 0.55, 0)
            items = items.map { .init(box: $0.box, x: $0.x + shift, y: $0.y) }
            items.append(.init(box: indexBox, x: max(signWidth * 0.55 - indexBox.width, 0),
                               y: (ascent - descent) * 0.55 + indexBox.descent))
            totalWidth += shift
        }
        return PlacedBox(items: items, width: totalWidth)
    }

    // MARK: Scripts and limits

    private func scripts(_ base: MathNode, sup: [MathNode]?, sub: [MathNode]?, style: MathStyle, color: NSColor?) -> MathBox {
        let baseBox = layoutNode(base, style: style, color: color)
        let small = style.smaller
        let supBox = sup.map { layoutList($0, style: small, color: color) }
        let subBox = sub.map { layoutList($0, style: small, color: color) }

        var useLimits = false
        if case .bigOp(let text, let limits, let isFunction) = base {
            if let limits { useLimits = limits }
            else { useLimits = style == .display && (isFunction || !"∫∬∭∮∯".contains(text)) }
        }
        if case .brace = base { useLimits = true }
        if useLimits {
            let gap = em(style) * 0.12
            let width = max(baseBox.width, supBox?.width ?? 0, subBox?.width ?? 0)
            var items: [PlacedBox.Item] = [.init(box: baseBox, x: (width - baseBox.width) / 2, y: 0)]
            if let supBox {
                items.append(.init(box: supBox, x: (width - supBox.width) / 2, y: baseBox.ascent + gap + supBox.descent))
            }
            if let subBox {
                items.append(.init(box: subBox, x: (width - subBox.width) / 2, y: -(baseBox.descent + gap + subBox.ascent)))
            }
            let placed = PlacedBox(items: items, width: width)
            placed.atomClass = baseBox.atomClass
            return placed
        }

        let size = em(style)
        let isSimple: Bool
        switch base {
        case .atom, .text: isSimple = true
        default: isSimple = false
        }
        var supShift = isSimple ? size * (style == .display ? 0.42 : 0.38) : baseBox.ascent - size * 0.22
        var subShift = isSimple ? size * 0.18 : baseBox.descent + size * 0.12
        if let supBox { supShift = max(supShift, supBox.descent + size * 0.18) }
        if let subBox { subShift = max(subShift, subBox.ascent - size * 0.32) }
        if let supBox, let subBox {
            let gap = (supShift - supBox.descent) - (subBox.ascent - subShift)
            let minGap = ruleThickness(style) * 4
            if gap < minGap { subShift += minGap - gap }
        }
        var italicCorrection: CGFloat = 0
        if case .atom(_, _, .italic) = base { italicCorrection = size * 0.06 }
        var items: [PlacedBox.Item] = [.init(box: baseBox, x: 0, y: 0)]
        var width = baseBox.width
        let scriptX = baseBox.width + size * 0.02
        if let supBox {
            items.append(.init(box: supBox, x: scriptX + italicCorrection, y: supShift))
            width = max(width, scriptX + italicCorrection + supBox.width)
        }
        if let subBox {
            items.append(.init(box: subBox, x: scriptX - (baseBox.atomClass == .op ? size * 0.12 : 0), y: -subShift))
            width = max(width, scriptX + subBox.width)
        }
        let placed = PlacedBox(items: items, width: width + size * 0.04)
        placed.atomClass = baseBox.atomClass
        return placed
    }

    // MARK: Delimiters

    private func leftRight(_ left: String, _ body: [MathNode], _ right: String, style: MathStyle, color: NSColor?) -> MathBox {
        // Lay out the body first to find the delimiter height, then middle delimiters.
        var bodyNodes = body
        var middles: [Int] = []
        for (k, node) in bodyNodes.enumerated() { if case .middle = node { middles.append(k) } }
        let bodyBox = layoutList(bodyNodes.filter { if case .middle = $0 { return false }; return true }, style: style, color: color)
        let a = axis(style)
        let height = max(bodyBox.ascent - a, bodyBox.descent + a) * 2 + em(style) * 0.1
        if !middles.isEmpty {
            for k in middles {
                if case .middle(let d) = bodyNodes[k] { bodyNodes[k] = .sizedDelimiter(d, height / em(style), .rel) }
            }
        }
        let inner = middles.isEmpty ? bodyBox : layoutList(bodyNodes, style: style, color: color)
        var parts: [MathBox] = []
        if !left.isEmpty { parts.append(delimiter(left, height: height, style: style, color: color, centered: true)) }
        parts.append(inner)
        if !right.isEmpty { parts.append(delimiter(right, height: height, style: style, color: color, centered: true)) }
        let box = HBox(parts)
        box.atomClass = .inner
        return box
    }

    /// A delimiter at least `height` tall, centered on the math axis. Small
    /// sizes use the font's glyph; larger ones are drawn as vector shapes.
    private func delimiter(_ d: String, height: CGFloat, style: MathStyle, color: NSColor?, centered: Bool = true) -> MathBox {
        let size = em(style)
        let a = axis(style)
        let natural = GlyphBox(d, font: font(size), color: color)
        if height <= max(natural.height, size) * 1.05 || d.isEmpty {
            let shift = centered ? a - (natural.ascent - natural.descent) / 2 : 0
            let placed = PlacedBox(items: [.init(box: natural, x: 0, y: shift)], width: natural.width)
            placed.atomClass = "([{⟨⌊⌈".contains(d) ? .open : ")]}⟩⌋⌉".contains(d) ? .close : .ord
            return placed
        }
        let half = height / 2
        let top = a + half
        let bottom = a - half
        let t = max(size * 0.07, 0.8)
        let width: CGFloat
        let draw: (CGContext, CGFloat, CGFloat) -> Void
        switch d {
        case "(", ")":
            width = min(size * 0.35 + height * 0.08, size * 0.9)
            let mirrored = d == ")"
            draw = { ctx, x, y in
                let outer = width * 0.85, inner = width * 0.85 - t * 1.6
                func px(_ v: CGFloat) -> CGFloat { mirrored ? x + width - v : x + v }
                let midY = y + a
                ctx.move(to: CGPoint(x: px(width * 0.8), y: y + top))
                ctx.addQuadCurve(to: CGPoint(x: px(width * 0.8), y: y + bottom),
                                 control: CGPoint(x: px(width * 0.8 - outer * 1.25), y: midY))
                ctx.addLine(to: CGPoint(x: px(width * 0.8 + t * 0.2), y: y + bottom))
                ctx.addQuadCurve(to: CGPoint(x: px(width * 0.8 + t * 0.2), y: y + top),
                                 control: CGPoint(x: px(width * 0.8 - inner * 1.25 + t * 0.2), y: midY))
                ctx.closePath()
                ctx.fillPath()
            }
        case "[", "]", "⌊", "⌋", "⌈", "⌉":
            width = size * 0.4
            let mirrored = d == "]" || d == "⌋" || d == "⌉"
            let hasTop = d == "[" || d == "]" || d == "⌈" || d == "⌉"
            let hasBottom = d == "[" || d == "]" || d == "⌊" || d == "⌋"
            draw = { ctx, x, y in
                let stemX = mirrored ? x + width * 0.7 - t : x + width * 0.3
                ctx.fill(CGRect(x: stemX, y: y + bottom, width: t, height: top - bottom))
                let armX = mirrored ? x + width * 0.25 : x + width * 0.3
                let armW = width * 0.45 + t
                if hasTop { ctx.fill(CGRect(x: armX, y: y + top - t, width: armW, height: t)) }
                if hasBottom { ctx.fill(CGRect(x: armX, y: y + bottom, width: armW, height: t)) }
            }
        case "{", "}":
            width = size * 0.5
            let mirrored = d == "}"
            draw = { ctx, x, y in
                func px(_ v: CGFloat) -> CGFloat { mirrored ? x + width - v : x + v }
                let mid = y + a
                let w = width
                ctx.setLineWidth(t)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: px(w * 0.8), y: y + top))
                ctx.addCurve(to: CGPoint(x: px(w * 0.5), y: y + top - min(half * 0.25, w)),
                             control1: CGPoint(x: px(w * 0.55), y: y + top), control2: CGPoint(x: px(w * 0.5), y: y + top - w * 0.2))
                ctx.addLine(to: CGPoint(x: px(w * 0.5), y: mid + min(half * 0.25, w)))
                ctx.addCurve(to: CGPoint(x: px(w * 0.15), y: mid),
                             control1: CGPoint(x: px(w * 0.5), y: mid + w * 0.15), control2: CGPoint(x: px(w * 0.35), y: mid))
                ctx.addCurve(to: CGPoint(x: px(w * 0.5), y: mid - min(half * 0.25, w)),
                             control1: CGPoint(x: px(w * 0.35), y: mid), control2: CGPoint(x: px(w * 0.5), y: mid - w * 0.15))
                ctx.addLine(to: CGPoint(x: px(w * 0.5), y: y + bottom + min(half * 0.25, w)))
                ctx.addCurve(to: CGPoint(x: px(w * 0.8), y: y + bottom),
                             control1: CGPoint(x: px(w * 0.5), y: y + bottom + w * 0.2), control2: CGPoint(x: px(w * 0.55), y: y + bottom))
                ctx.strokePath()
            }
        case "|", "‖", "∣", "∥":
            let double = d == "‖" || d == "∥"
            width = size * (double ? 0.45 : 0.28)
            draw = { ctx, x, y in
                if double {
                    ctx.fill(CGRect(x: x + width * 0.3 - t / 2, y: y + bottom, width: t * 0.8, height: top - bottom))
                    ctx.fill(CGRect(x: x + width * 0.7 - t / 2, y: y + bottom, width: t * 0.8, height: top - bottom))
                } else {
                    ctx.fill(CGRect(x: x + width / 2 - t * 0.4, y: y + bottom, width: t * 0.8, height: top - bottom))
                }
            }
        case "⟨", "⟩":
            width = min(size * 0.35 + height * 0.06, size * 0.8)
            let mirrored = d == "⟩"
            draw = { ctx, x, y in
                func px(_ v: CGFloat) -> CGFloat { mirrored ? x + width - v : x + v }
                ctx.setLineWidth(t * 0.9)
                ctx.setLineJoin(.miter)
                ctx.move(to: CGPoint(x: px(width * 0.8), y: y + top))
                ctx.addLine(to: CGPoint(x: px(width * 0.2), y: y + a))
                ctx.addLine(to: CGPoint(x: px(width * 0.8), y: y + bottom))
                ctx.strokePath()
            }
        default:
            // Any other glyph is scaled vertically.
            let scale = height / max(natural.height, 1)
            width = natural.width
            draw = { ctx, x, y in
                ctx.saveGState()
                ctx.translateBy(x: x, y: y + bottom)
                ctx.scaleBy(x: 1, y: scale)
                ctx.translateBy(x: 0, y: natural.descent)
                CTLineDraw(natural.line, ctx)
                ctx.restoreGState()
            }
        }
        let box = PathBox(width: width, ascent: max(top, 0), descent: max(-bottom, 0), color: color, draw: draw)
        box.atomClass = "([{⟨⌊⌈".contains(d) ? .open : ")]}⟩⌋⌉".contains(d) ? .close : .ord
        return box
    }

    // MARK: Accents, braces, stacks

    private func accent(_ accent: String, _ body: [MathNode], stretch: Bool, style: MathStyle, color: NSColor?) -> MathBox {
        let inner = layoutList(body, style: style, color: color)
        let size = em(style)
        let t = ruleThickness(style)
        let raise = max(inner.ascent, size * 0.45) + size * 0.05
        let isArrow = "→←↔".contains(accent)
        if stretch || isArrow, inner.width > size * 0.7 || isArrow {
            let w = inner.width
            let h = size * (isArrow ? 0.25 : 0.2)
            let mark = PathBox(width: w, ascent: raise + h + t, descent: 0, color: color) { ctx, x, y in
                let base = y + raise + t
                ctx.setLineWidth(t)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                switch accent {
                case "\u{02C6}", "\u{02C7}":
                    let up = accent == "\u{02C6}"
                    ctx.move(to: CGPoint(x: x, y: up ? base : base + h))
                    ctx.addLine(to: CGPoint(x: x + w / 2, y: up ? base + h : base))
                    ctx.addLine(to: CGPoint(x: x + w, y: up ? base : base + h))
                case "\u{02DC}":
                    ctx.move(to: CGPoint(x: x, y: base + h * 0.3))
                    ctx.addCurve(to: CGPoint(x: x + w, y: base + h * 0.7), control1: CGPoint(x: x + w * 0.3, y: base + h * 1.4),
                                 control2: CGPoint(x: x + w * 0.7, y: base - h * 0.4))
                default:
                    let mid = base + h / 2
                    ctx.move(to: CGPoint(x: x, y: mid))
                    ctx.addLine(to: CGPoint(x: x + w, y: mid))
                    if accent == "→" || accent == "↔" {
                        ctx.move(to: CGPoint(x: x + w - h * 0.9, y: mid + h * 0.6))
                        ctx.addLine(to: CGPoint(x: x + w, y: mid))
                        ctx.addLine(to: CGPoint(x: x + w - h * 0.9, y: mid - h * 0.6))
                    }
                    if accent == "←" || accent == "↔" {
                        ctx.move(to: CGPoint(x: x + h * 0.9, y: mid + h * 0.6))
                        ctx.addLine(to: CGPoint(x: x, y: mid))
                        ctx.addLine(to: CGPoint(x: x + h * 0.9, y: mid - h * 0.6))
                    }
                }
                ctx.strokePath()
            }
            return PlacedBox(items: [.init(box: inner, x: 0, y: 0), .init(box: mark, x: 0, y: 0)], width: inner.width)
        }
        let mark = GlyphBox(accent, font: font(size), color: color)
        // Place the accent glyph's ink just above the body.
        let x = (inner.width - mark.width) / 2 + (body.count == 1 ? size * 0.05 : 0)
        let markY = max(inner.ascent, size * 0.42) + size * 0.06 - mark.inkBottom
        return PlacedBox(items: [.init(box: inner, x: 0, y: 0),
                                 .init(box: mark, x: x, y: markY)],
                         width: max(inner.width, mark.width))
    }

    private func brace(_ body: [MathNode], label: [MathNode]?, over: Bool, style: MathStyle, color: NSColor?) -> MathBox {
        let inner = layoutList(body, style: style, color: color)
        let size = em(style)
        let h = size * 0.3
        let t = ruleThickness(style)
        let w = inner.width
        let y0 = over ? inner.ascent + size * 0.1 : -(inner.descent + size * 0.1 + h)
        let brace = PathBox(width: w, ascent: over ? y0 + h : 0, descent: over ? 0 : -y0, color: color) { ctx, x, y in
            let b = y + y0
            ctx.setLineWidth(t * 1.2)
            ctx.setLineCap(.round)
            let tip = over ? b + h : b
            let edge = over ? b : b + h
            let mid = (tip + edge) / 2
            ctx.move(to: CGPoint(x: x, y: edge))
            ctx.addQuadCurve(to: CGPoint(x: x + h, y: mid), control: CGPoint(x: x, y: mid))
            ctx.addLine(to: CGPoint(x: x + w / 2 - h, y: mid))
            ctx.addQuadCurve(to: CGPoint(x: x + w / 2, y: tip), control: CGPoint(x: x + w / 2, y: mid))
            ctx.addQuadCurve(to: CGPoint(x: x + w / 2 + h, y: mid), control: CGPoint(x: x + w / 2, y: mid))
            ctx.addLine(to: CGPoint(x: x + w - h, y: mid))
            ctx.addQuadCurve(to: CGPoint(x: x + w, y: edge), control: CGPoint(x: x + w, y: mid))
            ctx.strokePath()
        }
        var items: [PlacedBox.Item] = [.init(box: inner, x: 0, y: 0), .init(box: brace, x: 0, y: 0)]
        var width = w
        if let label {
            let l = layoutList(label, style: style.smaller, color: color)
            let y = over ? y0 + h + size * 0.08 + l.descent : y0 - size * 0.08 - l.ascent
            width = max(w, l.width)
            items = items.map { .init(box: $0.box, x: $0.x + (width - w) / 2, y: $0.y) }
            items.append(.init(box: l, x: (width - l.width) / 2, y: y))
        }
        return PlacedBox(items: items, width: width)
    }

    private func stack(top: [MathNode]?, base: [MathNode], bottom: [MathNode]?, style: MathStyle, color: NSColor?) -> MathBox {
        let baseBox = layoutList(base, style: style, color: color)
        let topBox = top.map { layoutList($0, style: style.smaller, color: color) }
        let bottomBox = bottom.map { layoutList($0, style: style.smaller, color: color) }
        let gap = em(style) * 0.08
        let width = max(baseBox.width, topBox?.width ?? 0, bottomBox?.width ?? 0)
        var items: [PlacedBox.Item] = [.init(box: baseBox, x: (width - baseBox.width) / 2, y: 0)]
        if let topBox {
            items.append(.init(box: topBox, x: (width - topBox.width) / 2, y: baseBox.ascent + gap + topBox.descent))
        }
        if let bottomBox {
            items.append(.init(box: bottomBox, x: (width - bottomBox.width) / 2, y: -(baseBox.descent + gap + bottomBox.ascent)))
        }
        return PlacedBox(items: items, width: width)
    }

    // MARK: Matrices and aligned environments

    private func matrix(_ rows: [[[MathNode]]], alignments: [NSTextAlignment], left: String?, right: String?,
                        spacing: CGFloat, style: MathStyle, color: NSColor?) -> MathBox {
        let cellStyle: MathStyle = style == .display && spacing == 0 ? .display : (style == .display ? .text : style)
        // In aligned environments the right-hand columns start after `&`, so a
        // leading relation still gets its spacing (TeX inserts an empty atom).
        let boxes = rows.map { row in
            row.enumerated().map { c, cell -> MathBox in
                let nodes: [MathNode] = spacing == 0 && c % 2 == 1 ? [.atom("", .ord, .roman)] + cell : cell
                return layoutList(nodes, style: cellStyle, color: color)
            }
        }
        let columns = boxes.map(\.count).max() ?? 0
        guard columns > 0 else { return SpaceBox(width: 0) }
        var colWidths = [CGFloat](repeating: 0, count: columns)
        for row in boxes { for (c, box) in row.enumerated() { colWidths[c] = max(colWidths[c], box.width) } }
        let size = em(style)
        let colGap = spacing == 0 ? size * 0.1 : size * spacing
        let rowGap = size * 0.3
        let strut = (asc: size * 0.7, desc: size * 0.28)
        var rowMetrics: [(asc: CGFloat, desc: CGFloat)] = boxes.map { row in
            (max(row.map(\.ascent).max() ?? 0, strut.asc), max(row.map(\.descent).max() ?? 0, strut.desc))
        }
        if rowMetrics.isEmpty { rowMetrics = [strut] }
        let totalHeight = rowMetrics.reduce(0) { $0 + $1.asc + $1.desc } + rowGap * CGFloat(max(rowMetrics.count - 1, 0))
        // Center the grid on the math axis.
        var y = totalHeight / 2 + axis(style)
        var items: [PlacedBox.Item] = []
        let totalWidth = colWidths.reduce(0, +) + colGap * CGFloat(columns - 1)
        for (r, row) in boxes.enumerated() {
            y -= rowMetrics[r].asc
            var x: CGFloat = 0
            for c in 0..<columns {
                if c < row.count {
                    let box = row[c]
                    let alignment = alignments.isEmpty ? .center : alignments[c % alignments.count]
                    let offset: CGFloat
                    switch alignment {
                    case .left: offset = 0
                    case .right: offset = colWidths[c] - box.width
                    default: offset = (colWidths[c] - box.width) / 2
                    }
                    items.append(.init(box: box, x: x + offset, y: y))
                }
                x += colWidths[c] + (c < columns - 1 ? (spacing == 0 && c % 2 == 0 ? 0 : colGap) : 0)
            }
            y -= rowMetrics[r].desc + rowGap
        }
        var grid: MathBox = PlacedBox(items: items, width: totalWidth)
        if left != nil || right != nil {
            let h = max(grid.ascent - axis(style), grid.descent + axis(style)) * 2 + size * 0.1
            var parts: [MathBox] = []
            if let left { parts.append(delimiter(left, height: h, style: style, color: color)) }
            parts.append(SpaceBox(width: size * 0.12))
            parts.append(grid)
            parts.append(SpaceBox(width: size * 0.12))
            if let right { parts.append(delimiter(right, height: h, style: style, color: color)) }
            grid = HBox(parts)
        }
        grid.atomClass = .inner
        return grid
    }
}

// MARK: - Unicode math alphabets

enum MathAlphabets {
    static func map(_ text: String, _ font: MathFont) -> String {
        guard font != .roman else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { out.append(map(scalar, font)) }
        return String(out)
    }

    private static let italicExceptions: [Character: Character] = ["h": "ℎ"]
    private static let blackboardExceptions: [Character: Character] = [
        "C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ",
    ]
    private static let scriptExceptions: [Character: Character] = [
        "B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ", "e": "ℯ", "g": "ℊ", "o": "ℴ",
    ]
    private static let frakturExceptions: [Character: Character] = ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"]

    private static func map(_ s: Unicode.Scalar, _ font: MathFont) -> Unicode.Scalar {
        let v = s.value
        let isUpper = v >= 0x41 && v <= 0x5A
        let isLower = v >= 0x61 && v <= 0x7A
        let isDigit = v >= 0x30 && v <= 0x39
        let ch = Character(s)
        func offset(_ upper: UInt32, _ lower: UInt32, _ digits: UInt32? = nil) -> Unicode.Scalar {
            if isUpper { return Unicode.Scalar(upper + v - 0x41) ?? s }
            if isLower { return Unicode.Scalar(lower + v - 0x61) ?? s }
            if isDigit, let digits { return Unicode.Scalar(digits + v - 0x30) ?? s }
            return s
        }
        switch font {
        case .italic:
            if let e = italicExceptions[ch] { return e.unicodeScalars.first! }
            if let greek = greekItalic(v) { return greek }
            return offset(0x1D434, 0x1D44E)
        case .bold: return offset(0x1D400, 0x1D41A, 0x1D7CE)
        case .boldItalic: return offset(0x1D468, 0x1D482, 0x1D7CE)
        case .blackboard:
            if let e = blackboardExceptions[ch] { return e.unicodeScalars.first! }
            return offset(0x1D538, 0x1D552, 0x1D7D8)
        case .calligraphic:
            if let e = scriptExceptions[ch] { return e.unicodeScalars.first! }
            return offset(0x1D49C, 0x1D4B6)
        case .fraktur:
            if let e = frakturExceptions[ch] { return e.unicodeScalars.first! }
            return offset(0x1D504, 0x1D51E)
        case .sansSerif: return offset(0x1D5A0, 0x1D5BA, 0x1D7E2)
        case .monospace: return offset(0x1D670, 0x1D68A, 0x1D7F6)
        case .roman: return s
        }
    }

    /// Lowercase Greek → mathematical italic Greek.
    private static func greekItalic(_ v: UInt32) -> Unicode.Scalar? {
        if v >= 0x3B1 && v <= 0x3C9 { return Unicode.Scalar(0x1D6FC + v - 0x3B1) }
        switch v {
        case 0x3F5: return Unicode.Scalar(0x1D716) // ϵ
        case 0x3D1: return Unicode.Scalar(0x1D717) // ϑ
        case 0x3F0: return Unicode.Scalar(0x1D718) // ϰ
        case 0x3D5: return Unicode.Scalar(0x1D719) // ϕ
        case 0x3F1: return Unicode.Scalar(0x1D71A) // ϱ
        case 0x3D6: return Unicode.Scalar(0x1D71B) // ϖ
        default: return nil
        }
    }
}

// MARK: - Attachment

/// Draws a laid-out formula inline with the text. Inline formulas sit on the
/// text baseline; display formulas shrink to fit narrow windows.
final class MathAttachmentCell: NSTextAttachmentCell {
    let box: MathBox
    let color: NSColor
    private let isDisplay: Bool
    private var scale: CGFloat = 1

    init(box: MathBox, color: NSColor, display: Bool) {
        self.box = box
        self.color = color
        self.isDisplay = display
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var padding: CGFloat { isDisplay ? 4 : 1 }

    override func cellSize() -> NSSize {
        NSSize(width: ceil(box.width + padding * 2), height: ceil(box.height + 2))
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -(box.descent + 1) * scale)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let natural = cellSize()
        let available = max(lineFrag.width - 8, 40)
        scale = isDisplay && natural.width > available ? max(available / natural.width, 0.35) : 1
        return NSRect(x: 0, y: -(box.descent + 1) * scale, width: natural.width * scale, height: natural.height * scale)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let flipped = NSGraphicsContext.current?.isFlipped ?? true
        ctx.saveGState()
        if flipped {
            ctx.translateBy(x: cellFrame.minX, y: cellFrame.maxY)
            ctx.scaleBy(x: scale, y: -scale)
        } else {
            ctx.translateBy(x: cellFrame.minX, y: cellFrame.minY)
            ctx.scaleBy(x: scale, y: scale)
        }
        // y-up coordinates with the box baseline at (padding, descent + 1).
        box.draw(in: ctx, x: padding, y: box.descent + 1, color: color.cgColor)
        ctx.restoreGState()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}
