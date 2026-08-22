import AVFoundation
import Darwin
import Foundation
import Synchronization

/// Records the samples and timing facts needed to explain an audible glitch.
/// All file work happens off the audio and separation threads.
final class SessionRecorder: @unchecked Sendable {
    fileprivate final class ActiveFlag: @unchecked Sendable {
        private let value = Atomic<Bool>(true)
        func get() -> Bool { value.load(ordering: .relaxed) }
        func stop() -> Bool { value.exchange(false, ordering: .acquiringAndReleasing) }
    }

    fileprivate struct RTEvent {
        var ticks: UInt64 = 0
        var kind: Int32 = 0
        var flag: Int32 = 0
        var a: Double = 0
        var b: Double = 0
        var c: Double = 0
        var d: Double = 0
        var e: Double = 0
        var f: Double = 0
        var g: Double = 0
    }

    /// A single-producer / single-consumer ring for fixed-size timing events.
    fileprivate final class EventRing: @unchecked Sendable {
        private let storage: UnsafeMutablePointer<RTEvent>
        private let capacity: Int
        private let mask: Int
        private let writeIndex = Atomic<Int>(0)
        private let readIndex = Atomic<Int>(0)

        init(capacity requested: Int) {
            var size = 1
            while size < max(2, requested) { size <<= 1 }
            capacity = size
            mask = size - 1
            storage = .allocate(capacity: size)
            storage.initialize(repeating: RTEvent(), count: size)
        }

        deinit { storage.deallocate() }

        func write(_ event: RTEvent) {
            let w = writeIndex.load(ordering: .relaxed)
            let r = readIndex.load(ordering: .acquiring)
            guard w &- r < capacity else { return }
            storage[w & mask] = event
            writeIndex.store(w &+ 1, ordering: .releasing)
        }

        func read() -> RTEvent? {
            let r = readIndex.load(ordering: .relaxed)
            let w = writeIndex.load(ordering: .acquiring)
            guard r != w else { return nil }
            let event = storage[r & mask]
            readIndex.store(r &+ 1, ordering: .releasing)
            return event
        }
    }

    /// The only object captured by the tap callback.
    final class InputSink: @unchecked Sendable {
        private let ring: RingBuffer
        private let active: ActiveFlag

        fileprivate init(ring: RingBuffer, active: ActiveFlag) {
            self.ring = ring
            self.active = active
        }

        func write(_ samples: UnsafePointer<Float>, count: Int) {
            guard active.get() else { return }
            ring.write(samples, count: count)
        }
    }

    /// Interleaves the device's planar output into a preallocated scratch area.
    final class OutputSink: @unchecked Sendable {
        private let ring: RingBuffer
        private let events: EventRing
        private let active: ActiveFlag
        private let scratch: UnsafeMutablePointer<Float>
        private let capacityFrames: Int
        private let channels: Int

        fileprivate init(ring: RingBuffer, events: EventRing, active: ActiveFlag,
                         capacityFrames: Int, channels: Int) {
            self.ring = ring
            self.events = events
            self.active = active
            self.capacityFrames = capacityFrames
            self.channels = channels
            scratch = .allocate(capacity: capacityFrames * channels)
        }

        deinit { scratch.deallocate() }

        func write(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            guard active.get(), buffers.count > 0 else { return }
            let count = min(frames, capacityFrames)
            var frame = 0
            while frame < count {
                var channel = 0
                while channel < channels {
                    let source = min(channel, buffers.count - 1)
                    let samples = buffers[source].mData?.assumingMemoryBound(to: Float.self)
                    scratch[frame * channels + channel] = samples?[frame] ?? 0
                    channel += 1
                }
                frame += 1
            }
            ring.write(scratch, count: count * channels)
        }

        func writePlanar(_ buffers: UnsafePointer<UnsafeMutablePointer<Float>?>,
                         availableChannels: Int, frames: Int) {
            guard active.get(), availableChannels > 0 else { return }
            let count = min(frames, capacityFrames)
            var frame = 0
            while frame < count {
                var channel = 0
                while channel < channels {
                    let source = min(channel, availableChannels - 1)
                    scratch[frame * channels + channel] = buffers[source]?[frame] ?? 0
                    channel += 1
                }
                frame += 1
            }
            ring.write(scratch, count: count * channels)
        }

