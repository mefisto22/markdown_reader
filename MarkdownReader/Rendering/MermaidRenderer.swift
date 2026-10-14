import AppKit

/// Native renderer for Mermaid diagrams in ```` ```mermaid ```` blocks: no
/// WebKit, no JavaScript. Supports flowcharts (`graph` / `flowchart`, all
/// directions, node shapes, edge styles and labels, subgraphs, `style` /
/// `classDef`), sequence diagrams and pie charts. Other diagram types
/// return nil and are shown as source code.
enum MermaidRenderer {
    static func diagram(_ source: String, fontSize: CGFloat) -> MermaidDiagram? {
        let lines = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first?.lowercased() else { return nil }
        let body = Array(lines.dropFirst())
        let font = NSFont.systemFont(ofSize: max(fontSize * 0.82, 9))
        if header.hasPrefix("graph") || header.hasPrefix("flowchart") {
            let direction = header.split(separator: " ").dropFirst().first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ";")).uppercased() } ?? "TD"
            return Flowchart.parse(body, direction: direction).layout(font: font)
        }
        if header.hasPrefix("sequencediagram") {
            return SequenceDiagram.parse(body).layout(font: font)
        }
        if header.hasPrefix("pie") {
            return PieChart.parse(lines).layout(font: font)
        }
        return nil
    }

    /// The diagram type named in the first line (for the "not supported" note).
    static func diagramType(_ source: String) -> String {
        let first = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("%%") } ?? ""
        return String(first.split(separator: " ").first ?? "")
    }

    enum Colors {
        static let nodeFill = RenderColors.dynamic(light: NSColor(srgbRed: 0.93, green: 0.93, blue: 1, alpha: 1),
                                                   dark: NSColor(srgbRed: 0.17, green: 0.18, blue: 0.26, alpha: 1))
        static let nodeStroke = RenderColors.dynamic(light: NSColor(srgbRed: 0.58, green: 0.44, blue: 0.86, alpha: 1),
                                                     dark: NSColor(srgbRed: 0.55, green: 0.5, blue: 0.82, alpha: 1))
        static let edge = RenderColors.dynamic(light: NSColor(white: 0.2, alpha: 1), dark: NSColor(white: 0.8, alpha: 1))
        static let labelBackground = RenderColors.dynamic(light: NSColor(white: 0.97, alpha: 0.95),
                                                          dark: NSColor(white: 0.16, alpha: 0.95))
        static let groupFill = RenderColors.dynamic(light: NSColor(srgbRed: 1, green: 1, blue: 0.87, alpha: 1),
                                                    dark: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.16, alpha: 1))
        static let groupStroke = RenderColors.dynamic(light: NSColor(srgbRed: 0.67, green: 0.67, blue: 0.2, alpha: 1),
                                                      dark: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.25, alpha: 1))
        static let noteFill = RenderColors.dynamic(light: NSColor(srgbRed: 1, green: 0.96, blue: 0.68, alpha: 1),
                                                   dark: NSColor(srgbRed: 0.33, green: 0.31, blue: 0.15, alpha: 1))
        static let text = NSColor.textColor
        static let pie: [NSColor] = [
            NSColor(srgbRed: 0.42, green: 0.45, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.98, green: 0.69, blue: 0.29, alpha: 1),
            NSColor(srgbRed: 0.36, green: 0.73, blue: 0.53, alpha: 1), NSColor(srgbRed: 0.91, green: 0.38, blue: 0.43, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.42, blue: 0.79, alpha: 1), NSColor(srgbRed: 0.33, green: 0.68, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.55, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.65, green: 0.65, blue: 0.3, alpha: 1),
            NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1), NSColor(srgbRed: 0.95, green: 0.55, blue: 0.4, alpha: 1),
        ]
    }

    /// Mermaid label text: quotes removed, `<br>` and `\n` as line breaks,
    /// `#quot;`-style entity codes decoded, Markdown emphasis markers dropped.
    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("`") && s.hasSuffix("`")) {
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        for (code, value) in [("#quot;", "\""), ("#amp;", "&"), ("#lt;", "<"), ("#gt;", ">"), ("#35;", "#"), ("#59;", ";")] {
            s = s.replacingOccurrences(of: code, with: value)
        }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s
    }

    static func textSize(_ text: String, font: NSFont) -> NSSize {
        let size = (text as NSString).boundingRect(with: NSSize(width: 10_000, height: 10_000),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font]).size
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    static func drawText(_ text: String, centeredIn rect: NSRect, font: NSFont, color: NSColor = Colors.text) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let size = textSize(text, font: font)
        let r = NSRect(x: rect.midX - size.width / 2 - 1, y: rect.midY - size.height / 2, width: size.width + 2, height: size.height)
        (text as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
    }
}

/// A laid-out diagram: size plus a drawing closure in top-left coordinates.
final class MermaidDiagram {
    let size: NSSize
    let draw: () -> Void

    init(size: NSSize, draw: @escaping () -> Void) {
        self.size = size
        self.draw = draw
    }
}

// MARK: - Flowchart

struct Flowchart {
    enum Shape { case rect, round, stadium, subroutine, cylinder, circle, doubleCircle, diamond, hexagon, parallelogram, parallelogramAlt, trapezoid, trapezoidAlt, asymmetric }

    struct Node {
        var id: String
        var label: String
        var shape: Shape = .rect
        var fill: NSColor?
        var stroke: NSColor?
        var textColor: NSColor?
    }

    struct Edge {
        var from: String
        var to: String
        var label: String?
        var dotted = false
        var thick = false
        var invisible = false
        var arrowEnd = true
        var arrowStart = false
        var endMarker: Character = ">"
        var startMarker: Character = " "
    }

    struct Group {
        var title: String
        var members: [String]
    }

    var direction = "TD"
    var nodes: [String: Node] = [:]
    var order: [String] = []
    var edges: [Edge] = []
    var groups: [Group] = []

