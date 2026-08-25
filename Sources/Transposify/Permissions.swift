import AVFoundation
import AppKit
import CoreAudio

/// What macOS will let Transposify do, and how to ask for the rest.
///
/// Three separate grants sit behind two things a person actually cares about:
/// hearing Spotify, and reading what is playing. Two of them — System Audio
/// Recording and Microphone — are both needed for the same one tap, so the
/// setup window presents them together and this type reports them together.
enum Permission {
    enum State: Equatable {
        case notAsked
        case allowed
        case denied
        /// Asked for, but the answer cannot be known yet — Automation cannot
        /// be settled while Spotify is closed.
        case unavailable(String)

        var isAllowed: Bool { self == .allowed }
    }

    // MARK: - Hearing Spotify

    /// The tap needs System Audio Recording. It does not need Microphone —
    /// measured, with the Microphone grant reset the tap still creates and
    /// captures. The app never opens an input device.
    ///
    /// Microphone is asked for only if a tap cannot be made without it, which
    /// is how the earliest macOS 14.4 releases behaved and is where the
    /// original request came from. On anything that does not need it the word
    /// "microphone" never reaches the user.
    ///
    /// There is no API that reports System Audio Recording without asking, so
    /// whether the question has been put is remembered here and the answer is
    /// then read by creating a tap and throwing it away.
    private static let audioAskedKey = "audioAccessAsked"

    static var audioAsked: Bool {
        get {
            // A decided Microphone answer means this app has asked before,
            // which covers everyone upgrading from a version that asked at
            // launch without recording that it had.
            UserDefaults.standard.bool(forKey: audioAskedKey)
                || AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
        }
        set { UserDefaults.standard.set(newValue, forKey: audioAskedKey) }
    }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// The last probe's answer. Probing is a real capture, so it is done on
    /// demand rather than every time something wants to know.
    private static var probed: State?

    /// Run the probe and remember the answer. Before the question has ever
    /// been put this *is* the question, so callers must only run it when the
    /// user has asked for it — otherwise a dialog appears unbidden, which is
    /// the whole thing this flow exists to avoid.
    static func checkAudio(_ completion: ((State) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let state: State = AudioCapture.canCapture() ? .allowed : .denied
            DispatchQueue.main.async {
                probed = state
                completion?(state)
            }
        }
    }

    /// Refresh the answer only when doing so cannot prompt.
    static func refreshAudioIfSettled() {
        guard audioAsked, probed == nil else { return }
        checkAudio()
    }

    static var systemAudio: State {
        if let probed { return probed }
        return audioAsked ? .denied : .notAsked
    }

    /// Whether the app can hear Spotify, which is the only thing a person
    /// cares about. A tap that can be made is the whole answer; how many
    /// grants sit behind it is macOS's business.
    static var audio: State { systemAudio }

    /// Ask, and only escalate if asking was not enough.
    ///
    /// The tap prompt blocks the thread it is put on, so this must not run on
    /// the main thread; the answer comes back on the main queue.
    static func requestAudio(_ completion: @escaping (State) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            audioAsked = true
            if AudioCapture.canCapture() {
                DispatchQueue.main.async {
                    probed = .allowed
                    completion(.allowed)
                }
                return
            }
            // Older systems gate the tap on Microphone as well. Nothing else
            // explains a refusal we did not get a dialog for, so ask, and try
            // once more.
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
                DispatchQueue.main.async { probed = .denied; completion(.denied) }
                return
            }
            log.notice("tap refused; falling back to asking for microphone access")
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                let state: State = AudioCapture.canCapture() ? .allowed : .denied
                DispatchQueue.main.async { probed = state; completion(state) }
            }
        }
    }

    // MARK: - Reading what is playing

    /// Reading the current track, its artwork, and pausing Spotify while the
    /// model loads. Setup treats this as needed rather than nice to have, so
    /// it is asked for in the flow rather than turning up unannounced later.
    static func spotifyControl(_ spotify: SpotifyState) -> State {
        guard spotify.isRunning else {
            return .unavailable("Open Spotify to ask for this.")
        }
        switch spotify.automation {
        case .granted: return .allowed
        case .denied: return .denied
        case .unknown: return .notAsked
        }
    }

    /// A refused tap is almost always System Audio Recording; Microphone only
    /// matters where it was the fallback, and then only if it was refused.
    static var audioPane: Pane {
        microphone == .denied ? .microphone : .audioRecording
    }

    // MARK: - Settings panes

    static func openSettings(for pane: Pane) {
        guard let url = URL(string: pane.url) else { return }
        NSWorkspace.shared.open(url)
    }

    enum Pane {
        case audioRecording, microphone, automation

        var url: String {
            let root = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .audioRecording: return root + "Privacy_AudioCapture"
            case .microphone: return root + "Privacy_Microphone"
            case .automation: return root + "Privacy_Automation"
            }
        }
    }
}
