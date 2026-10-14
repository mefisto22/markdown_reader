import Foundation

/// Resolves link and image destinations relative to the Markdown file.
enum LinkResolver {
    static func isRemote(_ destination: String) -> Bool {
        let lower = destination.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    /// Returns the fragment (`#section`) of a destination, if any.
    static func fragment(of destination: String) -> String? {
        guard let hash = destination.firstIndex(of: "#") else { return nil }
        let fragment = String(destination[destination.index(after: hash)...])
        return fragment.isEmpty ? nil : (fragment.removingPercentEncoding ?? fragment)
    }

    /// Resolves a destination to an absolute URL. Relative paths are resolved
    /// against `base` (the directory containing the document).
    static func resolve(_ destination: String, relativeTo base: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") { return URL(string: "https:" + trimmed) }
        if let schemeEnd = trimmed.firstIndex(of: ":"), trimmed.distance(from: trimmed.startIndex, to: schemeEnd) > 1,
           trimmed[..<schemeEnd].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
            return URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        var path = trimmed
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        guard !path.isEmpty else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded).standardizedFileURL }
        if decoded.hasPrefix("~") { return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath).standardizedFileURL }
        guard let base else { return nil }
        // Treat the base as a directory even without a trailing slash.
        let directory = URL(fileURLWithPath: base.path, isDirectory: true)
        return URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL
    }

    /// GitHub-style heading anchor: lowercase, spaces to dashes, punctuation removed.
    static func anchor(for heading: String) -> String {
        var result = ""
        for ch in heading.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                result.append(ch)
            } else if ch == " " {
                result.append("-")
            }
        }
        return result
    }
}
