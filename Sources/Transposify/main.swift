import AppKit

// Headless checks; never run in normal use.
if ProcessInfo.processInfo.environment["TRANSPOSIFY_UNREGISTER_LOGIN"] == "1" {
    // uninstall.sh: only the app can remove its own launch-at-login entry.
    LoginItem.set(false)
    exit(0)
}
if let spec = ProcessInfo.processInfo.environment["TRANSPOSIFY_SIMULATE"] {
    PacedSimulator.run(spec)
}
if let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_PREDICT_BENCH"] {
    PredictBench.run(path)
}
if let spec = ProcessInfo.processInfo.environment["TRANSPOSIFY_SEPARATE_FILE"] {
    SeparationFileTest.run(spec)
}
if ProcessInfo.processInfo.environment["TRANSPOSIFY_RBTEST"] == "1" {
    RubberBandTest.run()
}
if ProcessInfo.processInfo.environment["TRANSPOSIFY_TEST_INSTALL"] == "1" {
    ModelInstallTest.run()
}
if ProcessInfo.processInfo.environment["TRANSPOSIFY_SELFTEST"] == "1" {
    let controller = AudioController()
    SelfTest.run(controller)
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
