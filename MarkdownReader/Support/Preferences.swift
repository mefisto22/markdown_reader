import AppKit

enum ViewMode: String, CaseIterable {
    case reader, editor, split

    var title: String {
        switch self {
        case .reader: return "Reader"
        case .editor: return "Editor"
        case .split: return "Split View"
        }
    }

    var symbolName: String {
        switch self {
        case .reader: return "book"
        case .editor: return "pencil.line"
        case .split: return "rectangle.split.2x1"
        }
    }
}

enum ReadingWidth: Int, CaseIterable {
    case narrow = 0, medium, wide, full

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .medium: return "Medium"
        case .wide: return "Wide"
        case .full: return "Full Width"
        }
    }

    /// Maximum text column width in points, scaled by font size.
    func maxWidth(fontSize: CGFloat) -> CGFloat? {
        let scale = fontSize / 16
        switch self {
        case .narrow: return 600 * scale
        case .medium: return 760 * scale
        case .wide: return 980 * scale
        case .full: return nil
        }
    }
}

/// Light or dark appearance; `system` follows the macOS setting (and
/// switches automatically with it, e.g. Auto at sunset).
enum AppAppearance: Int, CaseIterable {
    case system = 0, light, dark

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The appearance to set on the application; nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Small UserDefaults-backed store for the handful of persisted UI settings.
/// Changes are broadcast so every open window can update.
final class Preferences {
    static let shared = Preferences()
    static let didChangeNotification = Notification.Name("PreferencesDidChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let viewMode = "ViewMode"
        static let readerFontSize = "ReaderFontSize"
        static let editorFontSize = "EditorFontSize"
        static let editorMonospaced = "EditorMonospaced"
        static let syntaxHighlighting = "SyntaxHighlighting"
        static let wrapLines = "WrapLines"
        static let readingWidth = "ReadingWidth"
        static let syncScrolling = "SyncScrolling"
        static let showOutline = "ShowOutline"
        static let windowWidth = "WindowWidth"
        static let windowHeight = "WindowHeight"
        static let splitFraction = "SplitFraction"
        static let loadRemoteImages = "LoadRemoteImages"
        static let appearance = "Appearance"
    }

    static let defaultReaderFontSize: CGFloat = 16
    static let defaultEditorFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 9...36

    private init() {
        defaults.register(defaults: [
            Key.viewMode: ViewMode.reader.rawValue,
            Key.readerFontSize: Double(Self.defaultReaderFontSize),
            Key.editorFontSize: Double(Self.defaultEditorFontSize),
            Key.editorMonospaced: true,
            Key.syntaxHighlighting: true,
            Key.wrapLines: true,
            Key.readingWidth: ReadingWidth.medium.rawValue,
            Key.syncScrolling: true,
            Key.loadRemoteImages: false,
            Key.appearance: AppAppearance.system.rawValue,
            Key.showOutline: false,
            Key.splitFraction: 0.5,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    var viewMode: ViewMode {
        get { ViewMode(rawValue: defaults.string(forKey: Key.viewMode) ?? "") ?? .reader }
        set { defaults.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    var readerFontSize: CGFloat {
        get { clampFont(defaults.double(forKey: Key.readerFontSize), fallback: Self.defaultReaderFontSize) }
        set { defaults.set(Double(clampFont(newValue, fallback: Self.defaultReaderFontSize)), forKey: Key.readerFontSize); changed() }
    }

    var editorFontSize: CGFloat {
        get { clampFont(defaults.double(forKey: Key.editorFontSize), fallback: Self.defaultEditorFontSize) }
        set { defaults.set(Double(clampFont(newValue, fallback: Self.defaultEditorFontSize)), forKey: Key.editorFontSize); changed() }
    }

    var editorMonospaced: Bool {
        get { defaults.bool(forKey: Key.editorMonospaced) }
        set { defaults.set(newValue, forKey: Key.editorMonospaced); changed() }
    }

    var syntaxHighlighting: Bool {
        get { defaults.bool(forKey: Key.syntaxHighlighting) }
        set { defaults.set(newValue, forKey: Key.syntaxHighlighting); changed() }
    }

    var wrapLines: Bool {
        get { defaults.bool(forKey: Key.wrapLines) }
        set { defaults.set(newValue, forKey: Key.wrapLines); changed() }
    }

    var readingWidth: ReadingWidth {
        get { ReadingWidth(rawValue: defaults.integer(forKey: Key.readingWidth)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.readingWidth); changed() }
    }

    var syncScrolling: Bool {
        get { defaults.bool(forKey: Key.syncScrolling) }
        set { defaults.set(newValue, forKey: Key.syncScrolling); changed() }
    }

    /// Off by default: without it the app makes no network requests.
    var loadRemoteImages: Bool {
        get { defaults.bool(forKey: Key.loadRemoteImages) }
        set { defaults.set(newValue, forKey: Key.loadRemoteImages); changed() }
    }

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.integer(forKey: Key.appearance)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance); changed() }
    }

    var showOutline: Bool {
        get { defaults.bool(forKey: Key.showOutline) }
        set { defaults.set(newValue, forKey: Key.showOutline) }
    }

    var splitFraction: CGFloat {
        get { CGFloat(min(max(defaults.double(forKey: Key.splitFraction), 0.15), 0.85)) }
        set { defaults.set(Double(newValue), forKey: Key.splitFraction) }
    }

    var windowSize: NSSize? {
        get {
            let w = defaults.double(forKey: Key.windowWidth)
            let h = defaults.double(forKey: Key.windowHeight)
            return w >= 300 && h >= 200 ? NSSize(width: w, height: h) : nil
        }
        set {
            defaults.set(Double(newValue?.width ?? 0), forKey: Key.windowWidth)
            defaults.set(Double(newValue?.height ?? 0), forKey: Key.windowHeight)
        }
    }

    private func clampFont(_ value: Double, fallback: CGFloat) -> CGFloat {
        let v = CGFloat(value)
        guard v > 0 else { return fallback }
        return min(max(v, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }
}
