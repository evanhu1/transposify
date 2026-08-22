import CoreML
import Foundation

/// Locates the compiled HTDemucs Core ML model.
///
/// The model is ~256 MB compiled, so it isn't in the repo or the .app bundle.
/// `install-model.sh` converts it and drops it here; until then the neural mode
/// reports itself unavailable and the UI offers the fast mid/side mode instead.
enum SeparationModel {
    static let directoryName = "Transposify"
    static let fileName = "HTDemucs.mlmodelc"

    /// `~/Library/Application Support/Transposify/HTDemucs.mlmodelc`
    static var installedURL: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(directoryName).appendingPathComponent(fileName)
    }

    /// Where the model actually is, honouring a debug override, or nil.
    static func locate() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["TRANSPOSIFY_MODEL"] {
            let url = URL(fileURLWithPath: override)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        // Bundled alongside the app, if someone chooses to ship it that way.
        if let bundled = Bundle.main.url(forResource: "HTDemucs", withExtension: "mlmodelc"),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let installed = installedURL, fm.fileExists(atPath: installed.path) {
            return installed
        }
        return nil
    }

    static var isInstalled: Bool { locate() != nil }

    // MARK: - Release asset

    /// model-v3 is the six-stem htdemucs_6s (vocals, drums, bass, other,
    /// guitar, piano) converted with a 3 s window instead of the 7.8 s it
    /// was trained on. A prediction costs a quarter as much, which is what
    /// lets the hop shrink from 0.27 s to 0.15 s; on a 60 s test the output
    /// was within 1 dB of the 7.8 s window. A model already on disk keeps
    /// working — the app reads the window and stem count from the model — so
    /// upgrading is optional, but the old window cannot reach the new delay.
    ///
    /// Bumped whenever the converted model changes. The app refuses an archive
    /// whose hash doesn't match, which pins the model's *geometry* — window
    /// length and stem order are compiled in, and a mismatched model would
    /// produce silent garbage rather than an honest failure.
    static let modelVersion = "model-v3"

    static var downloadURL: URL {
        // Debug hook: point the installer at a local server to exercise the
        // download path without hitting the network.
        if let override = ProcessInfo.processInfo.environment["TRANSPOSIFY_MODEL_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string:
            "https://github.com/evanhu1/transposify/releases/download/"
            + "\(modelVersion)/HTDemucs.mlmodelc.zip")!
    }

    /// SHA-256 of that exact archive, from `./install-model.sh --package`.
    ///
    /// Zip embeds timestamps, so packaging the same model twice produces two
    /// different digests. This must be the hash of the file actually attached
    /// to the release, not of a later rebuild.
    static let expectedArchiveSHA256 =
        "d7970250d670bc4bb08ab92cdb0f74d0600d913d4e5163d967d4efd951b2d2a2"

    static let approximateDownloadBytes = 110_996_483

    static var downloadSizeDescription: String {
        let mb = Double(approximateDownloadBytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }

    static var installHint: String {
        "The vocal-removal model isn't installed. Download it from the popover, "
            + "or build it from source with ./install-model.sh."
    }
}

/// Holds the loaded model so engaging doesn't pay for it.
///
/// Loading takes 1.5–7 s and must not happen on the main thread — doing it
/// inside `engage()` froze the UI for the whole of a cold load. Instead the
/// controller asks for a load as soon as "Best" is chosen, and engages when the
/// model reports ready. The model stays resident (it is large, on the order of
/// a gigabyte) until the user picks another mode.
final class SeparationModelLoader {
    enum State {
        case idle
        case loading
        case ready(MLModel)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Median time for one window, measured right after loading. Persisted,
    /// because the pipeline's hop has to be chosen before the model is
    /// necessarily resident, and it must not change while audio is flowing.
    private static let inferenceKey = "measuredInferenceSeconds"

    /// Off in the simulator, whose readings are taken under whatever else is
    /// running and must not become the app's idea of this machine.
    static var persistMeasurements = true

    /// Drop every stored speed reading; the next load re-measures.
    static func forgetMeasurements() {
        UserDefaults.standard.removeObject(forKey: inferenceKey)
        SeparationEngine.forgetWorstStep()
    }

    static var measuredInference: Double? {
        let v = UserDefaults.standard.double(forKey: inferenceKey)
        return v > 0 ? v : nil
    }
    /// Called on the main queue whenever `state` changes.
    var onChange: (() -> Void)?

    var model: MLModel? {
        if case .ready(let m) = state { return m }
        return nil
    }

    /// Stems the loaded model exposes, so four- and six-stem models can both be
    /// dropped in. Taken from an actual prediction: Core ML does not populate
    /// `multiArrayConstraint` for *outputs*, so the declared shape in the
    /// .mlpackage isn't readable from the compiled model's description.
    private(set) var stemCount: Int?

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var error: String? {
        if case .failed(let m) = state { return m }
        return nil
    }

    /// How long the model stays resident after it stops being needed. Loading
    /// costs seconds, so flicking Off and back should not pay for it twice.
    static let releaseGrace: TimeInterval = 90
    private var releaseWork: DispatchWorkItem?

