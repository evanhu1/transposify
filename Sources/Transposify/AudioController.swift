import AppKit
import os

let log = Logger(subsystem: "com.evanhu.transposify", category: "audio")

/// Which part of the mix to keep. Both isolating modes run the same HTDemucs
/// pass — the model returns all four stems on every window, so choosing vocals
/// instead of everything-else only changes which stems get summed. Neither
/// costs more than the other.
enum IsolateTrack: String, CaseIterable {
    /// Leave the mix alone.
    case off
    /// Keep the vocal, drop the backing.
    case vocals
    /// Keep the backing, drop the vocal.
    case instrumental

    /// Both isolating modes need the model, and both add the pipeline's ~2 s.
    var isolating: Bool { self != .off }

    var title: String {
        switch self {
        case .off: return "Off"
        case .vocals: return "Only Vocals"
        case .instrumental: return "Only Instrumental"
        }
    }
}

/// Owns the capture + pitch pipeline and decides when it should run.
///
/// Core rule: the tap is engaged **only** while Spotify is playing AND there's
/// something to do (`semitones != 0` or vocal reduction on). With nothing to do
/// the pipeline is fully torn down, so Spotify plays untouched, bit-perfect,
/// with zero added latency. Transpose is remembered per Spotify track; vocal
/// reduction is a global preference.
final class AudioController {
    enum Mode: Equatable {
        case shifting(Int)
        case isolating
        case original
        case paused
        case notRunning
        case error(String)
    }

    private(set) var semitones = 0
    private(set) var rememberThisSong = true
    private(set) var engaged = false

    /// Global on/off. When off, the pipeline never engages and Spotify plays
    /// untouched — lets you just listen without quitting. Persisted across launches.
    private(set) var enabled: Bool

    /// Isolation is a global preference, not per-song: it applies to whatever
    /// is playing and persists across launches.
    private(set) var isolate: IsolateTrack

    /// True while the neural pipeline is filling its lookahead buffer and the
    /// output hasn't started yet.
    private(set) var priming = false

    var onChange: (() -> Void)?

    private static let enabledKey = "globalEnabled"
    private static let karaokeKey = "globalKaraoke"          // legacy Bool
    private static let reductionKey = "vocalReduction"        // legacy string
    private static let isolateKey = "isolateTrack"

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
        if let raw = defaults.string(forKey: Self.isolateKey),
           let stored = IsolateTrack(rawValue: raw) {
            isolate = stored
        } else {
            // Migrate the older three-way mode. "best" removed the vocal, which
            // is now "only instrumental". "fast" was the mid/side approximation
            // and has no equivalent, so it lands on off rather than silently
            // opting someone into a mode that adds two seconds of latency.
            switch defaults.string(forKey: Self.reductionKey) {
            case "best": isolate = .instrumental
            default: isolate = .off
            }
        }
        if isolate.isolating && !SeparationModel.isInstalled {
            isolate = .off
        }
        // Loading is slow, so it happens off the main thread; engagement waits
        // for readiness rather than blocking on it.
        modelLoader.onChange = { [weak self] in
            guard let self else { return }
            if let error = self.modelLoader.error, self.isolate.isolating {
                self.lastError = error
            }
            self.updateEngagement()
            self.onChange?()
        }
        if isolate.isolating { modelLoader.prepare() }

