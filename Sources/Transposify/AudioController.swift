import AppKit
import os

let log = Logger(subsystem: "com.evanhu.transposify", category: "audio")

/// Owns the capture + pitch pipeline and decides when it should run.
///
/// Core rule: the tap is engaged **only** while Spotify is playing AND there's
/// something to do (`semitones != 0` or karaoke on). At 0 with karaoke off the
/// pipeline is fully torn down, so Spotify plays untouched, bit-perfect, with
/// zero added latency. Settings are remembered per Spotify track.
final class AudioController {
    enum Mode: Equatable {
        case shifting(Int)
        case karaoke
        case original
        case paused
        case notRunning
        case error(String)
    }

    private(set) var semitones = 0
    private(set) var karaoke = false
    private(set) var rememberThisSong = true
    private(set) var engaged = false

    /// Global on/off. When off, the pipeline never engages and Spotify plays
    /// untouched — lets you just listen without quitting. Persisted across launches.
    private(set) var enabled: Bool

    var onChange: (() -> Void)?

    private static let enabledKey = "globalEnabled"

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
    }

    private var currentTrackID: String?
    private var hasTrack = false
    private var spotifyPlaying = false
    private var spotifyRunning = false
    private var permissionDenied = false
    private var lastError: String?

    private var capture: AudioCapture?
    private var engine: PitchEngine?
    private let store = SongSettingsStore()

    private var disengageWork: DispatchWorkItem?
    private var reconfiguring = false

    /// When set, engage/disengage drive these stubs instead of real audio —
    /// used by the headless self-test to verify the state machine.
    var testHooks: (engage: (Int, Bool) -> Void, disengage: () -> Void)?

    // MARK: - Inputs from Spotify

    func spotifyUpdate(running: Bool, playing: Bool, trackID: String?) {
        spotifyRunning = running
        spotifyPlaying = playing
        if trackID != currentTrackID {
            currentTrackID = trackID
            hasTrack = trackID != nil
            loadSettingForCurrentTrack()
        }
        updateEngagement()
        onChange?()
    }

    private func loadSettingForCurrentTrack() {
        if let id = currentTrackID, let saved = store.setting(for: id) {
            semitones = saved.semitones
            karaoke = saved.karaoke
        } else {
            semitones = 0
            karaoke = false
        }
        rememberThisSong = true
        engine?.semitones = semitones
        engine?.karaoke = karaoke
    }

    // MARK: - User actions

    func setSemitones(_ value: Int) {
        let clamped = max(-12, min(12, value))
        guard clamped != semitones else { return }
        semitones = clamped
        engine?.semitones = clamped
        persistIfRemembering()
        updateEngagement()
        onChange?()
    }

    func nudge(_ delta: Int) { setSemitones(semitones + delta) }
    func resetPitch() { setSemitones(0) }

    func setKaraoke(_ on: Bool) {
        guard on != karaoke else { return }
        karaoke = on
        engine?.karaoke = on
        persistIfRemembering()
        updateEngagement()
        onChange?()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        updateEngagement()
        onChange?()
    }

    func setRemember(_ on: Bool) {
        rememberThisSong = on
        if let id = currentTrackID {
            if on {
                persistIfRemembering()
            } else {
                store.remove(for: id)
            }
        }
        onChange?()
    }

    func reportPermissionDenied() {
        permissionDenied = true
        log.error("microphone access denied")
        onChange?()
    }

    func shutdown() {
        disengageWork?.cancel()
        disengage()
    }

    private func persistIfRemembering() {
        guard rememberThisSong, let id = currentTrackID else { return }
        if semitones == 0 && !karaoke {
            store.remove(for: id) // don't keep a no-op entry
        } else {
            store.save(SongSetting(semitones: semitones, karaoke: karaoke), for: id)
        }
    }

    // MARK: - Engagement

    private var shouldEngage: Bool {
        enabled && spotifyRunning && spotifyPlaying && hasTrack && (semitones != 0 || karaoke)
    }

    private func updateEngagement() {
        if shouldEngage {
            disengageWork?.cancel()
            disengageWork = nil
            if !engaged { engage() }
        } else {
            scheduleDisengage()
        }
    }

    /// Debounced so scrubbing through 0 doesn't tear down and rebuild the tap.
    private func scheduleDisengage() {
        guard engaged, disengageWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.disengageWork = nil
            if !self.shouldEngage { self.disengage() }
        }
        disengageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func engage() {
        if let hooks = testHooks {
            engaged = true
            lastError = nil
            hooks.engage(semitones, karaoke)
            onChange?()
            return
        }
        do {
            let capture = AudioCapture()
            try capture.start()
            let engine = PitchEngine(sampleRate: capture.sampleRate,
                                     channels: capture.channelCount, ring: capture.ring)
            engine.semitones = semitones
            engine.karaoke = karaoke
            engine.onConfigurationChange = { [weak self] in self?.reconfigure() }
            try engine.start()
            self.capture = capture
            self.engine = engine
            engaged = true
            lastError = nil
            log.notice("engaged: \(capture.sampleRate, privacy: .public) Hz, pitch \(self.semitones, privacy: .public) st, karaoke \(self.karaoke, privacy: .public)")
        } catch {
            disengage()
            lastError = (error as? AudioCaptureError)?.description ?? "\(error)"
            log.error("engage failed: \(self.lastError ?? "", privacy: .public)")
        }
        onChange?()
    }

    private func disengage() {
        let wasEngaged = engaged
        if let hooks = testHooks {
            engaged = false
            if wasEngaged { hooks.disengage() }
            onChange?()
            return
        }
        engine?.stop(); engine = nil
        capture?.stop(); capture = nil
        engaged = false
        if wasEngaged { log.notice("disengaged (passthrough)") }
        onChange?()
    }

    /// Output route or format changed (e.g. headphones plugged in): rebuild.
    private func reconfigure() {
        guard engaged, !reconfiguring else { return }
        reconfiguring = true
        log.notice("audio route changed; rebuilding")
        disengage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.reconfiguring = false
            self.updateEngagement()
        }
    }

    // MARK: - Status for UI

    var mode: Mode {
        if permissionDenied {
            return .error("Microphone access needed \u{2014} enable it in System Settings "
                + "\u{25B8} Privacy & Security \u{25B8} Microphone, then reopen.")
        }
        if !spotifyRunning { return .notRunning }
        if !enabled { return spotifyPlaying ? .original : .paused }
        if (semitones != 0 || karaoke), !engaged, let error = lastError, spotifyPlaying {
            return .error(error)
        }
        if !spotifyPlaying { return .paused }
        if semitones != 0 { return .shifting(semitones) }
        if karaoke { return .karaoke }
        return .original
    }
}
