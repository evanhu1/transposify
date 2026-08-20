import AppKit

/// Fetches and caches Spotify album art for the popover.
///
/// The `PlaybackStateChanged` notification reports `Has Artwork` but not the
/// URL, so the URL has to come from AppleScript — which means artwork depends
/// on Automation permission and must degrade to a placeholder without it.
/// Nothing here is load-bearing: it is decoration on a control panel.
final class ArtworkStore {
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight = Set<String>()
    private var failedOnce = false

    /// Called on the main queue when a newly fetched image is available.
    var onChange: (() -> Void)?

    init() { cache.countLimit = 24 }

    /// Cached art for a track, or nil. Never blocks.
    func image(for trackID: String) -> NSImage? {
        cache.object(forKey: trackID as NSString)
    }

    /// Snapshot/testing only: supply art directly.
    func seed(_ image: NSImage, for trackID: String) {
        cache.setObject(image, forKey: trackID as NSString)
    }

    /// Start a fetch if this track isn't cached or already being fetched.
    func request(trackID: String) {
        guard !trackID.isEmpty,
              cache.object(forKey: trackID as NSString) == nil,
              !inFlight.contains(trackID) else { return }
        inFlight.insert(trackID)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Ask for the id and the URL together: by the time this runs the
            // current track may have moved on, and caching art under the wrong
            // id would show the previous cover.
            guard let pair = Self.currentArtwork() else {
                DispatchQueue.main.async {
                    self.inFlight.remove(trackID)
                    if !self.failedOnce {
                        self.failedOnce = true
                        log.notice("album art unavailable (Automation permission?)")
                    }
                }
                return
            }
            guard let url = URL(string: pair.url) else {
                DispatchQueue.main.async { self.inFlight.remove(trackID) }
                return
            }
            // URLSession rather than Data(contentsOf:) so a stalled CDN can't
            // pin a worker thread indefinitely.
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { data, _, error in
                DispatchQueue.main.async {
                    self.inFlight.remove(trackID)
                    guard let data, let image = NSImage(data: data) else {
                        if let error {
                            log.error("album art download failed: \(String(describing: error), privacy: .public)")
                        }
                        return
                    }
                    self.cache.setObject(image, forKey: pair.trackID as NSString)
                    log.notice("album art loaded for \(pair.trackID, privacy: .public)")
                    self.onChange?()
                }
            }.resume()
        }
    }

    private static func currentArtwork() -> (trackID: String, url: String)? {
        let source = """
        tell application "Spotify"
            set theTrackID to (id of current track) as text
            set theArtURL to (artwork url of current track) as text
            return theTrackID & "\u{0001}" & theArtURL
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?
                .executeAndReturnError(&error).stringValue, error == nil else { return nil }
        let parts = result.components(separatedBy: "\u{0001}")
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
