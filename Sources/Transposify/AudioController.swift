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
/// always the stem mask, and a preset is simply the name of a common one.
/// `custom` is the odd one out — it selects nothing, it only reveals the
/// per-stem controls.
enum IsolatePreset: String, CaseIterable {
    case all, vocals, backing, custom

    var title: String {
        switch self {
        case .all: return "All"
        case .vocals: return "Vocals"
        case .backing: return "Backing"
        case .custom: return "Custom"
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

    /// Which preset is highlighted. Derived state for the UI — the stem mask
    /// below is what actually drives the audio.
    private(set) var preset: IsolatePreset

    /// The single source of truth: which stems reach the output.
    private(set) var stemMask: Int
    /// How many stems existed when `stemMask` was last saved. A model with more
    /// stems turns the new ones on rather than leaving them silently off — the
    /// user never unchecked something that did not exist.
    private var knownStemCount: Int

    /// How many stems the installed model actually has. Four until a six-stem
    /// model is loaded; the extra checkboxes stay hidden until then.
    var stemCount: Int { modelLoader.stemCount ?? 4 }

    /// True while the neural pipeline is filling its lookahead buffer and the
    /// output hasn't started yet.
    private(set) var priming = false

    var onChange: (() -> Void)?

    private static let enabledKey = "globalEnabled"
    private static let karaokeKey = "globalKaraoke"          // legacy Bool
    private static let reductionKey = "vocalReduction"        // legacy string
    private static let isolateKey = "isolateTrack"
    private static let advancedKey = "advancedStems"
    private static let stemMaskKey = "stemMask"
    private static let stemMaskCountKey = "stemMaskCount"

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
        // Migrate: before presets and stems were unified, the audible state was
        // either `isolateTrack` (simple) or `stemMask` (advanced), depending on
        // an `advanced` flag. Collapse that into a single mask.
        let wasAdvanced = defaults.bool(forKey: Self.advancedKey)
        let storedMask = defaults.object(forKey: Self.stemMaskKey) as? Int
        let allFour = StemSelection.mask([0, 1, 2, 3])
        if wasAdvanced, let storedMask {
            stemMask = storedMask
            preset = .custom
        } else {
            switch defaults.string(forKey: Self.isolateKey) {
            case "vocals":
                stemMask = 1 << Stem.vocalsIndex
                preset = .vocals
            case "instrumental":
                stemMask = allFour & ~(1 << Stem.vocalsIndex)
                preset = .backing
            default:
                stemMask = allFour
                preset = .all
            }
        }
        knownStemCount = defaults.object(forKey: Self.stemMaskCountKey) as? Int ?? 4
        if preset != .all && !SeparationModel.isInstalled {
            stemMask = allFour
            preset = .all
        }
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
    func downloadModel(then wanted: IsolatePreset = .backing) {
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
    var needsModel: Bool { !currentSelection.isPassthrough || preset == .custom }

    var preparingModel: Bool { needsModel && modelLoader.isLoading }

    /// Per-stem controls are showing.
    var showsStems: Bool { preset == .custom }

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
    private var wantedModeWhenInstalled: IsolatePreset?
    private let store = SongSettingsStore()

    private var disengageWork: DispatchWorkItem?
    private var reconfiguring = false

    /// A track change reaches the ears ~0.6 s after Spotify reports it (the
    /// separation pipeline's depth), so the new track's saved transpose must
    /// wait for its audio. `target` is the staged-frame position of the
    /// boundary; the watchdog applies `value` once consumption passes it.
    private var pendingSemitones: (target: Int, value: Int)?
    private var lastUnderrunLog = 0

    /// Buffered audio to build before letting playback start, in ring floats.
    /// Sized to comfortably exceed one inference, since switching modes shifts
    /// production later by exactly that much.
    private var cushionFloats: Int {
        let inference = SeparationModelLoader.measuredInference
            ?? SeparationEngine.assumedInferenceSeconds
        let seconds = max(0.15, inference * 1.5)
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

    /// Choose a preset. `custom` only reveals the per-stem controls; it never
    /// changes what you hear, so opening it is always safe.
    func setPreset(_ new: IsolatePreset) {
        if new != .all && !SeparationModel.isInstalled {
            lastError = SeparationModel.installHint
            onChange?()
            return
        }
        preset = new
        let available = (1 << stemCount) - 1
        switch new {
        case .all: stemMask = available
        case .vocals: stemMask = 1 << Stem.vocalsIndex
        case .backing: stemMask = available & ~(1 << Stem.vocalsIndex)
        case .custom: break          // reveal only
        }
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
        // Editing stems is what "custom" means; stay there rather than snapping
        // the highlight to whichever preset the mask happens to match.
        preset = .custom
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
        defaults.set(preset.rawValue, forKey: Self.isolateKey)
        defaults.set(preset == .custom, forKey: Self.advancedKey)
    }

    /// What the worker should emit.
    private var currentSelection: StemSelection {
        // "All" is authoritative. A mask saved when the model had four stems
        // reads as "everything except guitar and piano" against a six-stem
        // model, which would engage the pipeline to reproduce the full mix.
        if preset == .all { return .passthrough }
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
            if let engine, !engine.hold {
                engine.hold = true
                log.notice("""
                    held (paused with \(self.preset.rawValue, privacy: .public) \
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
                stems \(self.stemMask, privacy: .public) (\(self.preset.rawValue, privacy: .public))
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
            if self.priming, separation.outputRing.availableToRead >= self.cushionFloats {
                self.priming = false
                self.engine?.hold = false
                // Underruns before this point are the start-up gap, which is
                // unavoidable when the pipeline builds its buffer from empty.
                self.engine?.resetUnderruns()
                self.lastUnderrunLog = 0
                self.onChange?()
            }
            // Trace where glitches land relative to loading and switching.
            if let engine = self.engine, !self.priming {
                let n = engine.underruns
                if n > self.lastUnderrunLog {
                    log.notice("""
                        underruns \(n, privacy: .public) (+\(n - self.lastUnderrunLog, privacy: .public)) \
                        model \(self.modelLoader.model != nil, privacy: .public) \
                        worker \(separation.hasModel, privacy: .public)
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
        let underrunsAtStop = engine?.underruns ?? 0
        engine?.stop(); engine = nil
        // Stop the worker before the capture ring it reads from goes away.
        separation?.stop(); separation = nil
        capture?.stop(); capture = nil
        priming = false
        modelLoader.releaseAfterGrace()   // keep it briefly in case they return
        pendingSemitones = nil   // next engage seeds engine.semitones directly
        engaged = false
        if wasEngaged {
            log.notice("disengaged (passthrough), underruns \(underrunsAtStop, privacy: .public)")
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
