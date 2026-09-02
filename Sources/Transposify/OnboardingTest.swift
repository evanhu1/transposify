import Foundation

/// Deterministic onboarding state-machine checks. Unlike a live first-run
/// test, these cannot raise a privacy prompt or depend on Spotify being
/// installed, running, or signed in.
enum OnboardingTest {
    static func run() -> Never {
        var passed = 0
        var failed = 0

        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                print("PASS  \(name)")
                passed += 1
            } else {
                print("FAIL  \(name)")
                failed += 1
            }
        }

        print("\n===== Transposify onboarding test =====")

        let missing = SetupFlow.render(SetupScenario.spotifyMissing.input)
        check(missing.spotify.button == "Get Spotify"
              && missing.spotify.mark == .warn,
              "Missing Spotify offers the download")
        check(missing.audio.button == "Allow…" && !missing.audio.enabled
              && missing.control.button == "Allow…" && !missing.control.enabled,
              "Permissions stay blocked until Spotify exists and runs")

        let movedWhileRunning = SetupFlow.render(.init(
            spotifyInstalled: false, spotifyRunning: true,
            audio: .allowed, control: .allowed))
        check(movedWhileRunning.spotify.mark == .good && movedWhileRunning.primaryEnabled,
              "A running Spotify wins over a stale install lookup")

        let closed = SetupFlow.render(SetupScenario.spotifyClosed.input)
        check(closed.spotify.button == "Open Spotify" && closed.spotify.enabled,
              "Installed, closed Spotify can be opened")

        let opening = SetupFlow.render(SetupScenario.spotifyOpening.input)
        check(opening.spotify.busy && !opening.spotify.enabled
              && opening.spotify.status == "Opening Spotify…",
              "Spotify launch has an unambiguous progress state")

        let launchFailed = SetupFlow.render(SetupScenario.spotifyLaunchFailed.input)
        check(launchFailed.spotify.button == "Try Again"
              && launchFailed.spotify.enabled && launchFailed.spotify.mark == .warn,
              "A stalled Spotify launch recovers to retry")

        let fresh = SetupFlow.render(SetupScenario.fresh.input)
        check(fresh.spotify.mark == .good && fresh.spotify.button == nil,
              "Running Spotify completes step one")
        check(fresh.audio.button == "Allow…" && fresh.audio.enabled
              && fresh.control.button == "Allow…" && fresh.control.enabled,
              "Fresh permissions are explicitly user initiated")
        check(!fresh.primaryEnabled && fresh.primaryButton == "Continue",
              "Setup cannot finish before both grants")

        let requesting = SetupFlow.render(SetupScenario.audioRequesting.input)
        check(requesting.audio.busy && requesting.audio.status == "Waiting for macOS…",
              "An in-flight audio request cannot be clicked twice")

        let controlPending = SetupFlow.render(SetupScenario.controlPending.input)
        check(controlPending.audio.mark == .good
              && controlPending.control.button == "Allow…",
              "Granting audio advances cleanly to the remaining step")

        let audioDenied = SetupFlow.render(SetupScenario.audioDenied.input)
        check(audioDenied.audio.button == "Open Settings"
              && audioDenied.audio.mark == .warn,
              "Denied audio routes to System Settings")

        let controlDenied = SetupFlow.render(SetupScenario.controlDenied.input)
        check(controlDenied.audio.mark == .good && controlDenied.audio.button == nil,
              "Completed audio stays completed while control recovers")
        check(controlDenied.control.button == "Open Settings"
              && controlDenied.control.mark == .warn,
              "Denied Automation routes to System Settings")

        let closedAfterGrants = SetupFlow.render(
            SetupScenario.spotifyClosedAfterGrants.input)
        check(closedAfterGrants.audio.mark == .good
              && closedAfterGrants.control.mark == .good,
              "Known grants stay checked when Spotify quits")
        check(!closedAfterGrants.primaryEnabled
              && closedAfterGrants.spotify.button == "Open Spotify",
              "Only Spotify must be recovered after it quits")

        let ready = SetupFlow.render(SetupScenario.ready.input)
        check(ready.title == "Transposify is ready"
              && ready.primaryButton == "Done" && ready.primaryEnabled,
              "All completed steps finish onboarding")

        let unavailable = SetupFlow.render(.init(
            spotifyInstalled: true, spotifyRunning: true,
            audio: .unavailable("Spotify stopped during the request."),
            control: .allowed))
        check(unavailable.audio.button == "Try Again"
              && unavailable.audio.status == "Spotify stopped during the request.",
              "A transient permission failure remains retryable")

        check(SetupFlow.shouldPresentFromMenu(
            setupCompleted: false, audio: .notAsked),
            "Closing first-run setup leaves a direct way back")
        check(SetupFlow.shouldPresentFromMenu(
            setupCompleted: true, audio: .denied),
            "Revoked essential audio access reopens recovery")
        check(!SetupFlow.shouldPresentFromMenu(
            setupCompleted: true, audio: .unavailable("Spotify is closed.")),
            "A closed Spotify does not block the normal popover")

        // Exhaust the full cross-product so future copy/UI changes cannot
        // accidentally enable completion for a partial or contradictory state.
        let answers: [Permission.State] = [
            .notAsked, .allowed, .denied, .unavailable("Temporarily unavailable.")
        ]
        var matrixIsSound = true
        var matrixCount = 0
        for installed in [false, true] {
            for running in [false, true] {
                for audio in answers {
                    for control in answers {
                        let input = SetupFlow.Input(
                            spotifyInstalled: installed,
                            spotifyRunning: running,
                            audio: audio,
                            control: control)
                        let output = SetupFlow.render(input)
                        let shouldFinish = running && audio.isAllowed && control.isAllowed
                        matrixIsSound = matrixIsSound
                            && output.primaryEnabled == shouldFinish
                            && (output.primaryEnabled ? output.primaryButton == "Done"
                                : output.primaryButton == "Continue")
                        matrixCount += 1
                    }
                }
            }
        }
        check(matrixIsSound && matrixCount == 64,
              "64-state completion matrix has no premature finish path")

        print("=========================================")
        print("\(passed)/\(passed + failed) passed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
