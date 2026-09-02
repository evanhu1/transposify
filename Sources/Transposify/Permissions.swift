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
    /// Core Audio tap creation is stateful system work. Serialize checks so a
    /// launch recheck and a user request cannot create competing temporary
    /// devices or let an older answer overwrite a newer recovery.
    private static let probeQueue = DispatchQueue(
        label: "com.evanhu.transposify.permission-probe", qos: .userInitiated)

    /// What a probe means. Running Spotify is the whole precondition:
    /// measured, a tap on a paused Spotify still delivers buffers, so silence
    /// from a Spotify that is up is a refusal rather than a quiet moment. A
    /// Spotify that is not up tells us nothing either way.
    private static func read(_ probe: AudioCapture.Probe) -> State {
        switch probe {
        case .captured:
            return .allowed
        case .failed(let error):
            if case AudioCaptureError.spotifyNotFound = error {
                return .unavailable("Open Spotify first.")
            }
            return .denied
        case .silent:
            return .denied
        }
    }

    /// Run the probe and remember the answer. Before the question has ever
    /// been put this *is* the question, so callers must only run it when the
    /// user has asked for it — otherwise a dialog appears unbidden, which is
    /// the whole thing this flow exists to avoid.
    static func checkAudio(_ completion: ((State) -> Void)? = nil) {
        probeQueue.async {
            let state = read(AudioCapture.probe())
            DispatchQueue.main.async {
                probed = state
                completion?(state)
            }
        }
    }

    static var systemAudio: State {
        if let probed { return probed }
        // No probe, no answer. Reporting a refusal here would put "Not
        // allowed" on a grant that may well be in place.
        return .notAsked
    }

    /// Re-read the answer when doing so cannot put a question: only after the
    /// user has been asked once, and only with Spotify running, or the probe
    /// learns nothing.
    static func recheckIfAsked(running: Bool,
                               completion: ((State) -> Void)? = nil) {
        guard audioAsked, running, probed?.isAllowed != true else {
            completion?(audio)
            return
        }
        checkAudio(completion)
    }

    /// Whether the app can hear Spotify, which is the only thing a person
    /// cares about. A tap that can be made is the whole answer; how many
    /// grants sit behind it is macOS's business.
    static var audio: State { systemAudio }

    /// Ask, and only escalate if asking was not enough.
    ///
    /// The tap prompt blocks the thread it is put on, so this must not run on
    /// the main thread; the answer comes back on the main queue.
    ///
    /// Only call this with Spotify running. With Spotify closed the probe
    /// cannot put the question at all, and the fallback below then asks for
    /// the microphone for no reason — which is the bug this flow exists to
    /// prevent.
    static func requestAudio(_ completion: @escaping (State) -> Void) {
        probeQueue.async {
            audioAsked = true
            let state = read(AudioCapture.probe())
            // Older systems gate the tap on Microphone as well. Only a real
            // refusal justifies asking: an unavailable answer means the probe
            // never got to put the question.
            guard state == .denied,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            else {
                DispatchQueue.main.async { probed = state; completion(state) }
                return
            }
            log.notice("tap refused; falling back to asking for microphone access")
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                let retry = read(AudioCapture.probe())
                DispatchQueue.main.async { probed = retry; completion(retry) }
            }
        }
    }

    // MARK: - Reading what is playing

    /// Reading the current track, its artwork, and pausing Spotify while the
    /// model loads. Setup treats this as needed rather than nice to have, so
    /// it is asked for in the flow rather than turning up unannounced later.
    static func spotifyControl(_ spotify: SpotifyState) -> State {
        // A decided grant stays decided while Spotify is closed. Setup should
        // keep completed work checked instead of making it look revoked.
        if spotify.automation == .granted { return .allowed }
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

    @discardableResult
    static func openSettings(for pane: Pane) -> Bool {
        guard let url = URL(string: pane.url) else { return false }
        return NSWorkspace.shared.open(url)
    }

    enum Pane: Equatable {
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
