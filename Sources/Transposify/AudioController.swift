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

/// What to do with the singer's formants when the key moves.
///
/// Shifting a voice down carries its whole spectral envelope down with it,
/// which is why a pitched-down singer sounds like a larger one. Rubber Band
/// can estimate that envelope and hold it in place — and, past that, lift it
/// further, which is worth a try because the estimate comes from the whole
/// mix rather than the voice alone and tends to under-correct.
enum FormantMode: String, CaseIterable {
    case off, natural, split

    var title: String {
        switch self {
        case .off: return "Off"
        case .natural: return "Natural"
        case .split: return "Split"
        }
    }

    var summary: String {
        switch self {
        case .off: return "Let the voice move with the key. Lower sounds larger."
        case .natural: return "Hold the singer's tone, judged from the whole mix."
        case .split: return "Separate the voice out and hold its tone on its own. "
                + "Needs the model, and runs it even for a full mix."
        }
    }

    /// nil lets the formants move with the pitch.
    var over: Double? {
        switch self {
        case .off: return nil
        case .natural, .split: return 1.0
        }
    }

    var isSplit: Bool { self == .split }
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

    /// How much of the singer's tone to hold on to when the key moves.
    /// Persisted; see `PitchEngine.formantOver` for what each one does.
    private(set) var formantMode: FormantMode
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

    /// The capture position the listener has to reach before a mix change is
    /// what they are hearing. Set on the click, cleared by the watchdog.
    private var mixTarget: Int?

    /// The ears have not caught up with the controls. Three things cause it: a
    /// cold model load, the pipeline filling its buffer, and a mix change
    /// travelling the pipeline's delay. All three are seconds long, and
    /// without a signal the click that started them reads as ignored.
    ///
    /// Only while playing: nothing travels a stopped pipeline, so a change made
    /// while paused is not late, it is simply waiting.
    var catchingUp: Bool {
        preparingModel || ((priming || mixTarget != nil) && spotifyPlaying)
    }

    var onChange: (() -> Void)?

    private static let enabledKey = "globalEnabled"
    private static let karaokeKey = "globalKaraoke"          // legacy Bool
    private static let reductionKey = "vocalReduction"        // legacy string
    private static let isolateKey = "isolateTrack"       // legacy, read once
    private static let advancedKey = "advancedStems"     // legacy Bool, unused
    private static let formantKey = "formantMode"
    private static let stemMaskKey = "stemMask"
    private static let stemMaskCountKey = "stemMaskCount"

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
        formantMode = ProcessInfo.processInfo.environment["TRANSPOSIFY_FORMANT"]
            .flatMap(FormantMode.init(rawValue:))
            ?? defaults.string(forKey: Self.formantKey)
                .flatMap(FormantMode.init(rawValue:)) ?? .natural
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
            // A model with another window cannot be adopted in place; the
            // pipeline is rebuilt around it instead.
            if let separation = self.separation,
               !separation.setModel(self.modelLoader.model) {
                self.reconfigure()
            }
            if self.modelLoader.model != nil, self.engaged {
                self.stepsSettleAt = Date().addingTimeInterval(3)
                self.stepsSettled = false
            }
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
    var needsModel: Bool { !currentSelection.isPassthrough || formantMode.isSplit }

    var preparingModel: Bool { needsModel && modelLoader.isLoading }
    var modelReadyForSimulation: Bool { modelLoader.model != nil }

    /// True while playback is stopped because the model is still loading.
    private(set) var pausedForModelLoad = false
    /// This load has already had its one pause. Without it, a user who presses
    /// play mid-load gets paused again on the very next update.
    private var modelLoadPauseSpent = false
    private var resumeWork: DispatchWorkItem?

    private var currentTrackID: String?
    private var hasTrack = false
    private var spotifyPlaying = false
    private var spotifyRunning = false
    private var permissionDenied = false
    private var lastError: String?

    private var capture: AudioSource?
    private var engine: PitchEngine?
    private var separation: SeparationEngine?
    private var recorder: SessionRecorder?
    private var separationWatchdog: DispatchSourceTimer?
    private let modelLoader = SeparationModelLoader()
    let modelInstaller = SeparationModelInstaller()
    private var wantedModeWhenInstalled: MixPreset?
    private let store = SongSettingsStore()

