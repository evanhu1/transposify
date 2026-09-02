import AppKit

/// Headless verification of the engagement state machine + per-song memory,
/// run with TRANSPOSIFY_SELFTEST=1. Stubs the audio side so it needs no mic,
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
        // Start from a known state: this exercises the engagement machine, not
        // whatever per-stem selection happens to be persisted.
        controller.setPreset(.all)

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
            // Coasting: nothing needs the pipeline any more, but tearing it
            // down mid-song would drop the ~0.6 s in flight and hand the
            // listener Spotify's live position instead. It stays up until a
            // boundary where that jump is free.
            Step(label: "Back to 0 \u{2192} coasts (no mid-song teardown)",
                 delay: 0.6,
                 action: { controller.setSemitones(0) },
                 expectEngaged: true, expectSemitones: 0),
            Step(label: "Track change while coasting \u{2192} stands down",
                 delay: 0.1,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackB) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Back to A \u{2192} still 0, still down",
                 delay: 0.1,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackA) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Shift +3 again \u{2192} engage",
                 delay: 0.05,
                 action: { controller.setSemitones(3) },
                 expectEngaged: true, expectSemitones: 3),
            Step(label: "Mix change while engaged \u{2192} no teardown",
                 delay: 0.05,
                 action: { controller.setPreset(.vocals) },
                 expectEngaged: true, expectSemitones: 3),
            Step(label: "Back to full mix \u{2192} still no teardown",
                 delay: 0.6,
                 action: { controller.setPreset(.all); controller.setSemitones(0) },
                 expectEngaged: true, expectSemitones: 0),
            Step(label: "Isolate on at 0 \u{2192} engage",
                 delay: 0.05,
                 action: { controller.setPreset(.backing) },
                 expectEngaged: true, expectSemitones: 0),
            Step(label: "Pause \u{2192} disengage",
                 delay: 0.6,
                 action: { controller.spotifyUpdate(running: true, playing: false, trackID: trackA) },
                 expectEngaged: false, expectSemitones: nil),
            Step(label: "Resume \u{2192} re-engage (isolate still on)",
                 delay: 0.05,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackA) },
                 expectEngaged: true, expectSemitones: nil),
            Step(label: "Set +5 on A (isolate off), remembered",
                 delay: 0.05,
                 action: { controller.setPreset(.all); controller.setSemitones(5) },
                 expectEngaged: true, expectSemitones: 5),
            Step(label: "Switch to B \u{2192} default 0, disengage",
                 delay: 0.6,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackB) },
                 expectEngaged: false, expectSemitones: 0),
            Step(label: "Back to A \u{2192} restores +5, engage",
                 delay: 0.05,
                 action: { controller.spotifyUpdate(running: true, playing: true, trackID: trackA) },
                 expectEngaged: true, expectSemitones: 5),
            Step(label: "Forget A (Remember off), leave A at 0 \u{2192} coasts",
                 delay: 0.6,
                 action: { controller.setRemember(false); controller.setSemitones(0) },
                 expectEngaged: true, expectSemitones: 0),
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
            controller.reportPermissionDenied()
            if case .error = controller.mode {
                results.append(("Denied audio is visible", true, ""))
            } else {
                results.append(("Denied audio is visible", false,
                                "controller did not expose an error"))
            }
            controller.reportPermissionAllowed()
            if case .error = controller.mode {
                results.append(("Recovered audio clears the stale error", false,
                                "controller still exposed an error"))
            } else {
                results.append(("Recovered audio clears the stale error", true, ""))
            }
            // cleanup any persisted self-test entries
            controller.setRemember(false)
            let err = FileHandle.standardError
            func emit(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }
            emit("\n===== Transposify self-test =====")
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
