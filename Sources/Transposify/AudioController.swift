import AppKit
import os

let log = Logger(subsystem: "com.evanhu.transposify", category: "audio")

/// The stems a converted model exposes, in the order the converter emits them.
/// Vocals is index 0 in both the four- and six-stem models, deliberately, so
/// these indices stay stable across a model swap and a stored selection keeps
/// meaning the same thing.
enum Stem: Int, CaseIterable {
    case vocals, drums, bass, other, guitar, piano

    static let vocalsIndex = 0

    var title: String {
        switch self {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Other"
        case .guitar: return "Guitar"
        case .piano: return "Piano"
        }
    }
}

/// Named stem sets. These are *shortcuts*, not a separate mode: the truth is
/// always the stem mask, and a preset is simply the name of a common one. Any
/// other mask is unnamed, which is why `preset` is optional rather than having
/// a "custom" case — a case that meant "none of the above" would be a second
/// place for the truth to live.
enum MixPreset: String, CaseIterable {
    case all, vocals, backing

    var title: String {
        switch self {
        case .all: return "All"
        case .vocals: return "Vocals"
        case .backing: return "Backing"
        }
    }

    var summary: String {
        switch self {
        case .all: return "Play the mix untouched."
        case .vocals: return "Keep the vocal, drop the backing."
        case .backing: return "Remove the vocal, keep the backing."
        }
    }
}

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

    /// The single source of truth: which stems reach the output.
    private(set) var stemMask: Int
    /// How many stems existed when `stemMask` was last saved. A model with more
    /// stems turns the new ones on rather than leaving them silently off — the
    /// user never unchecked something that did not exist.
    private var knownStemCount: Int

    /// How many stems the installed model actually has. Until it loads, the
    /// count from the last session — so the tiles do not have to wait for a
    /// model the user may not even need this time.
    var stemCount: Int { modelLoader.stemCount ?? knownStemCount }

    /// The preset the current mask happens to match, or nil when it matches
    /// none. Always derived, never stored: a stored preset can fall out of step
    /// with the mask, and then the interface shows a selection the audio does
    /// not have.
    var preset: MixPreset? {
        let available = (1 << stemCount) - 1
        let mask = stemMask & available
        if mask == available { return .all }
        if mask == 1 << Stem.vocalsIndex { return .vocals }
        if mask == available & ~(1 << Stem.vocalsIndex) { return .backing }
        return nil
    }

    /// The mask a preset stands for, at the current stem count.
    func mask(for preset: MixPreset) -> Int {
        let available = (1 << stemCount) - 1
        switch preset {
        case .all: return available
        case .vocals: return 1 << Stem.vocalsIndex
        case .backing: return available & ~(1 << Stem.vocalsIndex)
        }
    }

    /// True while the neural pipeline is filling its lookahead buffer and the
    /// output hasn't started yet.
    private(set) var priming = false

    var onChange: (() -> Void)?

    private static let enabledKey = "globalEnabled"
    private static let karaokeKey = "globalKaraoke"          // legacy Bool
    private static let reductionKey = "vocalReduction"        // legacy string
    private static let isolateKey = "isolateTrack"       // legacy, read once
    private static let advancedKey = "advancedStems"     // legacy Bool, unused
    private static let stemMaskKey = "stemMask"
    private static let stemMaskCountKey = "stemMaskCount"

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
        knownStemCount = defaults.object(forKey: Self.stemMaskCountKey) as? Int ?? 4
        let available = (1 << knownStemCount) - 1
        // The mask is the whole of the saved state. `isolateTrack` is the older
        // named-mode setting, read once for anyone upgrading and never written.
        if let stored = defaults.object(forKey: Self.stemMaskKey) as? Int {
            stemMask = stored
        } else {
            switch defaults.string(forKey: Self.isolateKey) {
            case "vocals": stemMask = 1 << Stem.vocalsIndex
            case "instrumental": stemMask = available & ~(1 << Stem.vocalsIndex)
            default: stemMask = available
            }
        }
        // Nothing can be dropped without the model, so start on the full mix
        // rather than showing a selection that silently is not happening.
        if !SeparationModel.isInstalled { stemMask = available }
        // Loading is slow, so it happens off the main thread; engagement waits
        // for readiness rather than blocking on it.
        modelLoader.onChange = { [weak self] in
            guard let self else { return }
            if let error = self.modelLoader.error, self.needsModel {
                self.lastError = error
            }
            self.adoptNewStemsIfAny()
            // Late arrival: the worker picks it up at the next hop boundary.
            self.separation?.setModel(self.modelLoader.model)
            self.applySelection()
            self.updateEngagement()
            self.onChange?()
        }
        if needsModel { modelLoader.prepare() }

        modelInstaller.onChange = { [weak self] in
            guard let self else { return }
            if case .installed = self.modelInstaller.state,
               let wanted = self.wantedModeWhenInstalled {
                self.wantedModeWhenInstalled = nil
                self.setPreset(wanted)
            }
            self.onChange?()
        }
    }

    /// Downloads the separation model, then switches to the mode the user was
    /// reaching for — they asked for the mode, not for a file.
    func downloadModel(then wanted: MixPreset = .backing) {
        guard !SeparationModel.isInstalled else { return }
        wantedModeWhenInstalled = wanted
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
    /// The model is only needed when some stem is actually being dropped.
    var needsModel: Bool { !currentSelection.isPassthrough }

    var preparingModel: Bool { needsModel && modelLoader.isLoading }

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
    private var wantedModeWhenInstalled: MixPreset?
    private let store = SongSettingsStore()

    private var disengageWork: DispatchWorkItem?
    /// Running with nothing to do, waiting for a track boundary to stand down.
    private var coasting = false
    private var reconfiguring = false

    /// A track change reaches the ears ~0.6 s after Spotify reports it (the
    /// separation pipeline's depth), so the new track's saved transpose must
    /// wait for its audio. `target` is the staged-frame position of the
    /// boundary; the watchdog applies `value` once consumption passes it.
    private var pendingSemitones: (target: Int, value: Int)?
    private var lastUnderrunLog = 0

    /// Buffered audio to build before letting playback start, in ring floats.
    ///
    /// This is the floor under the output ring, and it is what a mode switch
    /// spends. Switching a full mix to a separated one turns a hop that cost
    /// nothing into one that costs an inference, so production lands one
    /// inference later and the ring drains by exactly that much. If the floor
    /// is thinner than the worst hop, that switch is audible.
    ///
    /// Two terms, because two different things go wrong. `inference * 1.5`
    /// covers slow hardware, where inference dominates. The `+ 0.12` covers
    /// fast hardware, where inference is small but ordinary scheduling jitter
    /// is not — a 105 ms inference with a 1.5 multiplier leaves only ~50 ms of
    /// absolute headroom, which one late thread wake-up eats. The floor costs
    /// latency, so it is the smallest number that survives both.
    private var cushionFloats: Int {
        let inference = SeparationModelLoader.measuredInference
            ?? SeparationEngine.assumedInferenceSeconds
        let seconds = max(0.15, max(inference * 1.5, inference + 0.12))
        let rate = capture?.sampleRate ?? 48_000
        let channels = capture?.channelCount ?? 2
        return Int(seconds * rate) * channels
    }

    /// When set, engage/disengage drive these stubs instead of real audio —
    /// used by the headless self-test to verify the state machine.
    var testHooks: (engage: (Int, Bool) -> Void, disengage: () -> Void)?

    // MARK: - Inputs from Spotify

    func spotifyUpdate(running: Bool, playing: Bool, trackID: String?) {
        spotifyRunning = running
        spotifyPlaying = playing
        separation?.setInputGate(open: running && playing)
        let trackChanged = trackID != currentTrackID
        if trackChanged {
            currentTrackID = trackID
            hasTrack = trackID != nil
            loadSettingForCurrentTrack()
        }
        // A coasting pipeline gives its latency back here, and only here: at a
        // track change the audio is already discontinuous, so the ~0.6 s that
        // teardown costs lands on a boundary instead of mid-phrase. If the new
        // track has a saved transpose, the pipeline is useful again and stays.
        if trackChanged && engaged && !pipelineUseful {
            log.notice("standing down at track boundary")
            disengage()
        } else {
            updateEngagement()
        }
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

    /// Choose a preset — a shortcut for setting the mask to a common value.
    func setPreset(_ new: MixPreset) {
        if new != .all && !SeparationModel.isInstalled {
            lastError = SeparationModel.installHint
            onChange?()
            return
        }
        stemMask = mask(for: new)
        persistSelection()
        if needsModel { lastError = nil; modelLoader.prepare() } else { releaseModelIfIdle() }
        applySelection()
        updateEngagement()
        onChange?()
    }

    func setStem(_ stem: Stem, included: Bool) {
        let bit = 1 << stem.rawValue
        let updated = included ? (stemMask | bit) : (stemMask & ~bit)
        guard updated != stemMask else { return }
        stemMask = updated
        persistSelection()
        if needsModel { modelLoader.prepare() }
        applySelection()
        updateEngagement()
        onChange?()
    }

    func includes(_ stem: Stem) -> Bool { stemMask & (1 << stem.rawValue) != 0 }

    private func persistSelection() {
        let defaults = UserDefaults.standard
        defaults.set(stemMask, forKey: Self.stemMaskKey)
        defaults.set(stemCount, forKey: Self.stemMaskCountKey)
    }

    /// What the worker should emit.
    private var currentSelection: StemSelection {
        let available = (1 << stemCount) - 1
        let mask = stemMask & available
        // Everything selected is the untouched mix, which passthrough gives
        // bit-exact and without running the model at all.
        return mask == available ? .passthrough : .stems(mask: mask)
    }

    private func applySelection() {
        separation?.setSelection(currentSelection)
    }

    /// A model with more stems than the saved selection knew about turns the
    /// new ones on — the user never unchecked something that did not exist.
    private func adoptNewStemsIfAny() {
        let count = stemCount
        guard count > knownStemCount else { return }
        for index in knownStemCount..<count { stemMask |= (1 << index) }
        knownStemCount = count
        persistSelection()
        log.notice("stem selection extended to \(count, privacy: .public) stems")
    }

    private func releaseModelIfIdle() {
        if !needsModel { modelLoader.releaseAfterGrace() }
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
        // Advanced with every stem checked is the untouched mix, so it is not
        // a reason to engage — the tap would mute Spotify to hand back what
        // Spotify was already playing.
        // A full mix is not a reason to engage: the tap would mute Spotify to
        // hand back what Spotify was already playing.
        guard semitones != 0 || !currentSelection.isPassthrough else { return false }
        // The separation path can't start until its model is resident. The
        // headless self-test stubs the audio out entirely, so it has no model
        // to wait for.
        // Passthrough needs no model, so engagement never waits on one.
        return true
    }

    private var shouldEngage: Bool { pipelineUseful && spotifyPlaying }

    /// Paused with the pipeline up: hold, don't tear down. Teardown would
    /// discard the ~0.6 s in flight — audio the listener has not heard yet,
    /// and which Spotify will not replay, because it resumes from its own
    /// playhead. Holding freezes it, so resume continues from the exact sample.
    ///
    /// This deliberately does not ask whether the pipeline is still *useful*.
    /// A paused pipeline costs nothing to keep — no GPU, no audible mute — and
    /// standing down here would be the one stand-down that loses audio.
    private var shouldHold: Bool {
        engaged && separation != nil && enabled && spotifyRunning && !spotifyPlaying
    }

    /// Nothing needs the pipeline — a full mix at zero semitones — but audio is
    /// playing and the pipeline is already up.
    ///
    /// Standing down here is not free. About 0.6 s is in flight; dropping it
    /// hands the listener Spotify's live position instead, which is a jump
    /// forward mid-phrase, and coming back costs the same jump in reverse.
    /// That is exactly what made switching between mixes feel disconnected.
    ///
    /// So coast: keep running, which in a full mix means passthrough — the
    /// same window and hop machinery with no inference at all — and stand down
    /// at the next track change, the one moment during playback where the
    /// audio is already discontinuous.
    private var canCoast: Bool {
        engaged && enabled && spotifyRunning && spotifyPlaying && hasTrack
            && separation?.failure == nil
    }

    private func updateEngagement() {
        if shouldEngage {
            disengageWork?.cancel()
            disengageWork = nil
            coasting = false
            if engaged {
                if let engine, engine.hold, !priming {
                    engine.hold = false
                    log.notice("hold released\(self.flightDescription(), privacy: .public)")
                }
            } else {
                engage()
            }
        } else if shouldHold {
            disengageWork?.cancel()
            disengageWork = nil
            coasting = false
            if let engine, !engine.hold {
                engine.hold = true
                log.notice("""
                    held (paused with \(self.preset?.rawValue ?? "custom", privacy: .public) \
                    pipeline intact)\(self.flightDescription(), privacy: .public)
                    """)
            }
        } else if canCoast {
            disengageWork?.cancel()
            disengageWork = nil
            if !coasting {
                coasting = true
                log.notice("""
                    coasting: nothing to separate, staying up so switching back \
                    costs no jump\(self.flightDescription(), privacy: .public)
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
            hooks.engage(semitones, !currentSelection.isPassthrough)
            onChange?()
            return
        }
        do {
            let capture = AudioCapture()
            try capture.start()

            // The neural path sits between capture and pitch shifting and is
            // format-preserving, so PitchEngine just reads a different ring.
            // The separation stage runs in every mode, even Off, where it is
            // just a delay line and costs no GPU. That uniform delay is what
            // makes switching seamless: without it, going from a live stream to
            // a delayed one has to gap, repeat, or bend time.
            let separation = try SeparationEngine(
                captureRate: capture.sampleRate,
                channels: capture.channelCount,
                inputRing: capture.ring,
                model: modelLoader.model)
            log.notice("""
                pipeline: hop \(String(format: "%.2f", separation.hopSeconds), privacy: .public)s \
                delay \(String(format: "%.2f", separation.nominalDelay), privacy: .public)s \
                (inference \(String(format: "%.0f", (SeparationModelLoader.measuredInference ?? 0) * 1000), privacy: .public) ms)
                """)
            separation.setSelection(currentSelection)
            separation.start()
            self.separation = separation
            let sourceRing = separation.outputRing
            priming = true
            startSeparationWatchdog()

            let engine = PitchEngine(sampleRate: capture.sampleRate,
                                     channels: capture.channelCount, ring: sourceRing)
            engine.semitones = semitones
            engine.onConfigurationChange = { [weak self] in self?.reconfigure() }
            // Hold output until a cushion of audio exists. Releasing as soon as
            // the ring is merely non-empty leaves no floor, so every hiccup —
            // the switch from passthrough to separation especially, which
            // shifts production later by one inference — empties it and drops
            // samples. The cushion is the floor that absorbs them.
            engine.hold = true
            try engine.start()
            self.capture = capture
            self.engine = engine
            engaged = true
            lastError = nil
            log.notice("""
                engaged: \(capture.sampleRate, privacy: .public) Hz, \
                pitch \(self.semitones, privacy: .public) st, \
                stems \(self.stemMask, privacy: .public) (\(self.preset?.rawValue ?? "custom", privacy: .public))
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

    /// How much room the output ring has had, and what the slowest hop cost.
    /// A mode switch spends one hop's worth of the first; if the two numbers
    /// converge, switching is about to be audible.
    private func marginDescription(_ separation: SeparationEngine) -> String {
        let rate = capture?.sampleRate ?? 48_000
        let frames = separation.minOutputFrames
        let cushion = frames == Int.max ? -1 : Int(Double(frames) / rate * 1000)
        return "min cushion \(cushion) ms, worst hop \(Int(separation.maxStepSeconds * 1000)) ms"
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
            if self.priming, separation.outputRing.availableToRead >= self.cushionFloats {
                self.priming = false
                self.engine?.hold = false
                // Underruns before this point are the start-up gap, which is
                // unavoidable when the pipeline builds its buffer from empty.
                self.engine?.resetUnderruns()
                self.lastUnderrunLog = 0
                // Margins measured during priming describe the ramp, not the
                // steady state that mode switching has to survive.
                separation.resetMargins()
                self.onChange?()
            }
            // Trace where glitches land relative to loading and switching.
            if let engine = self.engine, !self.priming {
                let n = engine.underruns
                if n > self.lastUnderrunLog {
                    log.notice("""
                        underruns \(n, privacy: .public) (+\(n - self.lastUnderrunLog, privacy: .public)) \
                        model \(self.modelLoader.model != nil, privacy: .public) \
                        worker \(separation.hasModel, privacy: .public) \
                        \(self.marginDescription(separation), privacy: .public)
                        """)
                    self.lastUnderrunLog = n
                }
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
        let captureRateAtStop = capture?.sampleRate ?? 48_000
        let underrunsAtStop = engine?.underruns ?? 0
        let margin = separation.map {
            (frames: $0.minOutputFrames, step: $0.maxStepSeconds)
        }
        engine?.stop(); engine = nil
        // Stop the worker before the capture ring it reads from goes away.
        separation?.stop(); separation = nil
        capture?.stop(); capture = nil
        priming = false
        coasting = false
        modelLoader.releaseAfterGrace()   // keep it briefly in case they return
        pendingSemitones = nil   // next engage seeds engine.semitones directly
        engaged = false
        if wasEngaged {
            let rate = captureRateAtStop
            let cushionMs = margin.map { $0.frames == Int.max ? -1 : Int(Double($0.frames) / rate * 1000) } ?? -1
            let stepMs = margin.map { Int($0.step * 1000) } ?? 0
            log.notice("""
                disengaged (passthrough), underruns \(underrunsAtStop, privacy: .public), \
                min cushion \(cushionMs, privacy: .public) ms, worst hop \(stepMs, privacy: .public) ms
                """)
        }
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
        if !currentSelection.isPassthrough || semitones != 0, !engaged,
           let error = lastError, spotifyPlaying {
            return .error(error)
        }
        if !spotifyPlaying { return .paused }
        if semitones != 0 { return .shifting(semitones) }
        if !currentSelection.isPassthrough { return .isolating }
        return .original
    }
}