    private var disengageWork: DispatchWorkItem?
    /// Running with nothing to do, waiting for a track boundary to stand down.
    private var coasting = false
    private var reconfiguring = false

    /// Headless simulation injects a file-backed source and manual output.
    var audioSourceFactory: ((SessionRecorder?) throws -> AudioSource)?
    var simulationMode = false

    /// A track change reaches the ears ~0.6 s after Spotify reports it (the
    /// separation pipeline's depth), so the new track's saved transpose must
    /// wait for its audio. `target` is the staged-frame position of the
    /// boundary; the watchdog applies `value` once consumption passes it.
    private var pendingSemitones: (target: Int, value: Int)?
    private var lastUnderrunLog = 0
    /// Watchdog ticks since engaging, so the depth log stays sparse.
    private var depthTicks = 0

    /// Buffered audio to build before letting playback start, in ring floats.
    ///
    /// This is the floor under the output ring, and it has to cover one whole
    /// step: if a step takes longer than the ring holds, the render side plays
    /// silence, and that silence is never given back — the delay grows by
    /// exactly its length and stays grown. Every underrun is a permanent
    /// deepening, so the ring is sized against the *slowest* step measured on
    /// this machine, not the median one.
    ///
    /// It used to be sized from median inference, which on this Mac asked for
    /// 228 ms against steps that reached 362 ms. The pipeline then drifted from
    /// 0.7 s to 1.7 s over a few minutes of listening, one underrun at a time.
    /// Buying the tail up front is cheaper than paying for it in drift.
    private var cushionSeconds: Double {
        if let value = ProcessInfo.processInfo.environment["TRANSPOSIFY_CUSHION"],
           let override = Double(value) { return max(0, override) }
        let inference = SeparationModelLoader.measuredInference
            ?? SeparationEngine.assumedInferenceSeconds
        // Before the first measurement, assume a tail at three times the
        // median: the GPU's bursts run that far above it when borrowed.
        let worstStep = SeparationEngine.measuredWorstStep ?? (inference * 3.0)
        // The extra 50 ms is the wake-up that follows a late step; without it
        // the ring is exactly empty at the worst moment rather than nearly so.
        return max(0.15, min(worstStep, Self.cushionCap) + 0.05)
    }

    /// The most step the cushion will cover. The governor gives back the time
    /// an underrun inserts, so a step past this costs one short click and
    /// nothing after it — whereas covering it costs every later session that
    /// much delay. A single 520 ms step, seen once after a cold load, would
    /// otherwise have bought 300 ms of permanent latency.
    static let cushionCap = 0.35

    /// When the worker's margins start to count. The first predictions after
    /// a load follow the warm-up's back-to-back runs, which leave the GPU in
    /// its slow state, and the first after an engage follow a burst of
    /// catch-up steps. Neither describes the steady state the cushion is for.
    private var stepsSettleAt: Date?
    private var stepsSettled = false

    /// Ring occupancy that ends priming, in floats. Fixed at engage: it
    /// decides when playback starts, so it must not move underneath a
    /// pipeline that is already filling.
    ///
    /// This is the cushion *plus one hop*, and the hop is not optional. The
    /// first publish leaves exactly one hop in the ring and nothing in
    /// staging; the next step cannot begin until a further hop of input has
    /// arrived, and the ring drains by that whole hop while it waits. Release
    /// on the cushion alone and the second step starts against an empty ring,
    /// so its prediction time is an underrun every single time — the clip the
    /// listener hears a second after every switch. Waiting for the second
    /// publish costs no latency the design did not already budget: the target
    /// depth is `hop + lookahead + cushion`, and this is the moment the ring
    /// first holds it.
    private var primeFloats = 0
    /// What the pipeline's depth should be, in seconds, set at engage.
    private var targetDepth = 0.0
    /// Playback speed the governor is asking for, 1.0 when it is idle.
    private var governorRatio = 1.0

    // MARK: - The depth governor