    static func parse(_ lines: [String], direction: String) -> Flowchart {
        var chart = Flowchart()
        chart.direction = direction
        var classDefs: [String: NodeStyle] = [:]
        var classAssignments: [(String, String)] = []
        var styles: [(String, String)] = []
        var groupStack: [Group] = []
        let statements = lines.flatMap { line -> [String] in
            // `;` separates statements outside quotes and brackets.
            var parts: [String] = []
            var current = ""
            var depth = 0
            var inQuote = false
            for ch in line {
                if ch == "\"" { inQuote.toggle() }
                if !inQuote {
                    if "[({".contains(ch) { depth += 1 } else if "])}".contains(ch) { depth = max(0, depth - 1) }
                }
                if ch == ";", depth == 0, !inQuote { parts.append(current); current = "" } else { current.append(ch) }
            }
            parts.append(current)
            return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        for statement in statements {
            let lower = statement.lowercased()
            if lower.hasPrefix("subgraph") {
                var title = String(statement.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                if let open = title.firstIndex(of: "["), title.hasSuffix("]") {
                    title = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
                }
                groupStack.append(Group(title: MermaidRenderer.cleanLabel(title), members: []))
                continue
            }
            if lower == "end" {
                if let group = groupStack.popLast() {
                    if !groupStack.isEmpty { groupStack[groupStack.count - 1].members += group.members }
                    chart.groups.append(group)
                }
                continue
            }
            if lower.hasPrefix("classdef ") {
                let parts = statement.split(separator: " ", maxSplits: 2).map(String.init)
                if parts.count == 3 { classDefs[parts[1]] = mermaidStyle(parts[2]) }
                continue
            }
            if lower.hasPrefix("class ") {
                let parts = statement.split(separator: " ").map(String.init)
                if parts.count >= 3 {
                    for id in parts[1].split(separator: ",") { classAssignments.append((String(id), parts[2])) }
                }
                continue
            }
            if lower.hasPrefix("style ") {
                let parts = statement.split(separator: " ", maxSplits: 2).map(String.init)
                if parts.count == 3 { styles.append((parts[1], parts[2])) }
                continue
            }
            if lower.hasPrefix("linkstyle") || lower.hasPrefix("click ") || lower.hasPrefix("direction ")
                || lower.hasPrefix("accTitle") || lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr") {
                continue
            }
            let ids = chart.parseChain(statement, classAssignments: &classAssignments)
            if !groupStack.isEmpty { groupStack[groupStack.count - 1].members += ids }
        }
        for (id, className) in classAssignments {
            guard let style = classDefs[className] else { continue }
            chart.apply(style, to: id)
        }
        for (id, raw) in styles { chart.apply(mermaidStyle(raw), to: id) }
        return chart
    }

    struct NodeStyle {
        var fill: NSColor?
        var stroke: NSColor?
        var color: NSColor?
    }

    /// Mermaid's comma-separated CSS: `fill:#f9f,stroke:#333,color:#fff`.
    private static func mermaidStyle(_ raw: String) -> NodeStyle {
        var style = NodeStyle()
        for part in raw.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "fill": style.fill = CSSColor.parse(kv[1])
            case "stroke": style.stroke = CSSColor.parse(kv[1])
            case "color": style.color = CSSColor.parse(kv[1])
            default: break
            }
        }
        return style
    }

    private mutating func apply(_ style: NodeStyle, to id: String) {
        guard nodes[id] != nil else { return }
        if let fill = style.fill { nodes[id]?.fill = fill }
        if let stroke = style.stroke { nodes[id]?.stroke = stroke }
        if let text = style.color { nodes[id]?.textColor = text }
    }

    /// Parses `A[Label] -->|text| B & C --> D` and returns the node ids seen.
    private mutating func parseChain(_ statement: String, classAssignments: inout [(String, String)]) -> [String] {
        let chars = Array(statement)
        var i = 0
        var seen: [String] = []
        var previous: [String] = []
        var pendingEdge: Edge?

        func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }

        while i < chars.count {
            skipSpaces()
            // One or more nodes joined by &.
            var group: [String] = []
            while true {
                skipSpaces()
                guard let id = parseNode(chars, &i, classAssignments: &classAssignments) else { break }
                group.append(id)
                seen.append(id)
                skipSpaces()
                if i < chars.count, chars[i] == "&" { i += 1; continue }
                break
            }
            guard !group.isEmpty else { break }
            if var edge = pendingEdge {
                for from in previous {
                    for to in group {
                        edge.from = from
                        edge.to = to
                        edges.append(edge)
                    }
                }
                pendingEdge = nil
            }
            previous = group
            skipSpaces()
            guard let edge = parseEdge(chars, &i) else { break }
            pendingEdge = edge
        }
        return seen
    }

    private static func isIDChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == "'"
    }

    private mutating func parseNode(_ chars: [Character], _ i: inout Int, classAssignments: inout [(String, String)]) -> String? {
        let start = i
        while i < chars.count, Self.isIDChar(chars[i]) {
            // Stop before an edge that starts with - or = or .
            if chars[i] == "-" || chars[i] == ".", i + 1 < chars.count, "-.=>".contains(chars[i + 1]) { break }
            i += 1
        }
        // Trailing hyphens belong to the edge (A-->B).
        while i > start, chars[i - 1] == "-" { i -= 1 }
        guard i > start else { return nil }
        let id = String(chars[start..<i])
        var label: String?
        var shape: Shape = .rect
        let openers: [(String, String, Shape)] = [
            ("(((", ")))", .doubleCircle), ("((", "))", .circle), ("([", "])", .stadium), ("[[", "]]", .subroutine),
            ("[(", ")]", .cylinder), ("{{", "}}", .hexagon), ("[/", "/]", .parallelogram), ("[\\", "\\]", .parallelogramAlt),
            ("[/", "\\]", .trapezoid), ("[\\", "/]", .trapezoidAlt), ("[", "]", .rect), ("(", ")", .round),
            ("{", "}", .diamond), (">", "]", .asymmetric),
        ]
        for (open, close, s) in openers where Self.matches(chars, i, open) {
            let contentStart = i + open.count
            var j = contentStart
            var inQuote = false
            var found = -1
            while j < chars.count {
                if chars[j] == "\"" { inQuote.toggle() }
                if !inQuote, Self.matches(chars, j, close) { found = j; break }
                j += 1
            }
            guard found >= 0 else { continue }
            label = String(chars[contentStart..<found])
            shape = s
            i = found + close.count
            break
        }
        // :::className shorthand
        if Self.matches(chars, i, ":::") {
            var j = i + 3
            while j < chars.count, Self.isIDChar(chars[j]) { j += 1 }
            classAssignments.append((id, String(chars[(i + 3)..<j])))
            i = j
        }
        if nodes[id] == nil {
            nodes[id] = Node(id: id, label: MermaidRenderer.cleanLabel(label ?? id), shape: shape)
            order.append(id)
        } else if let label {
            nodes[id]?.label = MermaidRenderer.cleanLabel(label)
            nodes[id]?.shape = shape
        }
        return id
    }

    private static func matches(_ chars: [Character], _ i: Int, _ s: String) -> Bool {
        var j = i
        for c in s {
            guard j < chars.count, chars[j] == c else { return false }
            j += 1
        }
        return true
    }

    private func parseEdge(_ chars: [Character], _ i: inout Int) -> Edge? {
        let rest = String(chars[i...])
        var edge = Edge(from: "", to: "")
        // Labeled forms: A-- text -->B, A-. text .->B, A== text ==>B
        let labeled = try! NSRegularExpression(pattern: "^(<)?(--|==|-\\.)\\s+(.+?)\\s+(-->|---|==>|===|\\.->|\\.-|--x|--o|==x|==o)")
        let plain = try! NSRegularExpression(pattern: "^(<|x|o)?(-{2,}|={2,}|-\\.+-|~{3,})(>|x|o)?")
        let ns = rest as NSString
        if let m = labeled.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
            let opener = ns.substring(with: m.range(at: 2))
            let closer = ns.substring(with: m.range(at: 4))
            edge.label = MermaidRenderer.cleanLabel(ns.substring(with: m.range(at: 3)))
            edge.dotted = opener == "-." || closer.hasPrefix(".")
            edge.thick = opener == "=="
            edge.arrowStart = m.range(at: 1).location != NSNotFound
            edge.arrowEnd = closer.hasSuffix(">") || closer.hasSuffix("x") || closer.hasSuffix("o")
            if let last = closer.last, "xo".contains(last) { edge.endMarker = last }
            i += m.range.length
        } else if let m = plain.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 2))
            edge.invisible = body.hasPrefix("~")
            edge.dotted = body.contains(".")
            edge.thick = body.hasPrefix("=")
            if m.range(at: 3).location != NSNotFound {
                let end = ns.substring(with: m.range(at: 3))
                edge.arrowEnd = true
                edge.endMarker = Character(end)
            } else {
                edge.arrowEnd = false
            }
            if m.range(at: 1).location != NSNotFound {
                edge.arrowStart = true
                edge.startMarker = Character(ns.substring(with: m.range(at: 1)))
            }
            i += m.range.length
        } else {
            return nil
        }
        // |label|
        while i < chars.count, chars[i] == " " { i += 1 }
        if i < chars.count, chars[i] == "|", let close = chars[(i + 1)...].firstIndex(of: "|") {
            edge.label = MermaidRenderer.cleanLabel(String(chars[(i + 1)..<close]))
            i = close + 1
        }
        return edge
    }

    // MARK: Layout

    func layout(font: NSFont) -> MermaidDiagram? {
        guard !order.isEmpty else { return nil }
        let horizontal = direction == "LR" || direction == "RL"
        let reversed = direction == "BT" || direction == "RL"

        // Node sizes.
        var sizes: [String: NSSize] = [:]
        for id in order {
            guard let node = nodes[id] else { continue }
            let text = MermaidRenderer.textSize(node.label, font: font)
            var w = text.width + 24, h = text.height + 16
            switch node.shape {
            case .diamond: w = text.width * 1.4 + 24; h = max(text.height * 1.6 + 16, w * 0.55)
            case .circle, .doubleCircle: w = max(w, h) + 4; h = w
            case .hexagon: w += 20
            case .parallelogram, .parallelogramAlt, .trapezoid, .trapezoidAlt, .asymmetric: w += 22
            case .cylinder: h += 10
            case .stadium, .round: w += 8
            default: break
            }
            sizes[id] = NSSize(width: max(w, 50), height: max(h, 34))
        }

        // Rank assignment: longest path on the graph with back edges reversed.
        let visibleEdges = edges.filter { nodes[$0.from] != nil && nodes[$0.to] != nil }
        var outgoing: [String: [String]] = [:]
        for e in visibleEdges where e.from != e.to { outgoing[e.from, default: []].append(e.to) }
        var state: [String: Int] = [:] // 1 = on stack, 2 = done
        var backEdges = Set<String>()
        func dfs(_ v: String) {
            state[v] = 1
            for w in outgoing[v] ?? [] {
                if state[w] == 1 { backEdges.insert(v + "\u{1}" + w) } else if state[w] == nil { dfs(w) }
            }
            state[v] = 2
        }
        for id in order where state[id] == nil { dfs(id) }
        var dag: [(String, String)] = []
        for e in visibleEdges where e.from != e.to {
            if backEdges.contains(e.from + "\u{1}" + e.to) { dag.append((e.to, e.from)) } else { dag.append((e.from, e.to)) }
        }
        var rank: [String: Int] = [:]
        var changed = true
        for id in order { rank[id] = 0 }
        var guardCount = 0
        while changed, guardCount < order.count + 2 {
            changed = false
            guardCount += 1
            for (a, b) in dag where rank[b]! < rank[a]! + 1 {
                rank[b] = rank[a]! + 1
                changed = true
            }
        }

        // Virtual nodes for edges spanning several ranks.
        struct Chain { var edgeIndex: Int; var points: [String] }
        var layerOf = rank
        var chains: [Chain] = []
        var virtualCount = 0
        for (k, e) in visibleEdges.enumerated() where e.from != e.to {
            let (a, b) = backEdges.contains(e.from + "\u{1}" + e.to) ? (e.to, e.from) : (e.from, e.to)
            var points = [a]
            let ra = rank[a]!, rb = rank[b]!
            if rb - ra > 1 {
                for r in (ra + 1)..<rb {
                    let v = "\u{2}v\(virtualCount)"
                    virtualCount += 1
                    layerOf[v] = r
                    points.append(v)
                }
            }
            points.append(b)
            chains.append(Chain(edgeIndex: k, points: points))
        }
        let maxRank = layerOf.values.max() ?? 0
        var layers = [[String]](repeating: [], count: maxRank + 1)
        for id in order { layers[layerOf[id]!].append(id) }
        for chain in chains { for v in chain.points where v.hasPrefix("\u{2}") { layers[layerOf[v]!].append(v) } }

        // Crossing reduction: barycenter sweeps.
        var neighborsUp: [String: [String]] = [:], neighborsDown: [String: [String]] = [:]
        for chain in chains {
            for k in 0..<(chain.points.count - 1) {
                neighborsDown[chain.points[k], default: []].append(chain.points[k + 1])
                neighborsUp[chain.points[k + 1], default: []].append(chain.points[k])
            }
        }
        func positions(_ layer: [String]) -> [String: Double] {
            var p: [String: Double] = [:]
            for (k, v) in layer.enumerated() { p[v] = Double(k) }
            return p
        }
        for _ in 0..<6 {
            for r in 1..<max(layers.count, 1) where r < layers.count {
                let above = positions(layers[r - 1])
                let current = layers[r]
                layers[r] = current.sorted { a, b in
                    bary(a, neighborsUp, above, fallback: current) < bary(b, neighborsUp, above, fallback: current)
                }
            }
            if layers.count >= 2 {
                for r in stride(from: layers.count - 2, through: 0, by: -1) {
                    let below = positions(layers[r + 1])
                    let current = layers[r]
                    layers[r] = current.sorted { a, b in
                        bary(a, neighborsDown, below, fallback: current) < bary(b, neighborsDown, below, fallback: current)
                    }
                }
            }
        }

        // Coordinates (computed top-down, then rotated for LR/RL).
        let rankGap: CGFloat = horizontal ? 60 : 50
        let nodeGap: CGFloat = horizontal ? 24 : 32
        func along(_ s: NSSize) -> CGFloat { horizontal ? s.height : s.width }
        func across(_ s: NSSize) -> CGFloat { horizontal ? s.width : s.height }
        let virtualSize = NSSize(width: 10, height: 10)
        func size(of v: String) -> NSSize { sizes[v] ?? virtualSize }
        var layerExtent: [CGFloat] = layers.map { layer in layer.map { along(size(of: $0)) }.reduce(0, +) + nodeGap * CGFloat(max(layer.count - 1, 0)) }
        if layerExtent.isEmpty { layerExtent = [0] }
        let maxExtent = layerExtent.max() ?? 0
        var center: [String: CGPoint] = [:]
        var rankPosition: CGFloat = 0
        for (r, layer) in layers.enumerated() {
            let thickness = layer.map { across(size(of: $0)) }.max() ?? 0
            var cursor = (maxExtent - layerExtent[r]) / 2
            for v in layer {
                let s = size(of: v)
                let mid = cursor + along(s) / 2
                center[v] = horizontal ? CGPoint(x: rankPosition + thickness / 2, y: mid)
                                       : CGPoint(x: mid, y: rankPosition + thickness / 2)
                cursor += along(s) + nodeGap
            }
            rankPosition += thickness + rankGap
        }
        // Straighten: pull single-neighbor nodes toward their neighbor's position when there is room.
        let totalAcross = rankPosition - rankGap
        if reversed {
            for (k, p) in center {
                center[k] = horizontal ? CGPoint(x: totalAcross - p.x, y: p.y) : CGPoint(x: p.x, y: totalAcross - p.y)
            }
        }

        // Subgraph frames.
        let margin: CGFloat = 12
        var groupRects: [(String, NSRect)] = []
        for group in groups {
            var rect = NSRect.null
            for id in group.members {
                guard let c = center[id], let s = sizes[id] else { continue }
                rect = rect.union(NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
            }
            guard !rect.isNull else { continue }
            let titleHeight = MermaidRenderer.textSize(group.title, font: font).height
            rect = rect.insetBy(dx: -margin, dy: -margin)
            rect.origin.y -= titleHeight + 4
            rect.size.height += titleHeight + 4
            groupRects.append((group.title, rect))
        }

        // Bounds and translation.
        var bounds = NSRect.null
        for (v, c) in center {
            let s = size(of: v)
            bounds = bounds.union(NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
        }
        for (_, r) in groupRects { bounds = bounds.union(r) }
        // Edge labels may extend beyond nodes.
        let pad: CGFloat = 8
        let dx = pad - bounds.minX, dy = pad - bounds.minY
        let finalCenter = center.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        let finalGroups = groupRects.map { ($0.0, $0.1.offsetBy(dx: dx, dy: dy)) }
        var canvas = NSSize(width: ceil(bounds.width + pad * 2), height: ceil(bounds.height + pad * 2))

        // Precompute edge label sizes to grow the canvas if needed.
        var labelRects: [Int: NSRect] = [:]
        for chain in chains {
            let e = visibleEdges[chain.edgeIndex]
            guard let label = e.label, !label.isEmpty else { continue }
            let pts = chain.points.compactMap { finalCenter[$0] }
            guard pts.count >= 2 else { continue }
            let mid: CGPoint
            if pts.count % 2 == 1 { mid = pts[pts.count / 2] } else {
                let a = pts[pts.count / 2 - 1], b = pts[pts.count / 2]
                mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            let s = MermaidRenderer.textSize(label, font: font)
            let rect = NSRect(x: mid.x - s.width / 2 - 4, y: mid.y - s.height / 2 - 2, width: s.width + 8, height: s.height + 4)
            labelRects[chain.edgeIndex] = rect
            canvas.width = max(canvas.width, rect.maxX + pad)
            canvas.height = max(canvas.height, rect.maxY + pad)
        }

        let nodesCopy = nodes
        let orderCopy = order
        let selfLoops = visibleEdges.filter { $0.from == $0.to }
        return MermaidDiagram(size: canvas) {
            for (title, rect) in finalGroups {
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                MermaidRenderer.Colors.groupFill.setFill()
                path.fill()
                MermaidRenderer.Colors.groupStroke.setStroke()
                path.lineWidth = 1
                path.stroke()
                let s = MermaidRenderer.textSize(title, font: font)
                MermaidRenderer.drawText(title, centeredIn: NSRect(x: rect.midX - s.width / 2, y: rect.minY + 4,
                                                                   width: s.width, height: s.height), font: font)
            }
            for chain in chains {
                let e = visibleEdges[chain.edgeIndex]
                guard !e.invisible else { continue }
                var pts = chain.points.compactMap { finalCenter[$0] }
                guard pts.count >= 2 else { continue }
                let isReversed = chain.points.first != e.from
                if isReversed { pts.reverse() }
                // Clip the ends to the node outlines.
                if let fromNode = nodesCopy[e.from], let s = sizes[e.from] {
                    pts[0] = Flowchart.clip(center: pts[0], size: s, shape: fromNode.shape, toward: pts[1])
                }
                if let toNode = nodesCopy[e.to], let s = sizes[e.to] {
                    pts[pts.count - 1] = Flowchart.clip(center: pts[pts.count - 1], size: s, shape: toNode.shape,
                                                        toward: pts[pts.count - 2])
                }
                Flowchart.drawEdge(pts, e)
            }
            for e in selfLoops {
                guard let c = finalCenter[e.from], let s = sizes[e.from] else { continue }
                let path = NSBezierPath()
                let start = CGPoint(x: c.x + s.width / 2, y: c.y - s.height / 4)
                let end = CGPoint(x: c.x + s.width / 2, y: c.y + s.height / 4)
                path.move(to: start)
                path.curve(to: end, controlPoint1: CGPoint(x: start.x + 40, y: start.y - 20),
                           controlPoint2: CGPoint(x: end.x + 40, y: end.y + 20))
                MermaidRenderer.Colors.edge.setStroke()
                path.lineWidth = 1.2
                path.stroke()
                Flowchart.arrowHead(at: end, from: CGPoint(x: end.x + 20, y: end.y + 10), marker: ">")
            }
            for (k, rect) in labelRects {
                guard let label = visibleEdges[k].label else { continue }
                MermaidRenderer.Colors.labelBackground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                MermaidRenderer.drawText(label, centeredIn: rect, font: font)
            }
            for id in orderCopy {
                guard let node = nodesCopy[id], let c = finalCenter[id], let s = sizes[id] else { continue }
                let rect = NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
                Flowchart.drawNode(node, in: rect)
                MermaidRenderer.drawText(node.label, centeredIn: rect, font: font,
                                         color: node.textColor ?? MermaidRenderer.Colors.text)
            }
        }
    }

    private func bary(_ v: String, _ neighbors: [String: [String]], _ positions: [String: Double], fallback: [String]) -> Double {
        let ns = (neighbors[v] ?? []).compactMap { positions[$0] }
        if ns.isEmpty { return Double(fallback.firstIndex(of: v) ?? 0) }
        return ns.reduce(0, +) / Double(ns.count)
    }

    // MARK: Drawing helpers

    static func clip(center c: CGPoint, size s: NSSize, shape: Shape, toward p: CGPoint) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let hw = s.width / 2, hh = s.height / 2
        switch shape {
        case .circle, .doubleCircle:
            let len = sqrt(dx * dx + dy * dy)
            return CGPoint(x: c.x + dx / len * hw, y: c.y + dy / len * hh)
        case .diamond:
            let t = 1 / (abs(dx) / hw + abs(dy) / hh)
            return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
        default:
            let tx = dx != 0 ? hw / abs(dx) : .infinity
            let ty = dy != 0 ? hh / abs(dy) : .infinity
            let t = min(tx, ty)
            return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
        }
    }

    static func drawEdge(_ pts: [CGPoint], _ e: Edge) {
        let path = NSBezierPath()
        path.move(to: pts[0])
        if pts.count == 2 {
            path.line(to: pts[1])
        } else {
            // Smooth polyline through virtual nodes.
            for k in 1..<pts.count {
                let prev = pts[k - 1], cur = pts[k]
                if k == pts.count - 1 {
                    path.line(to: cur)
                } else {
                    let next = pts[k + 1]
                    let a = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
                    let b = CGPoint(x: (cur.x + next.x) / 2, y: (cur.y + next.y) / 2)
                    path.line(to: a)
                    path.curve(to: b, controlPoint1: cur, controlPoint2: cur)
                }
            }
        }
        path.lineWidth = e.thick ? 2.6 : 1.3
        if e.dotted { path.setLineDash([3, 3], count: 2, phase: 0) }
        MermaidRenderer.Colors.edge.setStroke()
        path.stroke()
        if e.arrowEnd { arrowHead(at: pts[pts.count - 1], from: pts[pts.count - 2], marker: e.endMarker) }
        if e.arrowStart { arrowHead(at: pts[0], from: pts[1], marker: e.startMarker == " " ? ">" : e.startMarker) }
    }

    static func arrowHead(at tip: CGPoint, from: CGPoint, marker: Character) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        MermaidRenderer.Colors.edge.setFill()
        MermaidRenderer.Colors.edge.setStroke()
        switch marker {
        case "o":
            let r: CGFloat = 4
            let c = CGPoint(x: tip.x - cos(angle) * r, y: tip.y - sin(angle) * r)
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            NSColor.textBackgroundColor.setFill()
            circle.fill()
            circle.lineWidth = 1.3
            circle.stroke()
        case "x":
            let r: CGFloat = 4.5
            let c = CGPoint(x: tip.x - cos(angle) * r, y: tip.y - sin(angle) * r)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x - r, y: c.y - r)); path.line(to: CGPoint(x: c.x + r, y: c.y + r))
            path.move(to: CGPoint(x: c.x - r, y: c.y + r)); path.line(to: CGPoint(x: c.x + r, y: c.y - r))
            path.lineWidth = 1.6
            path.stroke()
        default:
            let len: CGFloat = 9, spread: CGFloat = 0.42
            let path = NSBezierPath()
            path.move(to: tip)
            path.line(to: CGPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread)))
            path.line(to: CGPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread)))
            path.close()
            path.fill()
        }
    }

    static func drawNode(_ node: Node, in r: NSRect) {
        let path: NSBezierPath
        switch node.shape {
        case .rect, .subroutine:
            path = NSBezierPath(rect: r)
        case .round:
            path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        case .stadium:
            path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        case .circle, .doubleCircle:
            path = NSBezierPath(ovalIn: r)
        case .diamond:
            path = NSBezierPath()
            path.move(to: CGPoint(x: r.midX, y: r.minY)); path.line(to: CGPoint(x: r.maxX, y: r.midY))
            path.line(to: CGPoint(x: r.midX, y: r.maxY)); path.line(to: CGPoint(x: r.minX, y: r.midY)); path.close()
        case .hexagon:
            let inset = min(14, r.width / 4)
            path = NSBezierPath()
            path.move(to: CGPoint(x: r.minX + inset, y: r.minY)); path.line(to: CGPoint(x: r.maxX - inset, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.midY)); path.line(to: CGPoint(x: r.maxX - inset, y: r.maxY))
            path.line(to: CGPoint(x: r.minX + inset, y: r.maxY)); path.line(to: CGPoint(x: r.minX, y: r.midY)); path.close()
        case .parallelogram, .parallelogramAlt, .trapezoid, .trapezoidAlt:
            let k: CGFloat = 12
            var tl = CGPoint(x: r.minX, y: r.minY), tr = CGPoint(x: r.maxX, y: r.minY)
            var br = CGPoint(x: r.maxX, y: r.maxY), bl = CGPoint(x: r.minX, y: r.maxY)
            switch node.shape {
            case .parallelogram: tl.x += k; br.x -= k
            case .parallelogramAlt: tr.x -= k; bl.x += k
            case .trapezoid: tl.x += k; tr.x -= k
            default: bl.x += k; br.x -= k
            }
            path = NSBezierPath()
            path.move(to: tl); path.line(to: tr); path.line(to: br); path.line(to: bl); path.close()
        case .asymmetric:
            path = NSBezierPath()
            path.move(to: CGPoint(x: r.minX, y: r.minY)); path.line(to: CGPoint(x: r.maxX, y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.maxY)); path.line(to: CGPoint(x: r.minX, y: r.maxY))
            path.line(to: CGPoint(x: r.minX + 12, y: r.midY)); path.close()
        case .cylinder:
            let e: CGFloat = 8
            (node.fill ?? MermaidRenderer.Colors.nodeFill).setFill()
            NSBezierPath(rect: NSRect(x: r.minX, y: r.minY + e / 2, width: r.width, height: r.height - e)).fill()
            NSBezierPath(ovalIn: NSRect(x: r.minX, y: r.maxY - e, width: r.width, height: e)).fill()
            let top = NSBezierPath(ovalIn: NSRect(x: r.minX, y: r.minY, width: r.width, height: e))
            (node.fill ?? MermaidRenderer.Colors.nodeFill).setFill()
            top.fill()
            (node.stroke ?? MermaidRenderer.Colors.nodeStroke).setStroke()
            top.lineWidth = 1.2
            top.stroke()
            let sides = NSBezierPath()
            sides.move(to: CGPoint(x: r.minX, y: r.minY + e / 2)); sides.line(to: CGPoint(x: r.minX, y: r.maxY - e / 2))
            sides.move(to: CGPoint(x: r.maxX, y: r.minY + e / 2)); sides.line(to: CGPoint(x: r.maxX, y: r.maxY - e / 2))
            let bottom = NSBezierPath(ovalIn: NSRect(x: r.minX, y: r.maxY - e, width: r.width, height: e))
            sides.lineWidth = 1.2
            sides.stroke()
            bottom.lineWidth = 1.2
            bottom.stroke()
            return
        }
        (node.fill ?? MermaidRenderer.Colors.nodeFill).setFill()
        path.fill()
        (node.stroke ?? MermaidRenderer.Colors.nodeStroke).setStroke()
        path.lineWidth = 1.2
        path.stroke()
        if node.shape == .subroutine {
            let inner = NSBezierPath()
            inner.move(to: CGPoint(x: r.minX + 7, y: r.minY)); inner.line(to: CGPoint(x: r.minX + 7, y: r.maxY))
            inner.move(to: CGPoint(x: r.maxX - 7, y: r.minY)); inner.line(to: CGPoint(x: r.maxX - 7, y: r.maxY))
            inner.lineWidth = 1.2
            inner.stroke()
        }
        if node.shape == .doubleCircle {
            let inner = NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4))
            inner.lineWidth = 1.2
            inner.stroke()
        }
    }
}

