import CryptoKit
import Foundation

/// Downloads the compiled vocal-removal model and installs it into Application
/// Support.
///
/// The model is ~256 MB, so it ships as a release asset rather than in the repo
/// or the .app bundle — only people who want "Best" pay for it. The archive is
/// checked against a SHA-256 baked into this build before anything is unpacked,
/// which also pins the *geometry*: window length and stem order are compiled
/// into the model, and a mismatched one would produce silent garbage instead of
/// an honest error.
///
/// `install-model.sh` remains the reproducible path for anyone who'd rather
/// build the model from source than trust a binary.
final class SeparationModelInstaller: NSObject {
    enum State {
        case idle
        case downloading(fraction: Double, receivedBytes: Int64, totalBytes: Int64)
        case verifying
        case installing
        case failed(String)
        case installed
    }

    private(set) var state: State = .idle
    /// Called on the main queue whenever `state` changes.
    var onChange: (() -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .installing: return true
        case .idle, .failed, .installed: return false
        }
    }

    var progressFraction: Double? {
        if case .downloading(let f, _, _) = state { return f }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let m) = state { return m }
        return nil
    }

    // MARK: - Control

    func start() {
        guard !isBusy else { return }
        guard let destination = SeparationModel.installedURL else {
            setState(.failed("Couldn't find Application Support."))
            return
        }
        self.destination = destination

        // A background queue: verification hashes 256 MB and the unpack shells
        // out, neither of which belongs on the main thread.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        self.session = session

        setState(.downloading(fraction: 0, receivedBytes: 0,
                              totalBytes: Int64(SeparationModel.approximateDownloadBytes)))
        let task = session.downloadTask(with: SeparationModel.downloadURL)
        self.task = task
        task.resume()
        log.notice("model download started: \(SeparationModel.downloadURL.absoluteString, privacy: .public)")
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        setState(.idle)
        log.notice("model download cancelled")
    }

    private var destination: URL?

    private func setState(_ new: State) {
        DispatchQueue.main.async {
            self.state = new
            self.onChange?()
        }
    }

    private func finish(_ new: State) {
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        setState(new)
    }

    // MARK: - Verify and unpack

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpack with `ditto`, which handles the .mlmodelc directory bundle
    /// correctly. The app isn't sandboxed, so spawning it is fine.
    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "SeparationModelInstaller", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Couldn't unpack the model. \(detail)"])
        }
    }

    private func install(from downloaded: URL) {
        guard let destination else { return }
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("transposify-model-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        do {
            setState(.verifying)
            let digest = try Self.sha256(of: downloaded)
            let expected = SeparationModel.expectedArchiveSHA256
            guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
                log.error("model checksum mismatch: got \(digest, privacy: .public)")
                finish(.failed("The downloaded model didn't match its checksum. "
                    + "Nothing was installed."))
                return
            }

            setState(.installing)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try Self.unzip(downloaded, into: work)

            // Find the .mlmodelc the archive carried, whatever it was named.
            let contents = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            guard let unpacked = contents.first(where: { $0.pathExtension == "mlmodelc" }) else {
                finish(.failed("The downloaded archive didn't contain a model."))
                return
            }

            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // Swap in atomically-ish: move the old aside, put the new in place,
            // and only then delete the old, so a failure leaves it working.
            let backup = destination.appendingPathExtension("previous")
            try? fm.removeItem(at: backup)
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: backup)
            }
            do {
                try fm.moveItem(at: unpacked, to: destination)
            } catch {
                if fm.fileExists(atPath: backup.path) {
                    try? fm.moveItem(at: backup, to: destination)
                }
                throw error
            }
            try? fm.removeItem(at: backup)

            log.notice("model installed at \(destination.path, privacy: .public)")
            finish(.installed)
        } catch {
            log.error("model install failed: \(String(describing: error), privacy: .public)")
            finish(.failed("Couldn't install the model. \(error.localizedDescription)"))
        }
    }
}

extension SeparationModelInstaller: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : Int64(SeparationModel.approximateDownloadBytes)
        setState(.downloading(fraction: min(1, Double(totalBytesWritten) / Double(max(total, 1))),
                              receivedBytes: totalBytesWritten, totalBytes: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted the moment this returns, so move it first.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("transposify-model-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            finish(.failed("Couldn't save the download. \(error.localizedDescription)"))
            return
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        install(from: staged)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        log.error("model download failed: \(String(describing: error), privacy: .public)")
        finish(.failed("Download failed. \(error.localizedDescription)"))
    }
}