    /// Two things deepen the pipeline and neither reverses on its own. An
    /// underrun plays silence the listener never gets back, so the audio behind
    /// it lands later, for good. A pause keeps the audio captured just before
    /// it — real song content, worth keeping — but that audio has to go
    /// somewhere, and where it goes is the delay. Both are one-way, and a
    /// listening session with a few dozen of either drifts from 0.7 s to 1.7 s.
    ///
    /// Neither is a bug to remove: dropping the silence or the pre-pause audio
    /// would mean losing audio, which this pipeline never does. So give the
    /// time back instead of the audio. Playing 1.5% fast for twenty seconds
    /// returns 300 ms with no gap, no repeat, and no change in pitch.
    private static let governorSlack = 0.08      // ignore drift below this
    private static let governorGentle = 0.985    // 1.5% fast
    private static let governorBrisk = 0.97      // 3% fast, past half a second
    /// Watchdog ticks (0.25 s) a reading must persist before the governor
    /// acts on it. A ratio change makes Rubber Band pull a chunk from the ring
    /// as it re-buffers, and that dip looked like "back at target" — so the
    /// governor released, the ring refilled, and it engaged again, four times a
    /// second. Agreement over a second is what a real change looks like.
    private static let governorEngageTicks = 2
    private static let governorReleaseTicks = 4
    private var governorAgreeTicks = 0
    private var governorProposed = 1.0

    private func updateGovernor(_ separation: SeparationEngine) {
        if ProcessInfo.processInfo.environment["TRANSPOSIFY_GOVERNOR"] == "0" {
            if governorRatio != 1.0 { releaseGovernor(depth: nil) }
            return
        }
        guard let engine, !priming, spotifyPlaying, targetDepth > 0 else {
            if governorRatio != 1.0 { releaseGovernor(depth: nil) }
            governorAgreeTicks = 0
            return
        }
        let rate = capture?.sampleRate ?? 48_000
        let depth = Double(separation.stagedCaptureFrames
            - separation.consumedCaptureFrames) / rate
        let excess = depth - targetDepth

        let wanted: Double
        if excess > 0.5 {
            wanted = Self.governorBrisk
        } else if excess > Self.governorSlack {
            wanted = Self.governorGentle
        } else if excess < 0.02 {
            wanted = 1.0
        } else {
            wanted = governorRatio          // hysteresis: finish what we started
        }
        if wanted == governorRatio { governorAgreeTicks = 0; governorProposed = wanted; return }
        // A new proposal has to hold for a while before it is acted on.
        if wanted == governorProposed {
            governorAgreeTicks += 1
        } else {
            governorProposed = wanted
            governorAgreeTicks = 1
        }
        let needed = wanted == 1.0 ? Self.governorReleaseTicks : Self.governorEngageTicks
        guard governorAgreeTicks >= needed else { return }
        governorAgreeTicks = 0
        if wanted == 1.0 {
            releaseGovernor(depth: depth)
        } else {
            governorRatio = wanted
            engine.timeRatio = wanted
            recorder?.governor(ratio: wanted, depth: depth, target: targetDepth)
            log.notice("""
                governor \(String(format: "%.1f", (1 - wanted) * 100), privacy: .public)% fast: \
                depth \(String(format: "%.2f", depth), privacy: .public)s vs target \
                \(String(format: "%.2f", self.targetDepth), privacy: .public)s
                """)
        }
    }

    private func releaseGovernor(depth: Double?) {
        governorRatio = 1.0
        engine?.timeRatio = 1.0
        recorder?.governor(ratio: 1.0, depth: depth, target: targetDepth)
        let at = depth.map { String(format: " at %.2fs", $0) } ?? ""
        log.notice("governor released\(at, privacy: .public)")
    }

    /// When set, engage/disengage drive these stubs instead of real audio —
    /// used by the headless self-test to verify the state machine.
    var testHooks: (engage: (Int, Bool) -> Void, disengage: () -> Void)?

    /// Tells Spotify to play or pause, and reports whether the command landed.
    /// The app delegate wires this to `SpotifyState`; it is nil in tests.
    var setSpotifyPlaying: ((Bool) -> Bool)?

    // MARK: - Inputs from Spotify

