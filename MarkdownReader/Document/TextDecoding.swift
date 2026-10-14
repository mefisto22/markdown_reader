import Foundation

/// Text encoding detection and round-tripping. Files are written back in the
/// encoding they were read with (including a UTF-8 byte order mark if one was
/// present), so saving never silently rewrites a file's byte format. Line
/// endings are never modified.
enum TextDecoding {
    struct Decoded: Equatable {
        var text: String
        var encoding: String.Encoding
        var hasBOM: Bool
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

    static func decode(_ data: Data) -> Decoded {
        if data.isEmpty { return Decoded(text: "", encoding: .utf8, hasBOM: false) }
        if data.starts(with: utf8BOM), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, hasBOM: true)
        }
        if data.starts(with: utf16LEBOM), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return Decoded(text: text, encoding: .utf16LittleEndian, hasBOM: true)
        }
        if data.starts(with: utf16BEBOM), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return Decoded(text: text, encoding: .utf16BigEndian, hasBOM: true)
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, hasBOM: false)
        }
        // Legacy 8-bit encodings. Windows-1250 / ISO 8859-2 cover Hungarian (ő, ű).
        let suggestions: [String.Encoding] = [.windowsCP1250, .isoLatin2, .windowsCP1252, .macOSRoman]
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: suggestions.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        if raw != 0, let converted, !lossy.boolValue {
            return Decoded(text: converted as String, encoding: String.Encoding(rawValue: raw), hasBOM: false)
        }
        // ISO Latin 1 maps every byte, so this never fails and never loses bytes.
        let text = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        return Decoded(text: text, encoding: .isoLatin1, hasBOM: false)
    }

    /// Encodes `text` in the preferred encoding. If the text contains
    /// characters the encoding cannot represent, falls back to UTF-8 rather
    /// than dropping characters. Returns the encoding actually used.
    static func encode(_ text: String, encoding: String.Encoding, hasBOM: Bool) -> (Data, String.Encoding) {
        if let data = text.data(using: encoding, allowLossyConversion: false) {
            var result = Data()
            if hasBOM {
                switch encoding {
                case .utf8: result.append(contentsOf: utf8BOM)
                case .utf16LittleEndian: result.append(contentsOf: utf16LEBOM)
                case .utf16BigEndian: result.append(contentsOf: utf16BEBOM)
                default: break
                }
            }
            result.append(data)
            return (result, encoding)
        }
        var result = Data()
        if hasBOM { result.append(contentsOf: utf8BOM) }
        result.append(Data(text.utf8))
        return (result, .utf8)
    }

    /// The first character `encoding` cannot represent, or nil if it can
    /// represent the whole text.
    static func firstUnencodableCharacter(in text: String, encoding: String.Encoding) -> String? {
        switch encoding {
        case .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32, .unicode: return nil
        default: break
        }
        guard text.data(using: encoding, allowLossyConversion: false) == nil else { return nil }
        for ch in text where String(ch).data(using: encoding, allowLossyConversion: false) == nil {
            return String(ch)
        }
        return nil
    }

    static func displayName(_ encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian, .utf16BigEndian, .utf16: return "UTF-16"
        case .windowsCP1250: return "Windows-1250"
        case .isoLatin2: return "ISO 8859-2"
        case .windowsCP1252: return "Windows-1252"
        case .isoLatin1: return "ISO 8859-1"
        case .macOSRoman: return "Mac Roman"
        default: return String.localizedName(of: encoding)
        }
    }
}
