import Foundation

/// Turns `<details>` HTML into `Block.details`, so the reader can collapse
/// it. GitHub-style documents usually split a details element into several
/// blocks, with Markdown between the opening and the closing HTML:
///
///     <details>
///     <summary>More</summary>
///
///     Markdown content
///
///     </details>
///
/// The opening HTML block, the blocks up to the matching `</details>` and the
/// closing HTML block become one `.details` block (top-level line ranges and
/// hashes are merged accordingly).
enum DetailsGrouping {
    static func group(_ blocks: inout [Block]) {
        var ranges: [Range<Int>] = []
        var hashes: [Int] = []
        group(&blocks, ranges: &ranges, hashes: &hashes)
    }

    /// Groups in place. `ranges` and `hashes` are merged in parallel when
    /// they have one entry per block (top level); otherwise they are ignored.
    static func group(_ blocks: inout [Block], ranges: inout [Range<Int>], hashes: inout [Int]) {
        guard blocks.contains(where: { if case .html(let h) = $0 { return opensDetails(h) }; return false }) else { return }
        let tracksSource = ranges.count == blocks.count && hashes.count == blocks.count
        var outBlocks: [Block] = []
        var outRanges: [Range<Int>] = []
        var outHashes: [Int] = []
        var i = 0
        while i < blocks.count {
            guard case .html(let html) = blocks[i], opensDetails(html) else {
                outBlocks.append(blocks[i])
                if tracksSource { outRanges.append(ranges[i]); outHashes.append(hashes[i]) }
                i += 1
                continue
            }
            let balance = count(html)
            if balance.opens <= balance.closes {
                // The whole element is inside one HTML block.
                outBlocks.append(singleBlockDetails(html) ?? blocks[i])
                if tracksSource { outRanges.append(ranges[i]); outHashes.append(hashes[i]) }
                i += 1
                continue
            }
            // Find the HTML block that closes it.
            var depth = balance.opens - balance.closes
            var j = i + 1
            while j < blocks.count {
                if case .html(let h) = blocks[j] {
                    let c = count(h)
                    depth += c.opens - c.closes
                    if depth <= 0 { break }
                }
                j += 1
            }
            guard j < blocks.count, case .html(let closing) = blocks[j] else {
                outBlocks.append(blocks[i])
                if tracksSource { outRanges.append(ranges[i]); outHashes.append(hashes[i]) }
                i += 1
                continue
            }
            let head = splitOpening(html)
            var children: [Block] = []
            if let rest = head.rest { children.append(.html(rest)) }
            children.append(contentsOf: blocks[(i + 1)..<j])
            if let beforeClose = textBeforeLastClose(closing) { children.append(.html(beforeClose)) }
            group(&children)
            outBlocks.append(.details(summary: head.summary, open: head.open, children: children))
            if tracksSource {
                outRanges.append(ranges[i].lowerBound..<ranges[j].upperBound)
                var hasher = Hasher()
                for k in i...j { hasher.combine(hashes[k]) }
                outHashes.append(hasher.finalize())
            }
            i = j + 1
        }
        blocks = outBlocks
        if tracksSource {
            ranges = outRanges
            hashes = outHashes
        }
    }

    private static func opensDetails(_ html: String) -> Bool {
        let trimmed = html.drop(while: { $0.isWhitespace })
        guard trimmed.count >= 8 else { return false }
        let head = trimmed.prefix(9).lowercased()
        return head.hasPrefix("<details") && (head.count == 8 || [">", " ", "\t", "\n"].contains(head.last!))
    }

    private static func count(_ html: String) -> (opens: Int, closes: Int) {
        let lower = html.lowercased()
        var opens = 0
        var search = lower.startIndex
        while let r = lower.range(of: "<details", range: search..<lower.endIndex) {
            let next = r.upperBound < lower.endIndex ? lower[r.upperBound] : ">"
            if next == ">" || next.isWhitespace { opens += 1 }
            search = r.upperBound
        }
        let closes = lower.components(separatedBy: "</details").count - 1
        return (opens, closes)
    }

    private struct Opening {
        var summary: String
        var open: Bool
        var rest: String?
    }

    /// Splits `<details …><summary>…</summary>rest` into its parts.
    private static func splitOpening(_ html: String) -> Opening {
        let ns = html as NSString
        let lower = html.lowercased() as NSString
        let tagStart = lower.range(of: "<details")
        let tagEnd = lower.range(of: ">", options: [], range: NSRange(location: NSMaxRange(tagStart), length: lower.length - NSMaxRange(tagStart)))
        guard tagEnd.location != NSNotFound else { return Opening(summary: "", open: false, rest: nil) }
        let tag = ns.substring(with: NSRange(location: tagStart.location, length: NSMaxRange(tagEnd) - tagStart.location))
        let isOpen = tag.range(of: "\\sopen(\\s|=|>|/)", options: [.regularExpression, .caseInsensitive]) != nil
        var cursor = NSMaxRange(tagEnd)
        var summary = ""
        let afterTag = NSRange(location: cursor, length: lower.length - cursor)
        let summaryOpen = lower.range(of: "<summary", options: [], range: afterTag)
        if summaryOpen.location != NSNotFound,
           ns.substring(with: NSRange(location: cursor, length: summaryOpen.location - cursor))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let openEnd = lower.range(of: ">", options: [], range: NSRange(location: NSMaxRange(summaryOpen),
                                                                           length: lower.length - NSMaxRange(summaryOpen)))
            if openEnd.location != NSNotFound {
                let contentStart = NSMaxRange(openEnd)
                let close = lower.range(of: "</summary>", options: [], range: NSRange(location: contentStart, length: lower.length - contentStart))
                let contentEnd = close.location == NSNotFound ? lower.length : close.location
                summary = ns.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cursor = close.location == NSNotFound ? lower.length : NSMaxRange(close)
            }
        }
        let rest = ns.substring(from: cursor)
        return Opening(summary: summary, open: isOpen,
                       rest: rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rest)
    }

    private static func textBeforeLastClose(_ html: String) -> String? {
        guard let r = html.range(of: "</details", options: [.caseInsensitive, .backwards]) else { return nil }
        let before = String(html[..<r.lowerBound])
        return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : before
    }

    /// `<details><summary>…</summary>…</details>` within a single HTML block.
    private static func singleBlockDetails(_ html: String) -> Block? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let balance = count(trimmed)
        guard trimmed.lowercased().hasSuffix("</details>"), balance.opens == 1, balance.closes == 1 else { return nil }
        let head = splitOpening(String(trimmed.dropLast("</details>".count)))
        var children: [Block] = []
        if let rest = head.rest { children.append(.html(rest)) }
        return .details(summary: head.summary, open: head.open, children: children)
    }
}
