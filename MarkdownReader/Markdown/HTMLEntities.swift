import Foundation

/// Decodes HTML character references (`&amp;`, `&#233;`, `&#x151;`) using
/// the complete HTML5 named-entity list (`HTMLEntityTable.swift`).
enum HTMLEntities {
    static let named: [String: String] = {
        var result: [String: String] = [:]
        result.reserveCapacity(2200)
        for chunk in table {
            for record in chunk.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
                guard let sep = record.firstIndex(of: "\u{1F}") else { continue }
                result[String(record[..<sep])] = String(record[record.index(after: sep)...])
            }
        }
        return result
    }()

    /// Attempts to decode an entity starting at `i` (which must be `&`).
    /// Returns the decoded string and the index after the terminating `;`.
    static func decode<C: Collection>(_ s: C, at i: Int) -> (String, Int)? where C.Element == UInt8, C.Index == Int {
        guard i < s.endIndex, s[i] == Byte.amp else { return nil }
        var j = i + 1
        guard j < s.endIndex else { return nil }
        if s[j] == Byte.hash {
            j += 1
            var hex = false
            if j < s.endIndex, s[j] | 0x20 == 0x78 { hex = true; j += 1 } // x or X
            let digitsStart = j
            var value: UInt32 = 0
            while j < s.endIndex, j - digitsStart < (hex ? 6 : 7) {
                let b = s[j]
                if Byte.isDigit(b) {
                    value = value &* (hex ? 16 : 10) &+ UInt32(b - 0x30)
                } else if hex, (b | 0x20) >= 0x61, (b | 0x20) <= 0x66 {
                    value = value &* 16 &+ UInt32((b | 0x20) - 0x61 + 10)
                } else {
                    break
                }
                j += 1
            }
            guard j > digitsStart, j < s.endIndex, s[j] == Byte.semicolon else { return nil }
            let scalar = (value == 0 || value > 0x10FFFF) ? Unicode.Scalar(0xFFFD)! : (Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)!)
            return (String(Character(scalar)), j + 1)
        }
        let nameStart = j
        while j < s.endIndex, Byte.isAlnum(s[j]), j - nameStart < 32 { j += 1 }
        guard j > nameStart, j < s.endIndex, s[j] == Byte.semicolon else { return nil }
        let name = String(decoding: s[nameStart..<j], as: UTF8.self)
        guard let value = named[name] else { return nil }
        return (value, j + 1)
    }
}