        func underrun(shortFrames: Int, ringFrames: Int) {
            guard active.get() else { return }
            events.write(RTEvent(ticks: SessionRecorder.now(), kind: 2,
                                 a: Double(shortFrames), b: Double(ringFrames)))
        }
    }

    /// The only recorder object captured by the separation worker.
    final class StepSink: @unchecked Sendable {
        private let events: EventRing
        private let active: ActiveFlag

        fileprivate init(events: EventRing, active: ActiveFlag) {
            self.events = events
            self.active = active
        }

        func write(durationMs: Double, predictMs: Double, ringBeforeFrames: Int,
                   ringAfterFrames: Int, stagingFrames: Int, predicted: Bool,
                   stagedFrames: Int, publishedFrames: Int) {
            guard active.get() else { return }
            events.write(RTEvent(ticks: SessionRecorder.now(), kind: 1,
                                 flag: predicted ? 1 : 0, a: durationMs,
                                 b: Double(ringBeforeFrames), c: Double(ringAfterFrames),
                                 d: Double(stagingFrames), e: Double(stagedFrames),
                                 f: Double(publishedFrames), g: predictMs))
        }
    }

    private final class FloatWAV {
        private let file: FileHandle
        private let sampleRate: Int
        private let channels: Int
        private var byteCount: UInt64 = 0

