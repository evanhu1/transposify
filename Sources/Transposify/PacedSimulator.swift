import AVFoundation
import Darwin
import AppKit
import Foundation

/// The controller depends only on the format and ring that feed separation.
protocol AudioSource: AnyObject {
    var sampleRate: Double { get }
    var channelCount: Int { get }
    var ring: RingBuffer! { get }
    func start() throws
    func stop()
}

extension AudioCapture: AudioSource {}

/// File-backed source advanced by the simulator's audio clock.
private final class FileAudioSource: AudioSource {
    let sampleRate = 48_000.0
    let channelCount = 2
    let ring: RingBuffer!

    private let samples: [Float]
    private let recorder: SessionRecorder?
    private var position = 0

    init(path: String, recorder: SessionRecorder?) throws {
        self.recorder = recorder
        samples = try Self.load(path: path, rate: sampleRate, channels: channelCount)
        ring = RingBuffer(capacityFloats: Int(sampleRate * 0.5) * channelCount)
    }

    func start() throws {
        try recorder?.prepareAudio(sampleRate: sampleRate, channels: channelCount)
    }

    func stop() {}

    var finished: Bool { position >= samples.count }

    @discardableResult
    func push(frames: Int) -> Int {
        let count = min(frames * channelCount, samples.count - position)
        guard count > 0 else { return 0 }
        samples.withUnsafeBufferPointer { source in
            let pointer = source.baseAddress! + position
            ring.write(pointer, count: count)
            recorder?.inputSink?.write(pointer, count: count)
        }
        position += count
        return count / channelCount
    }

    private static func load(path: String, rate: Double, channels: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let sourceFormat = file.processingFormat
        guard let source = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "TransposifySimulator", code: -3)
        }
        try file.read(into: source)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: AVAudioChannelCount(channels)),
              let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw NSError(domain: "TransposifySimulator", code: -4)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let capacity = AVAudioFrameCount(Double(source.frameLength) * rate
            / sourceFormat.sampleRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let planes = output.floatChannelData else {
            throw NSError(domain: "TransposifySimulator", code: -5)
        }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        let frames = Int(output.frameLength)
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let input = planes[min(channel, Int(output.format.channelCount) - 1)]
            for frame in 0..<frames {
                interleaved[frame * channels + channel] = input[frame]
            }
        }
        return interleaved
    }
}

/// Runs the live controller, separator and pitch shifter under a paced clock.
enum PacedSimulator {
    private struct Action {
        let time: Double
        let command: String
    }

    static func run(_ specification: String) -> Never {
        let errorOutput = FileHandle.standardError
        func fail(_ message: String) -> Never {
            errorOutput.write(("simulation failed: \(message)\n").data(using: .utf8)!)
            exit(1)
        }

        let pieces = specification.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
            fail("usage: TRANSPOSIFY_SIMULATE=in.wav:outdir")
        }
        guard SeparationModel.isInstalled else { fail(SeparationModel.installHint) }
        setenv("TRANSPOSIFY_RECORD", pieces[1], 1)

        // The live app shares the GPU. Its predictions slow the simulator's
        // steps and vice versa, and a run taken like that measures the
        // contention, not the pipeline. The first run did exactly that:
        // 3 s steps against a 108 ms model.
        let liveApp = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.evanhu.transposify" }
        if liveApp && ProcessInfo.processInfo.environment["TRANSPOSIFY_SIM_ALLOW_LIVE"] != "1" {
            fail("Transposify.app is running and would share the GPU. Quit it first, "
                 + "or set TRANSPOSIFY_SIM_ALLOW_LIVE=1 to measure anyway.")
        }

        // Measure nothing into the store, and start from the live app's
        // numbers: the hop and cushion then match what the listener gets,
        // and a contended warm-up here cannot reconfigure the real app.
        SeparationModelLoader.persistMeasurements = false
        if let app = UserDefaults(suiteName: "com.evanhu.transposify") {
            for key in ["measuredInferenceSeconds", "measuredWorstStepSeconds"] {
                let v = app.double(forKey: key)
                if v > 0 { UserDefaults.standard.set(v, forKey: key) }
            }
            // The window too, or the loader sees a window change here and
            // wipes the readings just copied.
            let window = app.integer(forKey: "modelWindowFrames")
            if window > 0 { UserDefaults.standard.set(window, forKey: "modelWindowFrames") }
        }

