import AppKit

/// Headless verification of the engagement state machine + per-song memory,
/// run with TRANSPOSER_SELFTEST=1. Stubs the audio side so it needs no mic,
/// Spotify, or audio device. Prints PASS/FAIL and exits non-zero on failure.
enum SelfTest {
    private struct Step {
        let label: String
        let delay: Double          // wait before asserting (covers disengage debounce)
        let action: () -> Void
        let expectEngaged: Bool?
        let expectSemitones: Int?
    }

    static func run(_ controller: AudioController) {
        let trackA = "selftest:A"
        let trackB = "selftest:B"

        controller.testHooks = (engage: { _, _ in }, disengage: { })

        let steps: [Step] = [
            Step(label: "Spotify not running \u{2192} idle",
                 delay: 0.05,
                 action: { controller.spotifyUpdate(running: false, playing: false, trackID: nil) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Playing A at 0 \u{2192} passthrough (no tap)",
                 delay: 0.6,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackA) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Shift +3 \u{2192} engage",
                 delay: 0.05,
                 action: { controller.setSemitones(3) },
                 expectEngaged: true, expectSemitones: 3),
            Step(label: "Back to 0 \u{2192} disengage (debounced)",
                 delay: 0.6,
                 action: { controller.setSemitones(0) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Karaoke on at 0 \u{2192} engage",
                 delay: 0.05,
                 action: { controller.setKaraoke(true) },
                 expectEngaged: true, expectSemitones: 0),
            Step(label: "Pause \u{2192} disengage",
                 delay: 0.6,
                 action: { controller.spotifyUpdate(running: true, playing: false, trackID: trackA) },
                 expectEngaged: false, expectSemitones: nil),
            Step(label: "Resume \u{2192} re-engage (karaoke still on)",
                 delay: 0.05,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackA) },
                 expectEngaged: true, expectSemitones: nil),
            Step(label: "Set +5 on A (karaoke off), remembered",
                 delay: 0.05,
                 action: { controller.setKaraoke(false); controller.setSemitones(5) },
                 expectEngaged: true, expectSemitones: 5),
            Step(label: "Switch to B \u{2192} default 0, disengage",
                 delay: 0.6,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackB) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Back to A \u{2192} restores +5, engage",
                 delay: 0.05,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackA) },
                 expectEngaged: true, expectSemitones: 5),
            Step(label: "Forget A (Remember off) then leave A at 0",
                 delay: 0.6,
                 action: { controller.setRemember(false); controller.setSemitones(0) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Re-enter A \u{2192} no saved setting, stays 0",
                 delay: 0.6,
                 action: {
                     controller.spotifyUpdate(running: true, playing: true, trackID: trackB)
                     controller.spotifyUpdate(running: true, playing: true, trackID: trackA)
                 },
                 expectEngaged: false, expectSemitones: 0),
        ]

        var results: [(String, Bool, String)] = []

        func finish() {
            // cleanup any persisted self-test entries
            controller.setRemember(false)
            let err = FileHandle.standardError
            func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }
            emit("\n===== Transposer self-test =====")
            var failed = 0
            for (label, ok, detail) in results {
                emit("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
                if !ok { failed += 1 }
            }
            emit("================================")
            emit("\(results.count - failed)/\(results.count) passed")
            exit(failed == 0 ? 0 : 1)
        }

        func runStep(_ i: Int) {
            guard i < steps.count else { finish(); return }
            let step = steps[i]
            step.action()
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
                var ok = true
                var details: [String] = []
                if let e = step.expectEngaged, controller.engaged != e {
                    ok = false; details.append("engaged=\(controller.engaged) want \(e)")
                }
                if let s = step.expectSemitones, controller.semitones != s {
                    ok = false; details.append("semitones=\(controller.semitones) want \(s)")
                }
                results.append((step.label, ok, details.joined(separator: ", ")))
                runStep(i + 1)
            }
        }

        runStep(0)
    }
}
