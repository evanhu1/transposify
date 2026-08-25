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

    /// Whether Apple Events to Spotify are allowed. Only the now-playing
    /// snapshot and album art need it; playback tracking does not.
    private(set) var automation: AutomationPermission.Status = .unknown

    var onChange: (() -> Void)?

    private let bundleID = "com.spotify.client"
    private let notifName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private var observing = false
    /// Whether Apple Events may be sent without the user having just asked
    /// for something. Setup watches Spotify long before the Automation
    /// question has been put, and an event sent on its own initiative is what
    /// makes macOS put it — so the answer stays no until the user presses the
    /// button that means yes.
    private var maySendEvents = false

    /// Begin watching Spotify without sending it anything.
    ///
    /// Playback notifications need no permission, so setup can know what is
    /// playing before the Automation question has been put. Safe to call more
    /// than once.
    func startObserving() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)), name: notifName, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appsChanged),
                              name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appsChanged),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refreshRunning()
    }

    func start() {
        startObserving()
        maySendEvents = true
        // Querying is also what triggers macOS's consent prompt.
        if isRunning { queryInitialState() }
    }

    /// Whether Spotify is up, without sending it anything. Setup needs this
    /// before `start()` has run, and asking over Apple Events would put the
    /// Automation question before the user has pressed anything.
    func refreshRunningState() { refreshRunning() }

    /// Whether Spotify is on this Mac at all. Everything setup asks for is
    /// about Spotify, so there is nothing to ask when it is missing.
    var isInstalled: Bool { appURL != nil }

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Open Spotify. Returns whether it could be started at all — a missing
    /// app has to be said out loud rather than left as a spinner.
    @discardableResult
    func launch() -> Bool {
        guard let appURL else { return false }
        NSWorkspace.shared.openApplication(at: appURL,
                                           configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private func refreshRunning() {
        isRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
        if !isRunning { isPlaying = false; current = nil }
    }

    @objc private func appsChanged() {
        let wasRunning = isRunning
        refreshRunning()
        if isRunning && !wasRunning, maySendEvents {
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
        guard isRunning, maySendEvents else { return }
        // Player state first, and on its own. It is the one thing Spotify can
        // always answer: `current track` fails when nothing has been played
        // yet, and folding the two together made a fresh Spotify look like a
        // refused permission.
        guard let state = runAppleScript(
            "tell application \"Spotify\" to return (player state) as text") else { return }
        isPlaying = state.caseInsensitiveCompare("playing") == .orderedSame
        // Variable names matter here: `st` is reserved and makes the whole
        // script fail to compile, which silently left the initial snapshot
        // empty until the next play/pause notification arrived.
        guard let out = runAppleScript("""
        tell application "Spotify"
            set trackID to (id of current track) as text
            set trackName to (name of current track) as text
            set trackArtist to (artist of current track) as text
            return trackID & "\u{0001}" & trackName & "\u{0001}" & trackArtist
        end tell
        """) else { current = nil; return }
        let parts = out.components(separatedBy: "\u{0001}")
        guard parts.count >= 3 else { return }
        current = TrackInfo(id: parts[0], name: parts[1], artist: parts[2])
    }

    /// Re-read now-playing over AppleScript. Called when the popover opens: a
    /// user-initiated moment is the right time for macOS to show its consent
    /// prompt, and it also recovers without a relaunch if permission is granted
    /// in System Settings after the fact.
    func refreshNowPlaying() {
        guard isRunning else { return }
        // Asked for by hand, so this is the yes that unblocks the rest.
        maySendEvents = true
        queryInitialState()
        onChange?()
    }

    /// Ask Spotify to start or stop playing.
    ///
    /// Returns whether the command reached Spotify: it needs automation
    /// permission, and without it nothing happens. The caller has to know,
    /// because a pause that never landed must not be followed by a resume.
    @discardableResult
    func setPlaying(_ playing: Bool) -> Bool {
        guard isRunning else { return false }
        return execute("tell application \"Spotify\" to \(playing ? "play" : "pause")") != nil
    }

    /// Snapshot/testing only: present a fixed now-playing track.
    func injectSnapshotTrack(name: String, artist: String) {
        isRunning = true
        isPlaying = true
        current = TrackInfo(id: "snapshot", name: name, artist: artist)
    }

    private func runAppleScript(_ source: String) -> String? {
        execute(source)?.stringValue
    }

    /// Runs a script and returns its result, or nil if it failed. A command
    /// with no result still returns a descriptor, so nil means an error — which
    /// is what tells `setPlaying` whether the command landed.
    private func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -1743 is specifically "not authorised to send Apple events", so
            // the failure doubles as the permission answer. Playback
            // notifications still work, so the app recovers regardless.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == AutomationPermission.notPermitted {
                if automation != .denied {
                    automation = .denied
                    log.notice("automation permission denied; album art unavailable")
                    onChange?()
                }
            } else {
                log.error("Spotify query failed: \(error, privacy: .public)")
            }
            return nil
        }
        if automation != .granted { automation = .granted }
        return result
    }
}