        init(url: URL, sampleRate: Double, channels: Int) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: 0)
            self.sampleRate = Int(sampleRate.rounded())
            self.channels = channels
            file.write(Self.header(sampleRate: self.sampleRate, channels: channels, dataBytes: 0))
        }

        func write(_ samples: UnsafePointer<Float>, count: Int) {
            guard count > 0 else { return }
            file.write(Data(bytes: samples, count: count * MemoryLayout<Float>.size))
            byteCount += UInt64(count * MemoryLayout<Float>.size)
        }

        func close() {
            do {
                try file.seek(toOffset: 0)
                file.write(Self.header(sampleRate: sampleRate, channels: channels,
                                       dataBytes: UInt32(min(byteCount, UInt64(UInt32.max)))))
                try file.synchronize()
                try file.close()
            } catch {
                log.error("recording WAV close failed: \(error, privacy: .public)")
            }
        }

        private static func header(sampleRate: Int, channels: Int, dataBytes: UInt32) -> Data {
            var data = Data()
            func bytes(_ value: String) { data.append(contentsOf: value.utf8) }
            func u16(_ value: UInt16) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            func u32(_ value: UInt32) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            bytes("RIFF"); u32(36 &+ dataBytes); bytes("WAVE")
            bytes("fmt "); u32(16); u16(3); u16(UInt16(channels))
            u32(UInt32(sampleRate))
            u32(UInt32(sampleRate * channels * MemoryLayout<Float>.size))
            u16(UInt16(channels * MemoryLayout<Float>.size)); u16(32)
            bytes("data"); u32(dataBytes)
            return data
        }
    }

    private let directory: URL
    private let active = ActiveFlag()
    private let queue = DispatchQueue(label: "com.evanhu.transposify.recorder",
                                      qos: .utility)
    private let stepEvents = EventRing(capacity: 16_384)
    private let outputEvents = EventRing(capacity: 4_096)
    private let startTicks = SessionRecorder.now()
    private var inputRing: RingBuffer?
    private var outputRing: RingBuffer?
    private var inputWAV: FloatWAV?
    private var outputWAV: FloatWAV?
    private var eventFile: FileHandle?
    private var drainTimer: DispatchSourceTimer?
    private var autoStopTimer: DispatchSourceTimer?
    private var inputScratch: UnsafeMutablePointer<Float>?
    private var outputScratch: UnsafeMutablePointer<Float>?
    private let drainCapacity = 65_536
    private var metadata: [String: Any] = [:]
    private var sessionWorstStepMs = 0.0
    private var closed = false

    private(set) var inputSink: InputSink?
    private(set) var outputSink: OutputSink?
    lazy var stepSink = StepSink(events: stepEvents, active: active)

    static func requested() throws -> SessionRecorder? {
        guard let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_RECORD"],
              !path.isEmpty else { return nil }
        return try SessionRecorder(directory: URL(fileURLWithPath: path))
    }

    private init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    deinit {
        if active.stop() {
            queue.sync { closeOnQueue(reason: "deinit") }
        }
        inputScratch?.deallocate()
        outputScratch?.deallocate()
    }

    /// Allocates all callback-facing storage before Core Audio starts IO.
    func prepareAudio(sampleRate: Double, channels: Int) throws {
        let channelCount = max(1, channels)
        let capacity = Int(sampleRate * 10) * channelCount
        let inputRing = RingBuffer(capacityFloats: capacity)
        let outputRing = RingBuffer(capacityFloats: capacity)
        self.inputRing = inputRing
        self.outputRing = outputRing
        inputSink = InputSink(ring: inputRing, active: active)
        outputSink = OutputSink(ring: outputRing, events: outputEvents, active: active,
                                capacityFrames: 8_192, channels: channelCount)
        inputScratch = .allocate(capacity: drainCapacity)
        outputScratch = .allocate(capacity: drainCapacity)
        inputWAV = try FloatWAV(url: directory.appendingPathComponent("input.wav"),
                               sampleRate: sampleRate, channels: channelCount)
        outputWAV = try FloatWAV(url: directory.appendingPathComponent("output.wav"),
                                sampleRate: sampleRate, channels: channelCount)
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        eventFile = try FileHandle(forWritingTo: eventsURL)
        try eventFile?.truncate(atOffset: 0)
        metadata["sampleRate"] = sampleRate
        metadata["channels"] = channelCount
        startTimers()
    }

    func engage(sampleRate: Double, channels: Int, hopSeconds: Double,
                lookaheadSeconds: Double, cushionSeconds: Double, targetDepth: Double,
                semitones: Int, stemMask: Int, stemCount: Int) {
        metadata["machine"] = Self.machineName()
        metadata["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        metadata["sampleRate"] = sampleRate
        metadata["modelStemCount"] = stemCount
        metadata["measuredInferenceMs"] = (SeparationModelLoader.measuredInference ?? 0) * 1_000
        metadata["measuredWorstStepMs"] = (SeparationEngine.measuredWorstStep ?? 0) * 1_000
        metadata["overrides"] = Self.overrides()
        if let sha = Self.gitSHA() { metadata["gitSHA"] = sha }
        direct("engage", fields: [
            "sampleRate": sampleRate, "channels": channels, "hopSeconds": hopSeconds,
            "lookaheadSeconds": lookaheadSeconds, "cushionSeconds": cushionSeconds,
            "targetDepth": targetDepth, "semitones": semitones, "stemMask": stemMask,
        ])
    }

    func hold(_ held: Bool) { direct(held ? "hold" : "release") }

    func governor(ratio: Double, depth: Double?, target: Double) {
        var fields: [String: Any] = ["ratio": ratio, "target": target]
        if let depth { fields["depth"] = depth }
        direct("governor", fields: fields)
    }

    func selection(stemMask: Int, passthrough: Bool) {
        direct("selection", fields: ["stemMask": stemMask, "passthrough": passthrough])
    }

    func track(_ id: String?) {
        direct("track", fields: ["trackID": id ?? NSNull()])
    }

    func depth(stagedFrames: Int, consumedFrames: Int, ringFrames: Int,
               depthSeconds: Double) {
        direct("depth", fields: [
            "stagedFrames": stagedFrames, "consumedFrames": consumedFrames,
            "ringFrames": ringFrames, "depthSeconds": depthSeconds,
        ])
    }

    func finish(worstStepSeconds: Double? = nil) {
        guard active.stop() else { return }
        queue.sync {
            if let worstStepSeconds {
                sessionWorstStepMs = max(sessionWorstStepMs, worstStepSeconds * 1_000)
            }
            writeEvent("disengage", fields: [:], ticks: Self.now())
            closeOnQueue(reason: "disengage")
        }
    }

    private func direct(_ event: String, fields: [String: Any] = [:]) {
        guard active.get() else { return }
        let ticks = Self.now()
        queue.async { [weak self] in self?.writeEvent(event, fields: fields, ticks: ticks) }
    }

    private func startTimers() {
        let drain = DispatchSource.makeTimerSource(queue: queue)
        drain.schedule(deadline: .now(), repeating: .milliseconds(20))
        drain.setEventHandler { [weak self] in self?.drain() }
        drainTimer = drain
        drain.resume()

        let value = ProcessInfo.processInfo.environment["TRANSPOSIFY_RECORD_AUTOSTOP"]
        guard let value, let seconds = Double(value), seconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.active.stop() else { return }
            self.writeEvent("disengage", fields: ["reason": "autostop"], ticks: Self.now())
            self.closeOnQueue(reason: "autostop")
        }
        autoStopTimer = timer
        timer.resume()
    }

    private func drain() {
        if let ring = inputRing, let scratch = inputScratch, let wav = inputWAV {
            let count = ring.read(into: scratch, count: drainCapacity)
            wav.write(scratch, count: count)
        }
        if let ring = outputRing, let scratch = outputScratch, let wav = outputWAV {
            let count = ring.read(into: scratch, count: drainCapacity)
            wav.write(scratch, count: count)
        }
        while let event = stepEvents.read() { write(event) }
        while let event = outputEvents.read() { write(event) }
    }

    private func write(_ event: RTEvent) {
        if event.kind == 1 {
            sessionWorstStepMs = max(sessionWorstStepMs, event.a)
            writeEvent("step", fields: [
                "durationMs": event.a, "predictMs": event.g, "ringBeforeFrames": Int(event.b),
                "ringAfterFrames": Int(event.c), "stagingFrames": Int(event.d),
                "predicted": event.flag == 1, "stagedFrames": Int(event.e),
                "publishedFrames": Int(event.f),
            ], ticks: event.ticks)
        } else if event.kind == 2 {
            writeEvent("underrun", fields: [
                "shortFrames": Int(event.a), "ringFrames": Int(event.b),
            ], ticks: event.ticks)
        }
    }

    private func writeEvent(_ event: String, fields: [String: Any], ticks: UInt64) {
        guard let eventFile else { return }
        var object = fields
        object["t"] = Double(ticks &- startTicks) / 1_000_000_000
        object["ev"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        eventFile.write(data)
        eventFile.write(Data([0x0a]))
    }

    private func closeOnQueue(reason: String) {
        guard !closed else { return }
        closed = true
        drainTimer?.cancel(); drainTimer = nil
        autoStopTimer?.cancel(); autoStopTimer = nil
        drain()
        inputWAV?.close(); inputWAV = nil
        outputWAV?.close(); outputWAV = nil
        do {
            try eventFile?.synchronize()
            try eventFile?.close()
        } catch {
            log.error("recording events close failed: \(error, privacy: .public)")
        }
        eventFile = nil
        metadata["measuredWorstStepMs"] = max(
            metadata["measuredWorstStepMs"] as? Double ?? 0, sessionWorstStepMs)
        do {
            let data = try JSONSerialization.data(withJSONObject: metadata,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
            log.notice("recording closed (\(reason, privacy: .public)): \(self.directory.path, privacy: .public)")
        } catch {
            log.error("recording metadata failed: \(error, privacy: .public)")
        }
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static func machineName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: bytes)
    }

    private static func overrides() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let keys = [
            "TRANSPOSIFY_HOP", "TRANSPOSIFY_LOOKAHEAD", "TRANSPOSIFY_CUSHION",
            "TRANSPOSIFY_GOVERNOR", "TRANSPOSIFY_SIM_SPEED",
            "TRANSPOSIFY_RECORD_AUTOSTOP",
        ]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            env[key].map { (key, $0) }
        })
    }

    private static func gitSHA() -> String? {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", directory.path, "rev-parse", "HEAD"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
