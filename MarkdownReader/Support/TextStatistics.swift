import Foundation

struct TextStatistics: Equatable {
    var words = 0
    var characters = 0
    var lines = 0

    /// Counts words (runs of non-whitespace), user-perceived characters and
    /// lines (LF, CRLF and CR all count as one line break).
    static func compute(_ text: String) -> TextStatistics {
        var stats = TextStatistics()
        guard !text.isEmpty else { return stats }
        stats.characters = text.count
        var inWord = false
        var breaks = 0
        var previousCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x0A {
                if !previousCR { breaks += 1 }
                previousCR = false
            } else if v == 0x0D {
                breaks += 1
                previousCR = true
            } else {
                previousCR = false
            }
            let isSpace = v == 0x20 || v == 0x09 || v == 0x0A || v == 0x0D || (v > 0x7F && scalar.properties.isWhitespace)
            if isSpace {
                inWord = false
            } else if !inWord {
                inWord = true
                stats.words += 1
            }
        }
        stats.lines = breaks + 1
        return stats
    }
}