        modelInstaller.onChange = { [weak self] in
            guard let self else { return }
            if case .installed = self.modelInstaller.state,
               let wanted = self.wantedModeWhenInstalled {
                self.wantedModeWhenInstalled = nil
                self.setIsolate(wanted)
            }
            self.onChange?()
        }
    }

    /// Downloads the separation model, then switches to the mode the user was
    /// reaching for — they asked for the mode, not for a file.
    func downloadModel(then mode: IsolateTrack = .instrumental) {
        guard !SeparationModel.isInstalled else { return }
        wantedModeWhenInstalled = mode
        lastError = nil
        modelInstaller.start()
        onChange?()
    }

    func cancelModelDownload() {
        wantedModeWhenInstalled = nil
        modelInstaller.cancel()
        onChange?()
    }

    /// True while the model is still loading and "Best" is selected — the UI
    /// shows this rather than looking broken during a cold load.
    var preparingModel: Bool { isolate.isolating && modelLoader.isLoading }

    private var currentTrackID: String?
    private var hasTrack = false
    private var spotifyPlaying = false
    private var spotifyRunning = false
    private var permissionDenied = false
    private var lastError: String?

    private var capture: AudioCapture?
    private var engine: PitchEngine?
    private var separation: SeparationEngine?
    private var separationWatchdog: DispatchSourceTimer?
    private let modelLoader = SeparationModelLoader()
    let modelInstaller = SeparationModelInstaller()
    private var wantedModeWhenInstalled: IsolateTrack?
    private let store = SongSettingsStore()

    private var disengageWork: DispatchWorkItem?
    private var reconfiguring = false

    /// A track change reaches the ears ~2 s after Spotify reports it (the
    /// separation pipeline's depth), so the new track's saved transpose must
    /// wait for its audio. `target` is the staged-frame position of the
    /// boundary; the watchdog applies `value` once consumption passes it.
    private var pendingSemitones: (target: Int, value: Int)?

    /// When set, engage/disengage drive these stubs instead of real audio —
    /// used by the headless self-test to verify the state machine.
    var testHooks: (engage: (Int, Bool) -> Void, disengage: () -> Void)?

    // MARK: - Inputs from Spotify

    func spotifyUpdate(running: Bool, playing: Bool, trackID: String?) {
        spotifyRunning = running
        spotifyPlaying = playing
        separation?.setInputGate(open: running && playing)
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
        } else {
            semitones = 0
        }
        rememberThisSong = true
        // With the separation pipeline running, the previous track is still in
        // flight; changing the key now would transpose its tail. Defer to the
        // boundary. The UI shows the new value immediately — that's the intent.
        if let separation, engaged, separation.failure == nil {
            pendingSemitones = (separation.stagedCaptureFrames, semitones)
            log.notice("transpose \(self.semitones, privacy: .public) st deferred to track boundary")
        } else {
            engine?.semitones = semitones
        }
    }

    // MARK: - User actions

    func setSemitones(_ value: Int) {
        let clamped = max(-12, min(12, value))
        guard clamped != semitones else { return }
        pendingSemitones = nil          // the user is taking over: apply now
        semitones = clamped
        engine?.semitones = clamped
        persistIfRemembering()
        updateEngagement()
        onChange?()
    }

    func nudge(_ delta: Int) { setSemitones(semitones + delta) }
    func resetPitch() { setSemitones(0) }

    func setIsolate(_ mode: IsolateTrack) {
        guard mode != isolate else { return }
        if mode.isolating && !SeparationModel.isInstalled {
            lastError = SeparationModel.installHint
            onChange?()
            return
        }
        let wasIsolating = isolate.isolating
        isolate = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.isolateKey)
        if mode.isolating {
            lastError = nil
            modelLoader.prepare()
        } else {
            modelLoader.release()   // the model is large; don't hold it idle
        }

        if engaged && wasIsolating && mode.isolating {
            // Same pipeline, different stems: no rebuild, no re-prime. The ~2 s
            // already in flight keeps whatever it was rendered as.
            separation?.setIsolateVocals(mode == .vocals)
        } else if engaged && (wasIsolating || mode.isolating) {
            // Crossing into or out of separation changes the pipeline's shape.
            disengage()
        }
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
        if semitones == 0 {
            store.remove(for: id) // don't keep a no-op entry
        } else {
            store.save(SongSetting(semitones: semitones), for: id)
        }
    }

    // MARK: - Engagement

    /// The pipeline has a reason to exist (regardless of playback state).
    private var pipelineUseful: Bool {
        guard enabled, spotifyRunning, hasTrack else { return false }
        guard semitones != 0 || isolate.isolating else { return false }
        // The separation path can't start until its model is resident. The
        // headless self-test stubs the audio out entirely, so it has no model
        // to wait for.
        if isolate.isolating && modelLoader.model == nil && testHooks == nil { return false }
        return true
    }

    private var shouldEngage: Bool { pipelineUseful && spotifyPlaying }

    /// Pause with the separation pipeline up: hold, don't tear down. Teardown
    /// would discard ~2 s of in-flight audio; holding freezes it, so resume
    /// continues from the exact sample and never re-primes.
    private var shouldHold: Bool {
        engaged && separation != nil && pipelineUseful && !spotifyPlaying
    }

    private func updateEngagement() {
        if shouldEngage {
            disengageWork?.cancel()
            disengageWork = nil
            if engaged {
                if let engine, engine.hold {
                    engine.hold = false
                    log.notice("hold released\(self.flightDescription(), privacy: .public)")
                }
            } else {
                engage()
            }
        } else if shouldHold {
            disengageWork?.cancel()
            disengageWork = nil
            if let engine, !engine.hold {
                engine.hold = true
                log.notice("""
                    held (paused with \(self.isolate.rawValue, privacy: .public) \
                    pipeline intact)\(self.flightDescription(), privacy: .public)
                    """)
            }
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
            hooks.engage(semitones, isolate.isolating)
            onChange?()
            return
        }
        do {
            let capture = AudioCapture()
            try capture.start()

            // The neural path sits between capture and pitch shifting and is
            // format-preserving, so PitchEngine just reads a different ring.
            var sourceRing = capture.ring!
            if isolate.isolating {
                guard let model = modelLoader.model else {
                    throw SeparationEngine.StartError.modelMissing
                }
                let separation = try SeparationEngine(
                    captureRate: capture.sampleRate,
                    channels: capture.channelCount,
                    inputRing: capture.ring,
                    model: model)
                separation.setIsolateVocals(isolate == .vocals)
                separation.start()
                self.separation = separation
                sourceRing = separation.outputRing
                priming = true
                startSeparationWatchdog()
            }

            let engine = PitchEngine(sampleRate: capture.sampleRate,
                                     channels: capture.channelCount, ring: sourceRing)
            engine.semitones = semitones
            engine.onConfigurationChange = { [weak self] in self?.reconfigure() }
            try engine.start()
            self.capture = capture
            self.engine = engine
            engaged = true
            lastError = nil
            log.notice("""
                engaged: \(capture.sampleRate, privacy: .public) Hz, \
                pitch \(self.semitones, privacy: .public) st, \
                isolate \(self.isolate.rawValue, privacy: .public)
                """)
        } catch {
            disengage()
            lastError = (error as? AudioCaptureError)?.description
                ?? (error as? SeparationEngine.StartError)?.description
                ?? "\(error)"
            log.error("engage failed: \(self.lastError ?? "", privacy: .public)")
        }
        onChange?()
    }

    /// Frames captured but not yet heard. Across a pause this must stay put:
    /// a drop between "held" and "hold released" would be audio lost inside
    /// the song, which is exactly what holding is meant to prevent.
    private func flightDescription() -> String {
        guard let separation, capture != nil else { return "" }
        let staged = separation.stagedCaptureFrames
        let consumed = separation.consumedCaptureFrames
        let rate = capture?.sampleRate ?? 48_000
        return String(format: "  [in flight %.2fs, staged %d, consumed %d]",
                      Double(staged - consumed) / rate, staged, consumed)
    }

    /// Watches the separation worker: clears `priming` once audio is flowing and
    /// surfaces a prediction failure instead of leaving the user in silence.
    private func startSeparationWatchdog() {
        separationWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, let separation = self.separation else { return }
            if let failure = separation.failure {
                self.lastError = failure
                self.priming = false
                self.disengage()
                self.onChange?()
                return
            }
            if self.priming && separation.outputRing.availableToRead > 0 {
                self.priming = false
                self.onChange?()
            }
            if let pending = self.pendingSemitones,
               separation.consumedCaptureFrames >= pending.target {
                self.pendingSemitones = nil
                self.engine?.semitones = pending.value
                log.notice("deferred transpose \(pending.value, privacy: .public) st applied at track boundary")
            }
        }
        separationWatchdog = timer
        timer.resume()
    }

    private func disengage() {
        let wasEngaged = engaged
        if let hooks = testHooks {
            engaged = false
            if wasEngaged { hooks.disengage() }
            onChange?()
            return
        }
        separationWatchdog?.cancel(); separationWatchdog = nil
        engine?.stop(); engine = nil
        // Stop the worker before the capture ring it reads from goes away.
        separation?.stop(); separation = nil
        capture?.stop(); capture = nil
        priming = false
        pendingSemitones = nil   // next engage seeds engine.semitones directly
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
        if semitones != 0 || isolate.isolating, !engaged,
           let error = lastError, spotifyPlaying {
            return .error(error)
        }
        if !spotifyPlaying { return .paused }
        if semitones != 0 { return .shifting(semitones) }
        if isolate.isolating { return .isolating }
        return .original
    }
}
