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

    /// Bumped whenever the converted model changes. The app refuses an archive
    /// whose hash doesn't match, which pins the model's *geometry* — window
    /// length and stem order are compiled in, and a mismatched model would
    /// produce silent garbage rather than an honest failure.
    static let modelVersion = "model-v1"

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
        "a62bb8abdaeb8738c9cd831b52d3be90fdd2d9f2ba5c2809810aca5750d9b03b"

    static let approximateDownloadBytes = 141_910_700

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
                // Warm up and time it. The first prediction pays Core ML's
                // per-device specialisation, which is why it is discarded —
                // and why doing this here keeps that cost out of the audio
                // path entirely.
                // Warm up always — the first prediction pays Core ML's
                // per-device specialisation, and paying it here keeps it out
                // of the audio path. Only *time* it when there is no stored
                // measurement: three back-to-back window predictions are
                // enough GPU work to disturb playback, and the number only
                // needs establishing once.
                let existing = Self.measuredInference
                let inference = Self.warmUp(model, measure: existing == nil) ?? existing
                DispatchQueue.main.async {
                    log.notice("""
                        separation model loaded in \(String(format: "%.1f", elapsed), privacy: .public)s, \
                        inference \(String(format: "%.0f", (inference ?? 0) * 1000), privacy: .public) ms
                        """)
                    if let inference {
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
    private static func warmUp(_ model: MLModel, measure: Bool) -> Double? {
        do {
            let input = try MLMultiArray(
                shape: [1, 2, NSNumber(value: SeparationEngine.windowFrames)],
                dataType: .float32)
            memset(input.dataPointer, 0,
                   2 * SeparationEngine.windowFrames * MemoryLayout<Float>.size)
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [SeparationEngine.inputFeature: input])
            var times: [Double] = []
            let runs = measure ? 3 : 1
            for i in 0..<runs {
                let t = Date()
                _ = try model.prediction(from: provider)
                if i > 0 { times.append(-t.timeIntervalSinceNow) }
                // Let the audio worker have the GPU between runs.
                if i < runs - 1 { Thread.sleep(forTimeInterval: 0.05) }
            }
            return times.isEmpty ? nil : times.sorted()[times.count / 2]
        } catch {
            log.error("inference measurement failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Drop the model and its memory.
    func release() {
        state = .idle
        onChange?()
    }
}
