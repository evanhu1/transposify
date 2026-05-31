import AppKit

struct TrackInfo: Equatable {
    var id: String
    var name: String
    var artist: String
}

/// Tracks Spotify's now-playing state via its `PlaybackStateChanged`
/// distributed notification (instant, no polling), with AppleScript used only
/// for the initial snapshot and artwork URLs. Never launches Spotify.
final class SpotifyState {
    private(set) var current: TrackInfo?
    private(set) var isPlaying = false
    private(set) var isRunning = false

    var onChange: (() -> Void)?

    private let bundleID = "com.spotify.client"
    private let notifName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)), name: notifName, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appsChanged),
                              name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appsChanged),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refreshRunning()
        if isRunning { queryInitialState() }
    }

    private func refreshRunning() {
        isRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
        if !isRunning { isPlaying = false; current = nil }
    }

    @objc private func appsChanged() {
        let wasRunning = isRunning
        refreshRunning()
        if isRunning && !wasRunning {
            // Spotify's scripting interface isn't ready the instant it launches.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.queryInitialState()
                self?.onChange?()
            }
        }
        onChange?()
    }

    @objc private func playbackChanged(_ note: Notification) {
        guard let info = note.userInfo else { return }
        isRunning = true
        let state = (info["Player State"] as? String) ?? "Paused"
        isPlaying = state.caseInsensitiveCompare("Playing") == .orderedSame
        let id = (info["Track ID"] as? String) ?? current?.id ?? ""
        let name = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        current = TrackInfo(id: id, name: name, artist: artist)
        onChange?()
    }

    private func queryInitialState() {
        guard isRunning else { return }
        guard let out = runAppleScript("""
        tell application "Spotify"
            set st to (player state) as text
            set tid to (id of current track) as text
            set tnm to (name of current track) as text
            set tar to (artist of current track) as text
            return st & "\u{0001}" & tid & "\u{0001}" & tnm & "\u{0001}" & tar
        end tell
        """) else { return }
        let parts = out.components(separatedBy: "\u{0001}")
        guard parts.count >= 4 else { return }
        isPlaying = parts[0].caseInsensitiveCompare("playing") == .orderedSame
        current = TrackInfo(id: parts[1], name: parts[2], artist: parts[3])
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