    func spotifyUpdate(running: Bool, playing: Bool, trackID: String?) {
        spotifyRunning = running
        spotifyPlaying = playing
        separation?.setInputGate(open: running && playing)
        let trackChanged = trackID != currentTrackID
        if trackChanged {
            currentTrackID = trackID
            hasTrack = trackID != nil
            recorder?.track(trackID)
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
        let wasSplit = splitActive
        pendingSemitones = nil          // the user is taking over: apply now
        semitones = clamped
        engine?.semitones = clamped
        // Split only exists while the key is actually moving, so crossing zero
        // adds or removes the vocal path, which is built at engage.
        if splitActive != wasSplit {
            applySelection()
            if engaged { reconfigure() }
        }
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
        noteMixChange()
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
        noteMixChange()
        updateEngagement()
        onChange?()
    }

    func includes(_ stem: Stem) -> Bool { stemMask & (1 << stem.rawValue) != 0 }

    private func persistSelection() {
        guard !simulationMode else { return }
        let defaults = UserDefaults.standard
        defaults.set(stemMask, forKey: Self.stemMaskKey)
        defaults.set(stemCount, forKey: Self.stemMaskCountKey)
    }

    /// True when the vocal is pitched on its own path. It needs the model and
    /// a key change to be worth anything, and falls back quietly without them.
    var splitActive: Bool {
        formantMode.isSplit && SeparationModel.isInstalled && semitones != 0
    }

    /// What the worker should emit.
    private var currentSelection: StemSelection {
        let available = (1 << stemCount) - 1
        let mask = stemMask & available
        // Everything selected is the untouched mix, which passthrough gives
        // bit-exact and without running the model at all — unless the vocal
        // has to come out separately, which takes a prediction.
        if mask == available { return splitActive ? .stems(mask: mask) : .passthrough }
        return .stems(mask: mask)
    }

    private func applySelection() {
        separation?.setSelection(currentSelection)
        separation?.setSplitVocal(splitActive)
        recorder?.selection(stemMask: stemMask, passthrough: currentSelection.isPassthrough)
    }

    /// Remember where the listener has to get to before a mix change is what
    /// they are hearing; the watchdog says when they are there.
    ///
    /// Two waits, in order. The block being predicted right now still carries
    /// the old mix, so the change reaches the ring one hop after production
    /// stands — and the ears one ring-drain after that. Together that is the
    /// second and a half between the click and the vocal going away.
    ///
    /// With no pipeline up, engaging is the wait, and `priming` already covers
    /// it — a target taken now would be against a ring that does not exist.
    private func noteMixChange() {
        guard let separation, engaged, separation.failure == nil else { return }
        mixTarget = separation.publishedCaptureFrames + separation.hopCaptureFrames
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

    func setFormantMode(_ mode: FormantMode) {
        guard mode != formantMode else { return }
        let wasSplit = splitActive
        formantMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.formantKey)
        log.notice("formant mode \(mode.rawValue, privacy: .public)")
        if splitActive != wasSplit {
            // The vocal path is built at engage, so turning it on or off
            // rebuilds the pipeline. Everything else applies in place.
            if needsModel { modelLoader.prepare() }
            applySelection()
            if engaged { reconfigure() } else { updateEngagement() }
        } else {
            engine?.formantOver = mode.over
        }
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
        // Quitting with the music stopped by us would leave it stopped.
        if pausedForModelLoad { resumeAfterModelLoad() }
        disengage()
        recorder?.finish(); recorder = nil
    }

    private func persistIfRemembering() {
        guard !simulationMode else { return }
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
        if simulationMode { return true }
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
                    recorder?.hold(false)
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
                recorder?.hold(true)
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
        updateModelLoadPause()
    }

    // MARK: - Pausing while the model loads

    /// The pipeline runs while the model loads, and until the model arrives it
    /// passes the mix through — so for those seconds the vocal the user just
    /// asked to remove keeps playing. Stopping Spotify instead means the first
    /// note they hear is the mix they asked for.
    private var waitingForModel: Bool {
        pipelineUseful && needsModel && modelLoader.isLoading
    }

    /// Longest a load may keep the music stopped. Loading takes 1.5–7 s; if it
    /// ever takes longer than this, playback comes back anyway. Music that
    /// never restarts is a worse failure than a vocal that gets through.
    private static let modelLoadPauseLimit: TimeInterval = 20

    private func updateModelLoadPause() {
        guard waitingForModel else {
            if pausedForModelLoad { scheduleResumeAfterModelLoad() }
            modelLoadPauseSpent = false
            return
        }
        // Playing again while we hold the pause means the user pressed play.
        // They win: let it run, and stop owing a resume.
        if pausedForModelLoad, spotifyPlaying {
            log.notice("play pressed during the model load; leaving playback alone")
            clearModelLoadPause()
            return
        }
        guard !modelLoadPauseSpent, spotifyPlaying else { return }
        modelLoadPauseSpent = true
        // Without automation permission the command never lands, and a pause
        // we did not make is not ours to undo.
        guard setSpotifyPlaying?(false) == true else { return }
        pausedForModelLoad = true
        log.notice("paused Spotify while the separation model loads")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pausedForModelLoad else { return }
            log.error("model load outlasted the pause limit; resuming playback")
            self.resumeAfterModelLoad()
            self.onChange?()
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.modelLoadPauseLimit, execute: work)
    }

