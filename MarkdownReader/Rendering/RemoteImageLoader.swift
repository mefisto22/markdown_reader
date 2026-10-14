import AppKit

/// Downloads remote (`http`/`https`) images for the reader. Used only when
/// View ▸ Load Remote Images is on; otherwise the app makes no network
/// requests at all. Images are cached in memory for the session; a failed
/// download is not retried until the setting is toggled or the app restarts.
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()
    /// Posted on the main thread when an image finished loading; `object` is the URL.
    static let didLoadNotification = Notification.Name("RemoteImageDidLoad")

    enum State {
        case loaded(NSImage)
        case loading
        case failed
        case idle
    }

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: Set<URL> = []
    private var failed: Set<URL> = []
    private let lock = NSLock()
    private let maxBytes = 25 * 1024 * 1024

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        return URLSession(configuration: configuration)
    }()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 200 * 1024 * 1024
    }

    func state(for url: URL) -> State {
        if let image = cache.object(forKey: url as NSURL) { return .loaded(image) }
        lock.lock()
        defer { lock.unlock() }
        if failed.contains(url) { return .failed }
        if inFlight.contains(url) { return .loading }
        return .idle
    }

    /// Starts downloading `url` unless it is cached, in flight or failed.
    func load(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        lock.lock()
        let skip = inFlight.contains(url) || failed.contains(url) || cache.object(forKey: url as NSURL) != nil
        if !skip { inFlight.insert(url) }
        lock.unlock()
        guard !skip else { return }

        let task = session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            var image: NSImage?
            if let data, data.count <= self.maxBytes,
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                image = NSImage(data: data)
                if image?.isValid != true { image = nil }
            }
            self.lock.lock()
            self.inFlight.remove(url)
            if let image {
                self.cache.setObject(image, forKey: url as NSURL, cost: data?.count ?? 0)
            } else {
                self.failed.insert(url)
            }
            self.lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didLoadNotification, object: url)
            }
        }
        task.resume()
    }

    /// Forgets failures so images are retried (setting turned on again).
    func resetFailures() {
        lock.lock()
        failed.removeAll()
        lock.unlock()
    }
}
