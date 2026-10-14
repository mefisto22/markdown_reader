import AppKit

/// Folder access for the sandboxed build (Release-Sandboxed configuration).
///
/// A sandboxed app that opens a document may read only that file, so
/// relative images and links next to it need the user's permission for the
/// folder. Granted folders are remembered as security-scoped bookmarks and
/// re-opened at launch. In the regular (non-sandboxed) build every check
/// here is a no-op.
enum FolderAccess {
    static let didChangeNotification = Notification.Name("FolderAccessDidChange")
    private static let defaultsKey = "FolderAccessBookmarks"
    private static var granted: [URL] = []

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Resolves the stored bookmarks and starts accessing those folders.
    static func restoreBookmarks() {
        guard isSandboxed else { return }
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var keep: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() { granted.append(url.standardizedFileURL) }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
                keep.append(fresh)
            } else {
                keep.append(data)
            }
        }
        UserDefaults.standard.set(keep, forKey: defaultsKey)
    }

    /// True if `url` lies inside a folder the user granted access to.
    static func isCovered(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return granted.contains { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }

    /// True when a relative or local resource cannot be read because of the
    /// sandbox (rather than because it does not exist).
    static func needsGrant(for source: String, baseURL: URL?) -> Bool {
        guard isSandboxed, !LinkResolver.isRemote(source), !source.hasPrefix("data:"),
              let url = LinkResolver.resolve(source, relativeTo: baseURL), url.isFileURL else { return false }
        return !isCovered(url) && !FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Asks the user to grant access to `directory` (or a folder above it).
    static func requestAccess(suggesting directory: URL?, window: NSWindow?, completion: ((Bool) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Grant Access"
        panel.message = "Markdown Reader needs permission to read this folder to show images and open linked files."
        panel.directoryURL = directory
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion?(false); return }
            grant(url)
            completion?(true)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    private static func grant(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
            stored.append(data)
            UserDefaults.standard.set(stored, forKey: defaultsKey)
        }
        if url.startAccessingSecurityScopedResource() || !isSandboxed { granted.append(url.standardizedFileURL) }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