    /// Drop the model, but not yet.
    func releaseAfterGrace(_ seconds: TimeInterval = SeparationModelLoader.releaseGrace) {
        guard model != nil, releaseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releaseWork = nil
            self.release()
            log.notice("separation model released after grace period")
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Begin loading if it isn't already loaded or in flight. Safe to call often.
    func prepare() {
        // Wanted again before the grace period expired: keep what we have.
        releaseWork?.cancel()
        releaseWork = nil
        switch state {
        case .loading, .ready: return
        case .idle, .failed: break
        }
        guard let url = SeparationModel.locate() else {
            state = .failed(SeparationModel.installHint)
            onChange?()
            return
        }
        state = .loading
        onChange?()
        // .utility, not .userInitiated: loading competes with the separation
        // worker that is feeding the render thread, and starving that worker
        // empties the output ring and drops audio.
        DispatchQueue.global(qos: .utility).async {
            let config = MLModelConfiguration()
            // HTDemucs returns silent garbage on the Neural Engine.
            config.computeUnits = .cpuAndGPU
            let started = Date()
            do {
                let model = try MLModel(contentsOf: url, configuration: config)
                let elapsed = -started.timeIntervalSinceNow
                // Speed measurements describe one model. A different window
                // is a different model, and a hop tuned for a short one
                // would starve a long one.
                let previousWindow = SeparationEngine.storedWindowFrames
                let window = SeparationEngine.windowFrames(of: model)
                if let previousWindow, let window, previousWindow != window {
                    Self.forgetMeasurements()
                    log.notice("model window changed (\(previousWindow, privacy: .public) -> \(window, privacy: .public) frames); measurements reset")
                }
                // Warm up and time it. The first prediction pays Core ML's
                // per-device specialisation, which is why it is discarded —
                // and why doing this here keeps that cost out of the audio
                // path entirely.
                //
                // Timing used to happen only once, because three back-to-back
                // window predictions are enough GPU work to disturb playback.
                // Playback is now stopped for the whole load, so the
                // measurement is free and can be taken every time — which is
                // what lets the hop follow the machine instead of remembering
                // one reading from months ago.
                let existing = Self.measuredInference
                let warm = Self.warmUp(model, measure: true)
                // Keep the *fastest* reading. Contention — another process on
                // the GPU, a thermal dip — only ever makes a reading slower,
                // so the minimum is the machine's real capability. A blend
                // was tried first and a single contended load doubled the
                // stored value, which doubled the hop and the delay with it.
                let inference = warm.seconds.map { observed in
                    existing.map { min($0, observed) } ?? observed
                } ?? existing
                DispatchQueue.main.async {
                    self.stemCount = warm.stems
                    log.notice("""
                        separation model loaded in \(String(format: "%.1f", elapsed), privacy: .public)s, \
                        inference \(String(format: "%.0f", (inference ?? 0) * 1000), privacy: .public) ms \
                        (this load measured \(String(format: "%.0f", (warm.seconds ?? 0) * 1000), privacy: .public) ms), \
                        stems \(self.stemCount ?? -1, privacy: .public)
                        """)
                    if let inference, Self.persistMeasurements {
                        UserDefaults.standard.set(inference, forKey: Self.inferenceKey)
                    }
                    self.state = .ready(model)
                    self.onChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    log.error("separation model load failed: \(String(describing: error), privacy: .public)")
                    self.state = .failed("Couldn't load the vocal-removal model.")
                    self.onChange?()
                }
            }
        }
    }

    /// Run the model on silence. With `measure`, time it over extra runs.
    /// Also reports how many stems the output actually has.
    private static func warmUp(_ model: MLModel,
                               measure: Bool) -> (seconds: Double?, stems: Int?) {
        do {
            let frames = SeparationEngine.windowFrames(of: model)
                ?? SeparationEngine.defaultWindowFrames
            let input = try MLMultiArray(
                shape: [1, 2, NSNumber(value: frames)], dataType: .float32)
            memset(input.dataPointer, 0, 2 * frames * MemoryLayout<Float>.size)
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [SeparationEngine.inputFeature: input])
            var times: [Double] = []
            var stems: Int?
            let runs = measure ? 3 : 1
            for i in 0..<runs {
                let t = Date()
                try autoreleasepool {
                    let out = try model.prediction(from: provider)
                    if i > 0 { times.append(-t.timeIntervalSinceNow) }
                    if stems == nil,
                       let shape = out.featureValue(for: SeparationEngine.outputFeature)?
                           .multiArrayValue?.shape.map(\.intValue), shape.count > 1 {
                        stems = shape[1]
                    }
                }
                // Let the audio worker have the GPU between runs.
                if i < runs - 1 { Thread.sleep(forTimeInterval: 0.05) }
            }
            return (times.isEmpty ? nil : times.sorted()[times.count / 2], stems)
        } catch {
            log.error("inference measurement failed: \(String(describing: error), privacy: .public)")
            return (nil, nil)
        }
    }

    /// Drop the model and its memory.
    func release() {
        state = .idle
        stemCount = nil
        onChange?()
    }
}
