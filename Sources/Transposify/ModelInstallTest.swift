import Foundation

/// Headless exercise of the model download flow: fetches, verifies the
/// checksum, unpacks and installs, then confirms the result actually loads as
/// a Core ML model. Run with TRANSPOSIFY_TEST_INSTALL=1 (point
/// TRANSPOSIFY_MODEL_URL at a local server to avoid the network).
enum ModelInstallTest {
    static func run() -> Never {
        let err = FileHandle.standardError
        func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        guard let target = SeparationModel.installedURL else {
            emit("FAIL  no Application Support directory")
            exit(1)
        }

        // Move any existing install aside so this exercises a real first run.
        let fm = FileManager.default
        let stash = target.appendingPathExtension("testbackup")
        let hadExisting = fm.fileExists(atPath: target.path)
        if hadExisting {
            try? fm.removeItem(at: stash)
            do { try fm.moveItem(at: target, to: stash) } catch {
                emit("FAIL  couldn't stash existing model: \(error)")
                exit(1)
            }
        }
        func restore() {
            if hadExisting {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: stash, to: target)
            }
        }

        emit("source: \(SeparationModel.downloadURL.absoluteString)")
        emit("expecting sha256 \(SeparationModel.expectedArchiveSHA256)")
        emit("installed before start: \(SeparationModel.isInstalled)")

        let installer = SeparationModelInstaller()
        let done = DispatchSemaphore(value: 0)
        var lastPercent = -10
        var failure: String?

        installer.onChange = {
            switch installer.state {
            case .downloading(let fraction, _, _):
                let pct = Int(fraction * 100)
                if pct >= lastPercent + 20 { lastPercent = pct; emit("  downloading \(pct)%") }
            case .verifying: emit("  verifying checksum")
            case .installing: emit("  installing")
            case .failed(let m): failure = m; done.signal()
            case .installed: done.signal()
            case .idle: break
            }
        }

        DispatchQueue.main.async { installer.start() }
        let deadline = Date().addingTimeInterval(300)
        while done.wait(timeout: .now() + 0.02) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            if Date() > deadline {
                emit("FAIL  timed out")
                restore()
                exit(1)
            }
        }

        if let failure {
            emit("FAIL  \(failure)")
            restore()
            exit(1)
        }

        guard SeparationModel.isInstalled, let located = SeparationModel.locate() else {
            emit("FAIL  installer reported success but nothing is on disk")
            restore()
            exit(1)
        }
        emit("installed at \(located.path)")

        // The real proof: it loads and is the model we expect.
        let loader = SeparationModelLoader()
        let ready = DispatchSemaphore(value: 0)
        loader.onChange = { if loader.model != nil || loader.error != nil { ready.signal() } }
        DispatchQueue.main.async { loader.prepare() }
        while ready.wait(timeout: .now() + 0.02) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard let model = loader.model else {
            emit("FAIL  installed model wouldn't load: \(loader.error ?? "?")")
            restore()
            exit(1)
        }
        let shape = model.modelDescription
            .inputDescriptionsByName[SeparationEngine.inputFeature]?
            .multiArrayConstraint?.shape.map(\.intValue)
        emit("loaded; input shape \(shape.map(String.init(describing:)) ?? "nil")")
        guard shape?.last == SeparationEngine.windowFrames else {
            emit("FAIL  window \(String(describing: shape?.last)) != expected "
                + "\(SeparationEngine.windowFrames)")
            restore()
            exit(1)
        }

        emit("PASS  download, checksum, install, load, geometry all good")
        // Leave the freshly installed model in place; drop the stash.
        try? fm.removeItem(at: stash)
        exit(0)
    }
}
