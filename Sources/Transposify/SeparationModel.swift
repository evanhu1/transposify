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

    static var installHint: String {
        "Run ./install-model.sh to add the vocal-removal model "
            + "(~256 MB, downloaded and converted once)."
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

    /// Begin loading if it isn't already loaded or in flight. Safe to call often.
    func prepare() {
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
        DispatchQueue.global(qos: .userInitiated).async {
            let config = MLModelConfiguration()
            // HTDemucs returns silent garbage on the Neural Engine.
            config.computeUnits = .cpuAndGPU
            let started = Date()
            do {
                let model = try MLModel(contentsOf: url, configuration: config)
                let elapsed = -started.timeIntervalSinceNow
                DispatchQueue.main.async {
                    log.notice("separation model loaded in \(String(format: "%.1f", elapsed), privacy: .public)s")
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

    /// Drop the model and its memory.
    func release() {
        state = .idle
        onChange?()
    }
}