// MARK: - Sequence diagram

struct SequenceDiagram {
    struct Participant {
        var id: String
        var label: String
        var isActor: Bool
    }

    enum Item {
        case message(from: String, to: String, text: String, dashed: Bool, arrow: Character, number: Int?)
        case note(over: [String], position: String, text: String)
        case frameStart(kind: String, label: String)
        case frameElse(label: String)
        case frameEnd
    }

    var participants: [Participant] = []
    var items: [Item] = []

    static func parse(_ lines: [String]) -> SequenceDiagram {
        var diagram = SequenceDiagram()
        var autonumber = false
        var counter = 1
        func ensure(_ id: String) {
            if !diagram.participants.contains(where: { $0.id == id }) {
                diagram.participants.append(Participant(id: id, label: id, isActor: false))
            }
        }
        let message = try! NSRegularExpression(pattern: "^([^\\-<>:+]+?)\\s*(-->>|->>|-->|->|--x|-x|--\\)|-\\))\\s*([+-]?)\\s*([^:]+?)\\s*:\\s*(.*)$")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let isActor = lower.hasPrefix("actor ")
                let rest = String(line.dropFirst(isActor ? 6 : 12)).trimmingCharacters(in: .whitespaces)
                var id = rest, label = rest
                if let range = rest.range(of: " as ") {
                    id = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    label = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                if let k = diagram.participants.firstIndex(where: { $0.id == id }) {
                    diagram.participants[k].label = MermaidRenderer.cleanLabel(label)
                } else {
                    diagram.participants.append(Participant(id: id, label: MermaidRenderer.cleanLabel(label), isActor: isActor))
                }
                continue
            }
            if lower == "autonumber" { autonumber = true; continue }
            if lower.hasPrefix("note ") {
                let rest = String(line.dropFirst(5))
                guard let colon = rest.firstIndex(of: ":") else { continue }
                let spec = rest[..<colon].trimmingCharacters(in: .whitespaces)
                let text = MermaidRenderer.cleanLabel(String(rest[rest.index(after: colon)...]))
                let words = spec.split(separator: " ", maxSplits: 2).map(String.init)
                var position = "over"
                var targets = ""
                if words.first?.lowercased() == "over" {
                    targets = words.dropFirst().joined(separator: " ")
                } else if words.count >= 3 {
                    position = words[0].lowercased()
                    targets = words[2]
                }
                let ids = targets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                ids.forEach(ensure)
                diagram.items.append(.note(over: ids, position: position, text: text))
                continue
            }
            for kind in ["loop", "alt", "opt", "par", "critical", "break", "rect"] where lower == kind || lower.hasPrefix(kind + " ") {
                diagram.items.append(.frameStart(kind: kind, label: MermaidRenderer.cleanLabel(String(line.dropFirst(kind.count)))))
            }
            if lower == "else" || lower.hasPrefix("else ") || lower.hasPrefix("and ") || lower == "and" {
                diagram.items.append(.frameElse(label: MermaidRenderer.cleanLabel(String(line.drop(while: { $0 != " " })))))
                continue
            }
            if lower == "end" { diagram.items.append(.frameEnd); continue }
            let ns = line as NSString
            if let m = message.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let from = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let arrow = ns.substring(with: m.range(at: 2))
                let to = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
                let text = MermaidRenderer.cleanLabel(ns.substring(with: m.range(at: 5)))
                ensure(from)
                ensure(to)
                let head: Character = arrow.hasSuffix(">>") ? ">" : arrow.hasSuffix("x") ? "x" : arrow.hasSuffix(")") ? ")" : "-"
                diagram.items.append(.message(from: from, to: to, text: text, dashed: arrow.hasPrefix("--"),
                                              arrow: head, number: autonumber ? counter : nil))
                if autonumber { counter += 1 }
            }
        }
        return diagram
    }

    func layout(font: NSFont) -> MermaidDiagram? {
        guard !participants.isEmpty else { return nil }
        let index = Dictionary(uniqueKeysWithValues: participants.enumerated().map { ($1.id, $0) })
        let boxSizes = participants.map { p -> NSSize in
            let s = MermaidRenderer.textSize(p.label, font: font)
            return NSSize(width: max(s.width + 24, 80), height: s.height + 18)
        }
        // Column gaps wide enough for the messages between neighbours.
        var gaps = [CGFloat](repeating: 60, count: max(participants.count - 1, 0))
        for item in items {
            switch item {
            case .message(let from, let to, let text, _, _, let number):
                guard let a = index[from], let b = index[to], a != b else { continue }
                let label = (number.map { "\($0). " } ?? "") + text
                let need = MermaidRenderer.textSize(label, font: font).width + 30
                let lo = min(a, b), hi = max(a, b)
                let span = CGFloat(hi - lo)
                for k in lo..<hi { gaps[k] = max(gaps[k], need / span) }
            case .note(let over, _, let text):
                let need = MermaidRenderer.textSize(text, font: font).width + 30
                if over.count >= 2, let a = index[over[0]], let b = index[over[1]], a != b {
                    for k in min(a, b)..<max(a, b) { gaps[k] = max(gaps[k], need / CGFloat(abs(b - a))) }
                }
            default: break
            }
        }
        var xs: [CGFloat] = []
        var x: CGFloat = 10 + boxSizes[0].width / 2
        for k in 0..<participants.count {
            xs.append(x)
            if k < gaps.count { x += boxSizes[k].width / 2 + gaps[k] + boxSizes[k + 1].width / 2 - 40 + 40 }
        }
        let headerHeight = (boxSizes.map(\.height).max() ?? 30)
        var y = headerHeight + 24
        struct Row { var item: Item; var y: CGFloat; var height: CGFloat }
        var rows: [Row] = []
        var frames: [(kind: String, label: String, top: CGFloat, elses: [(CGFloat, String)])] = []
        var finished: [(kind: String, label: String, top: CGFloat, bottom: CGFloat, elses: [(CGFloat, String)])] = []
        for item in items {
            switch item {
            case .message(let from, let to, let text, _, _, _):
                let h = MermaidRenderer.textSize(text, font: font).height
                let selfMessage = from == to
                rows.append(Row(item: item, y: y + h, height: h))
                y += h + (selfMessage ? 44 : 30)
            case .note(_, _, let text):
                let h = MermaidRenderer.textSize(text, font: font).height + 14
                rows.append(Row(item: item, y: y, height: h))
                y += h + 14
            case .frameStart(let kind, let label):
                frames.append((kind, label, y, []))
                y += MermaidRenderer.textSize("X", font: font).height + 14
            case .frameElse(let label):
                if !frames.isEmpty { frames[frames.count - 1].elses.append((y, label)) }
                y += MermaidRenderer.textSize("X", font: font).height + 10
            case .frameEnd:
                if let f = frames.popLast() { finished.append((f.kind, f.label, f.top, y, f.elses)) }
                y += 10
            }
        }
        let lifelineBottom = y + 6
        let width = (xs.last ?? 0) + (boxSizes.last?.width ?? 0) / 2 + 10
        let height = lifelineBottom + headerHeight + 10
        let participantsCopy = participants
        let frameLeft: CGFloat = 4
        let frameRight = width - 4
        return MermaidDiagram(size: NSSize(width: ceil(max(width, 120)), height: ceil(height))) {
            // Frames behind everything.
            for f in finished {
                let rect = NSRect(x: frameLeft, y: f.top - 4, width: frameRight - frameLeft, height: f.bottom - f.top)
                if f.kind == "rect" {
                    MermaidRenderer.Colors.groupFill.withAlphaComponent(0.5).setFill()
                    NSBezierPath(rect: rect).fill()
                    continue
                }
                let path = NSBezierPath(rect: rect)
                MermaidRenderer.Colors.groupStroke.setStroke()
                path.lineWidth = 1
                path.stroke()
                let tag = f.kind
                let ts = MermaidRenderer.textSize(tag, font: font)
                let tagRect = NSRect(x: rect.minX, y: rect.minY, width: ts.width + 14, height: ts.height + 6)
                MermaidRenderer.Colors.groupFill.setFill()
                NSBezierPath(rect: tagRect).fill()
                MermaidRenderer.drawText(tag, centeredIn: tagRect, font: font)
                if !f.label.isEmpty {
                    let ls = MermaidRenderer.textSize("[\(f.label)]", font: font)
                    MermaidRenderer.drawText("[\(f.label)]", centeredIn: NSRect(x: tagRect.maxX + 6, y: tagRect.minY + 3,
                                                                              width: ls.width, height: ls.height), font: font)
                }
                for (ey, label) in f.elses {
                    let dash = NSBezierPath()
                    dash.move(to: CGPoint(x: rect.minX, y: ey - 4)); dash.line(to: CGPoint(x: rect.maxX, y: ey - 4))
                    dash.setLineDash([4, 3], count: 2, phase: 0)
                    dash.lineWidth = 1
                    dash.stroke()
                    if !label.isEmpty {
                        let ls = MermaidRenderer.textSize("[\(label)]", font: font)
                        MermaidRenderer.drawText("[\(label)]", centeredIn: NSRect(x: rect.midX - ls.width / 2, y: ey,
                                                                                width: ls.width, height: ls.height), font: font)
                    }
                }
            }
            // Lifelines and participant boxes.
            for (k, p) in participantsCopy.enumerated() {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: xs[k], y: headerHeight))
                line.line(to: CGPoint(x: xs[k], y: lifelineBottom))
                line.setLineDash([4, 3], count: 2, phase: 0)
                MermaidRenderer.Colors.nodeStroke.setStroke()
                line.lineWidth = 1
                line.stroke()
                for top in [CGFloat(0), lifelineBottom] {
                    let s = boxSizes[k]
                    let rect = NSRect(x: xs[k] - s.width / 2, y: top, width: s.width, height: headerHeight)
                    if p.isActor {
                        SequenceDiagram.drawActor(in: rect)
                        let ts = MermaidRenderer.textSize(p.label, font: font)
                        MermaidRenderer.drawText(p.label, centeredIn: NSRect(x: rect.midX - ts.width / 2, y: rect.maxY - ts.height,
                                                                             width: ts.width, height: ts.height), font: font)
                    } else {
                        let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                        MermaidRenderer.Colors.nodeFill.setFill()
                        box.fill()
                        MermaidRenderer.Colors.nodeStroke.setStroke()
                        box.lineWidth = 1.2
                        box.stroke()
                        MermaidRenderer.drawText(p.label, centeredIn: rect, font: font)
                    }
                }
            }
            // Messages and notes.
            for row in rows {
                switch row.item {
                case .message(let from, let to, let text, let dashed, let arrow, let number):
                    guard let a = index[from], let b = index[to] else { continue }
                    let label = (number.map { "\($0). " } ?? "") + text
                    let path = NSBezierPath()
                    let y0 = row.y + 6
                    MermaidRenderer.Colors.edge.setStroke()
                    if a == b {
                        let x0 = xs[a]
                        path.move(to: CGPoint(x: x0, y: y0))
                        path.line(to: CGPoint(x: x0 + 40, y: y0))
                        path.line(to: CGPoint(x: x0 + 40, y: y0 + 18))
                        path.line(to: CGPoint(x: x0 + 2, y: y0 + 18))
                        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
                        path.lineWidth = 1.2
                        path.stroke()
                        SequenceDiagram.head(at: CGPoint(x: x0 + 1, y: y0 + 18), from: CGPoint(x: x0 + 20, y: y0 + 18), arrow)
                        let ts = MermaidRenderer.textSize(label, font: font)
                        MermaidRenderer.drawText(label, centeredIn: NSRect(x: x0 + 46, y: y0 - ts.height / 2, width: ts.width,
                                                                           height: ts.height), font: font)
                    } else {
                        let x0 = xs[a], x1 = xs[b]
                        path.move(to: CGPoint(x: x0, y: y0))
                        path.line(to: CGPoint(x: x1 + (x1 > x0 ? -1 : 1), y: y0))
                        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
                        path.lineWidth = 1.2
                        path.stroke()
                        SequenceDiagram.head(at: CGPoint(x: x1, y: y0), from: CGPoint(x: x0, y: y0), arrow)
                        let ts = MermaidRenderer.textSize(label, font: font)
                        MermaidRenderer.drawText(label, centeredIn: NSRect(x: (x0 + x1) / 2 - ts.width / 2, y: y0 - ts.height - 3,
                                                                           width: ts.width, height: ts.height), font: font)
                    }
                case .note(let over, let position, let text):
                    let ids = over.compactMap { index[$0] }
                    guard let first = ids.first else { continue }
                    let ts = MermaidRenderer.textSize(text, font: font)
                    var rect: NSRect
                    let w = ts.width + 20
                    if position == "left" {
                        rect = NSRect(x: xs[first] - w - 10, y: row.y, width: w, height: row.height)
                    } else if position == "right" {
                        rect = NSRect(x: xs[first] + 10, y: row.y, width: w, height: row.height)
                    } else {
                        let lo = xs[ids.min()!], hi = xs[ids.max()!]
                        let width = max(hi - lo + 40, w)
                        rect = NSRect(x: (lo + hi) / 2 - width / 2, y: row.y, width: width, height: row.height)
                    }
                    rect.origin.x = max(rect.origin.x, 2)
                    let path = NSBezierPath(rect: rect)
                    MermaidRenderer.Colors.noteFill.setFill()
                    path.fill()
                    MermaidRenderer.Colors.groupStroke.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    MermaidRenderer.drawText(text, centeredIn: rect, font: font)
                default:
                    break
                }
            }
        }
    }

    static func head(at tip: CGPoint, from: CGPoint, _ kind: Character) {
        switch kind {
        case ">": Flowchart.arrowHead(at: tip, from: from, marker: ">")
        case "x": Flowchart.arrowHead(at: tip, from: from, marker: "x")
        case ")":
            let path = NSBezierPath()
            let dir: CGFloat = tip.x > from.x ? 1 : -1
            path.move(to: CGPoint(x: tip.x - 8 * dir, y: tip.y - 6))
            path.line(to: tip)
            path.line(to: CGPoint(x: tip.x - 8 * dir, y: tip.y + 6))
            path.lineWidth = 1.2
            path.stroke()
        default:
            let path = NSBezierPath()
            let dir: CGFloat = tip.x > from.x ? 1 : -1
            path.move(to: CGPoint(x: tip.x - 8 * dir, y: tip.y - 4))
            path.line(to: tip)
            path.line(to: CGPoint(x: tip.x - 8 * dir, y: tip.y + 4))
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    static func drawActor(in rect: NSRect) {
        let cx = rect.midX
        let top = rect.minY + 2
        MermaidRenderer.Colors.nodeStroke.setStroke()
        let head = NSBezierPath(ovalIn: NSRect(x: cx - 5, y: top, width: 10, height: 10))
        head.lineWidth = 1.2
        head.stroke()
        let body = NSBezierPath()
        body.move(to: CGPoint(x: cx, y: top + 10)); body.line(to: CGPoint(x: cx, y: top + 20))
        body.move(to: CGPoint(x: cx - 8, y: top + 14)); body.line(to: CGPoint(x: cx + 8, y: top + 14))
        body.move(to: CGPoint(x: cx, y: top + 20)); body.line(to: CGPoint(x: cx - 6, y: top + 28))
        body.move(to: CGPoint(x: cx, y: top + 20)); body.line(to: CGPoint(x: cx + 6, y: top + 28))
        body.lineWidth = 1.2
        body.stroke()
    }
}

// MARK: - Pie chart

struct PieChart {
    var title: String?
    var showData = false
    var slices: [(String, Double)] = []

    static func parse(_ lines: [String]) -> PieChart {
        var chart = PieChart()
        for (k, line) in lines.enumerated() {
            var text = line
            if k == 0 {
                let lower = line.lowercased()
                chart.showData = lower.contains("showdata")
                if let range = lower.range(of: "title ") {
                    chart.title = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if text.lowercased().hasPrefix("title ") {
                chart.title = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = text.lastIndex(of: ":"), let value = Double(text[text.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)) else { continue }
            text = String(text[..<colon])
            chart.slices.append((MermaidRenderer.cleanLabel(text), value))
        }
        return chart
    }

    func layout(font: NSFont) -> MermaidDiagram? {
        let total = slices.map(\.1).reduce(0, +)
        guard total > 0 else { return nil }
        let radius: CGFloat = 110
        let titleSize = title.map { MermaidRenderer.textSize($0, font: NSFont.boldSystemFont(ofSize: font.pointSize * 1.15)) }
            ?? .zero
        let legend = slices.map { label, value -> String in
            showData ? "\(label) [\(Self.format(value))]" : label
        }
        let legendWidth = (legend.map { MermaidRenderer.textSize($0, font: font).width }.max() ?? 0) + 28
        let rowHeight = MermaidRenderer.textSize("X", font: font).height + 6
        let top = titleSize.height > 0 ? titleSize.height + 14 : 6
        let height = max(radius * 2, rowHeight * CGFloat(slices.count)) + top + 10
        let width = radius * 2 + 40 + legendWidth + 10
        let slicesCopy = slices
        let titleCopy = title
        return MermaidDiagram(size: NSSize(width: ceil(max(width, titleSize.width + 20)), height: ceil(height))) {
            if let titleCopy {
                MermaidRenderer.drawText(titleCopy, centeredIn: NSRect(x: 0, y: 4, width: max(width, titleSize.width + 20),
                                                                       height: titleSize.height),
                                         font: NSFont.boldSystemFont(ofSize: font.pointSize * 1.15))
            }
            let center = CGPoint(x: 10 + radius, y: top + radius)
            var angle: CGFloat = -90
            for (k, slice) in slicesCopy.enumerated() {
                let sweep = CGFloat(slice.1 / total) * 360
                let path = NSBezierPath()
                path.move(to: center)
                // Flipped coordinates: clockwise in the drawing.
                path.appendArc(withCenter: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
                path.close()
                MermaidRenderer.Colors.pie[k % MermaidRenderer.Colors.pie.count].setFill()
                path.fill()
                NSColor.textBackgroundColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
                if sweep > 14 {
                    let mid = (angle + sweep / 2) * .pi / 180
                    let percent = "\(Int((slice.1 / total * 100).rounded()))%"
                    let ts = MermaidRenderer.textSize(percent, font: font)
                    let p = CGPoint(x: center.x + cos(mid) * radius * 0.65, y: center.y + sin(mid) * radius * 0.65)
                    MermaidRenderer.drawText(percent, centeredIn: NSRect(x: p.x - ts.width / 2, y: p.y - ts.height / 2,
                                                                         width: ts.width, height: ts.height),
                                             font: font, color: .white)
                }
                angle += sweep
            }
            let legendX = 10 + radius * 2 + 30
            var y = top + max(0, (radius * 2 - rowHeight * CGFloat(slicesCopy.count)) / 2)
            for (k, text) in legend.enumerated() {
                MermaidRenderer.Colors.pie[k % MermaidRenderer.Colors.pie.count].setFill()
                NSBezierPath(rect: NSRect(x: legendX, y: y + 3, width: 14, height: 14)).fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: MermaidRenderer.Colors.text]
                (text as NSString).draw(at: NSPoint(x: legendX + 20, y: y + 1), withAttributes: attrs)
                y += rowHeight
            }
        }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}

// MARK: - Attachment

/// Draws a laid-out Mermaid diagram, scaled down to fit narrow windows.
final class MermaidAttachmentCell: NSTextAttachmentCell {
    let diagram: MermaidDiagram
    private var scale: CGFloat = 1

    init(diagram: MermaidDiagram) {
        self.diagram = diagram
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func cellSize() -> NSSize { diagram.size }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(lineFrag.width - position.x - 4, 60)
        scale = diagram.size.width > available ? max(available / diagram.size.width, 0.3) : 1
        return NSRect(x: 0, y: 0, width: diagram.size.width * scale, height: diagram.size.height * scale)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let current = NSGraphicsContext.current else { return }
        let cg = current.cgContext
        cg.saveGState()
        if current.isFlipped {
            cg.translateBy(x: cellFrame.minX, y: cellFrame.minY)
            cg.scaleBy(x: scale, y: scale)
            diagram.draw()
        } else {
            cg.translateBy(x: cellFrame.minX, y: cellFrame.maxY)
            cg.scaleBy(x: scale, y: -scale)
            let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = flipped
            diagram.draw()
            NSGraphicsContext.restoreGraphicsState()
        }
        cg.restoreGState()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}