        do {
            let controller = AudioController()
            controller.simulationMode = true
            var source: FileAudioSource?
            controller.audioSourceFactory = { recorder in
                let created = try FileAudioSource(path: pieces[0], recorder: recorder)
                source = created
                return created
            }

            // Load and warm the model before the clock starts. This keeps the
            // config sweep about streaming performance rather than cold load.
            controller.setPreset(.backing)
            let loadDeadline = Date(timeIntervalSinceNow: 120)
            while controller.preparingModel && Date() < loadDeadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            guard !controller.preparingModel else { fail("model load timed out") }
            guard controller.modelReadyForSimulation else { fail("model load failed") }
            controller.setPreset(.all)

            let actions = parseActions(ProcessInfo.processInfo.environment["TRANSPOSIFY_SIM_SCRIPT"])
            let speed = max(0.01, Double(
                ProcessInfo.processInfo.environment["TRANSPOSIFY_SIM_SPEED"] ?? "1") ?? 1)
            let secondsLimit = Double(
                ProcessInfo.processInfo.environment["TRANSPOSIFY_SIM_SECONDS"] ?? "")
            let tickFrames = 512
            let tickSeconds = Double(tickFrames) / 48_000
            let output = UnsafeMutablePointer<Float>.allocate(capacity: tickFrames * 2)
            output.initialize(repeating: 0, count: tickFrames * 2)
            defer { output.deallocate() }

            var playing = true
            var trackNumber = 0
            controller.spotifyUpdate(running: true, playing: true, trackID: "simulation:0")
            guard let source else { fail("controller did not start its source") }

            let began = DispatchTime.now().uptimeNanoseconds
            var tick = 0
            var nextAction = 0
            while !source.finished {
                let sessionTime = Double(tick) * tickSeconds
                if let secondsLimit, sessionTime >= secondsLimit { break }
                while nextAction < actions.count, actions[nextAction].time <= sessionTime {
                    apply(actions[nextAction].command, controller: controller,
                          playing: &playing, trackNumber: &trackNumber)
                    nextAction += 1
                }
                if playing { _ = source.push(frames: tickFrames) }
                try controller.renderSimulation(frames: tickFrames, into: output)
                tick += 1
                wait(until: began + UInt64(Double(tick) * tickSeconds / speed * 1_000_000_000))
            }

            let stats = controller.simulationStats
            controller.shutdown()
            let minRing = stats.minRing == Int.max ? -1 : stats.minRing
            print(String(format: "underruns=%d worstStepMs=%.1f minRingFrames=%d finalDepth=%.3fs",
                         stats.underruns, stats.worstStep * 1_000, minRing, stats.depth))
            exit(0)
        } catch {
            fail("\(error)")
        }
    }

    private static func parseActions(_ specification: String?) -> [Action] {
        guard let specification else { return [] }
        return specification.split(separator: ",").compactMap { raw in
            let fields = raw.split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2, let time = Double(fields[0]) else { return nil }
            return Action(time: time, command: fields[1])
        }.sorted { $0.time < $1.time }
    }

    private static func apply(_ command: String, controller: AudioController,
                              playing: inout Bool, trackNumber: inout Int) {
        switch command {
        case "pause":
            playing = false
            controller.spotifyUpdate(running: true, playing: false,
                                     trackID: "simulation:\(trackNumber)")
        case "play":
            playing = true
            controller.spotifyUpdate(running: true, playing: true,
                                     trackID: "simulation:\(trackNumber)")
        case "all": controller.setPreset(.all)
        case "vocals": controller.setPreset(.vocals)
        case "backing": controller.setPreset(.backing)
        case "track":
            trackNumber += 1
            controller.spotifyUpdate(running: true, playing: playing,
                                     trackID: "simulation:\(trackNumber)")
        default:
            if let semitones = Int(command), command.hasPrefix("+") || command.hasPrefix("-") {
                controller.setSemitones(semitones)
            }
        }
    }

    private static func wait(until deadline: UInt64) {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return }
            let remaining = min(Double(deadline - now) / 1_000_000_000, 0.005)
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: remaining))
        }
    }
}
