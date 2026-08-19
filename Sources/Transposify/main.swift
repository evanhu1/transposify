import AppKit

// Headless separation check; never runs in normal use.
if let spec = ProcessInfo.processInfo.environment["TRANSPOSIFY_SEPARATE_FILE"] {
    SeparationFileTest.run(spec)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