    /// The warm-up ends with three back-to-back predictions, which leave the
    /// GPU in its slow state; the first real predictions then take twice as
    /// long and underrun. A short breath before playback lets it recover.
    private var resumeGraceWork: DispatchWorkItem?
    private func scheduleResumeAfterModelLoad() {
        guard resumeGraceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resumeGraceWork = nil
            guard self.pausedForModelLoad else { return }
            self.resumeAfterModelLoad()
            self.onChange?()
        }
        resumeGraceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Give the music back. Callers refresh the UI themselves.
    private func resumeAfterModelLoad() {
        clearModelLoadPause()
        _ = setSpotifyPlaying?(true)
        log.notice("model load finished; resuming playback")
    }

    private func clearModelLoadPause() {
        resumeGraceWork?.cancel()
        resumeGraceWork = nil
        resumeWork?.cancel()
        resumeWork = nil
        pausedForModelLoad = false
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
            let recorder = try SessionRecorder.requested()
            self.recorder = recorder
            let capture = try audioSourceFactory?(recorder) ?? AudioCapture(recorder: recorder)
            try capture.start()

            // The neural path sits between capture and pitch shifting and is
            // format-preserving, so PitchEngine just reads a different ring.
            // The separation stage runs in every mode, even Off, where it is
            // just a delay line and costs no GPU. That uniform delay is what
            // makes switching seamless: without it, going from a live stream to
            // a delayed one has to gap, repeat, or bend time.
            let env = ProcessInfo.processInfo.environment
            let hop = Double(env["TRANSPOSIFY_HOP"] ?? "")
                ?? SeparationEngine.defaultHopSeconds
            let lookahead = Double(env["TRANSPOSIFY_LOOKAHEAD"] ?? "")
                ?? SeparationEngine.defaultLookaheadSeconds
            let separation = try SeparationEngine(
                captureRate: capture.sampleRate,
                channels: capture.channelCount,
                inputRing: capture.ring,
                model: modelLoader.model,
                hopSeconds: hop,
                lookaheadSeconds: lookahead,
                recording: recorder?.stepSink)
            log.notice("""
                pipeline: hop \(String(format: "%.2f", separation.hopSeconds), privacy: .public)s \
                delay \(String(format: "%.2f", separation.nominalDelay), privacy: .public)s \
                (inference \(String(format: "%.0f", (SeparationModelLoader.measuredInference ?? 0) * 1000), privacy: .public) ms)
                """)
            separation.setSelection(currentSelection)
            separation.setSplitVocal(splitActive)
            separation.start()
            self.separation = separation
            let sourceRing = separation.outputRing
            priming = true
            depthTicks = 0
            stepsSettleAt = Date().addingTimeInterval(3)
            stepsSettled = false
            let cushion = cushionSeconds
            primeFloats = Int((cushion + separation.hopSeconds) * capture.sampleRate)
                * capture.channelCount
            targetDepth = separation.nominalDelay + cushion
            governorRatio = 1.0
            log.notice("""
                cushion \(String(format: "%.0f", self.cushionSeconds * 1000), privacy: .public) ms                 (worst step \(String(format: "%.0f", (SeparationEngine.measuredWorstStep ?? 0) * 1000), privacy: .public) ms),                 expected depth \(String(format: "%.2f", separation.nominalDelay + self.cushionSeconds), privacy: .public)s
                """)
            // Fade the mark so one bad session cannot charge every later one.
            SeparationEngine.decayWorstStep()
            startSeparationWatchdog()

            let engine = PitchEngine(sampleRate: capture.sampleRate,
                                     channels: capture.channelCount, ring: sourceRing,
                                     vocalRing: splitActive ? separation.vocalRing : nil,
                                     recorder: recorder, manualRendering: simulationMode)
            engine.semitones = semitones
            engine.formantOver = formantMode.over
            engine.onConfigurationChange = { [weak self] in self?.reconfigure() }
            // Hold output until a cushion of audio exists. Releasing as soon as
            // the ring is merely non-empty leaves no floor, so every hiccup —
            // the switch from passthrough to separation especially, which
            // shifts production later by one inference — empties it and drops
            // samples. The cushion is the floor that absorbs them.
            engine.hold = true
            recorder?.hold(true)
            try engine.start()
            self.capture = capture
            self.engine = engine
            engaged = true
            lastError = nil
            recorder?.engage(sampleRate: capture.sampleRate, channels: capture.channelCount,
                hopSeconds: separation.hopSeconds,
                lookaheadSeconds: Double(separation.lookaheadFrames) / SeparationEngine.modelRate,
                cushionSeconds: cushion, targetDepth: targetDepth, semitones: semitones,
                stemMask: stemMask, stemCount: stemCount)
            recorder?.track(currentTrackID)
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

    func renderSimulation(frames: Int, into output: UnsafeMutablePointer<Float>) throws {
        guard simulationMode, let engine else {
            throw NSError(domain: "TransposifySimulator", code: -1)
        }
        try engine.renderOffline(frames: frames, into: output)
    }

    var simulationStats: (underruns: Int, worstStep: Double, minRing: Int, depth: Double) {
        let rate = capture?.sampleRate ?? 48_000
        let depth = separation.map {
            Double($0.stagedCaptureFrames - $0.consumedCaptureFrames) / rate
        } ?? 0
        return (engine?.underruns ?? 0, separation?.maxStepSeconds ?? 0,
                separation?.minOutputFrames ?? 0, depth)
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
            if self.priming, separation.outputRing.availableToRead >= self.primeFloats {
                self.priming = false
                self.engine?.hold = false
                self.recorder?.hold(false)
                // Underruns before this point are the start-up gap, which is
                // unavoidable when the pipeline builds its buffer from empty.
                self.engine?.resetUnderruns()
                self.lastUnderrunLog = 0
                // Margins measured during priming describe the ramp, not the
                // steady state that mode switching has to survive.
                separation.resetMargins()
                self.onChange?()
            }
            // Keep the high-water mark that sizes the next cushion, once the
            // worker has settled. Only new maxima write, so this is a handful
            // of writes per session.
            if let at = self.stepsSettleAt, Date() >= at {
                self.stepsSettleAt = nil
                self.stepsSettled = true
                separation.resetMargins()
            }
            if self.stepsSettled {
                SeparationEngine.recordWorstStep(separation.maxStepSeconds)
            }

            let rate = self.capture?.sampleRate ?? 48_000
            let staged = separation.stagedCaptureFrames
            let consumed = separation.consumedCaptureFrames
            self.recorder?.depth(stagedFrames: staged, consumedFrames: consumed,
                ringFrames: separation.outputRing.availableToRead / (self.capture?.channelCount ?? 2),
                depthSeconds: Double(staged - consumed) / rate)

            // The number this whole design is judged on: how far behind
            // Spotify the listener actually is. Logged sparsely so a session
            // can be read back without drowning in it.
            if !self.priming, self.spotifyPlaying {
                self.depthTicks += 1
                if self.depthTicks % 60 == 0 {   // 0.25 s poll -> every 15 s
                    let depth = Double(separation.stagedCaptureFrames
                        - separation.consumedCaptureFrames) / rate
                    log.notice("""
                        depth \(String(format: "%.2f", depth), privacy: .public)s,                         underruns \(self.engine?.underruns ?? 0, privacy: .public),                         \(self.marginDescription(separation), privacy: .public)
                        """)
                }
            }

            self.updateGovernor(separation)

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
            if let target = self.mixTarget, separation.consumedCaptureFrames >= target {
                self.mixTarget = nil
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
        governorRatio = 1.0
        targetDepth = 0
        mixTarget = nil          // nothing is in flight once the pipeline is down
        modelLoader.releaseAfterGrace()   // keep it briefly in case they return
        pendingSemitones = nil   // next engage seeds engine.semitones directly
        engaged = false
        recorder?.finish(worstStepSeconds: margin?.step); recorder = nil
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
