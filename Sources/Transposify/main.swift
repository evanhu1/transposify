import AppKit

// Headless checks; never run in normal use.
if let spec = ProcessInfo.processInfo.environment["TRANSPOSIFY_SEPARATE_FILE"] {
    SeparationFileTest.run(spec)
}
if ProcessInfo.processInfo.environment["TRANSPOSIFY_TEST_INSTALL"] == "1" {
    ModelInstallTest.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
