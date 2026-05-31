import AppKit
import AVFoundation
import CoreText

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotify = SpotifyState()
    private let controller = AudioController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var popoverVC: PopoverViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if ProcessInfo.processInfo.environment["TRANSPOSER_SELFTEST"] == "1" {
            SelfTest.run(controller)
            return
        }

        if let path = ProcessInfo.processInfo.environment["TRANSPOSER_SNAPSHOT"] {
            snapshotPopover(to: path)
            return
        }

        if ProcessInfo.processInfo.environment["TRANSPOSER_RBTEST"] == "1" {
            RubberBandTest.run()
            return
        }

        installMenu()

        // Fixed-width status item (treble clef + signed value) so the value and
        // neighboring menu-bar items never shift between e.g. "0", "−1", "−12".
        let menuFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let numberWidth = ("\u{2212}12" as NSString).size(withAttributes: [.font: menuFont]).width
        let clef = Self.trebleClefImage()
        statusItem = NSStatusBar.system.statusItem(withLength: ceil(clef.size.width + numberWidth) + 6)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.font = menuFont
            button.alignment = .center
            button.image = clef
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }

        popoverVC = PopoverViewController(controller: controller, spotify: spotify)
        popover.contentViewController = popoverVC
        popover.behavior = .transient

        controller.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshUI() }
        }
        spotify.onChange = { [weak self] in
            DispatchQueue.main.async { self?.syncSpotifyToController() }
        }

        requestMicrophoneThenStart()
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    /// Process taps are gated on Microphone (kTCCServiceMicrophone) access.
    /// Begin monitoring Spotify once we know the permission outcome.
    private func requestMicrophoneThenStart() {
        let begin: () -> Void = { [weak self] in
            self?.spotify.start()
            self?.syncSpotifyToController()
            self?.applyDebugHooks()
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if !granted { self.controller.reportPermissionDenied() }
                    begin()
                }
            }
        default:
            controller.reportPermissionDenied()
            begin()
        }
    }

    /// Env-gated affordances for headless testing (no-ops in normal use).
    private func applyDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        if let v = env["TRANSPOSER_DEBUG_PITCH"], let n = Int(v) { controller.setSemitones(n) }
        if env["TRANSPOSER_DEBUG_KARAOKE"] == "1" { controller.setKaraoke(true) }
        if let q = env["TRANSPOSER_DEBUG_QUIT_AFTER"], let secs = Double(q) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
        }
    }

    private func syncSpotifyToController() {
        controller.spotifyUpdate(running: spotify.isRunning,
                                 playing: spotify.isPlaying,
                                 trackID: spotify.current?.id)
        refreshUI()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverVC.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refreshUI() {
        let s = controller.semitones
        statusItem.button?.title = s == 0 ? "0" : (s > 0 ? "+\(s)" : "\u{2212}\(abs(s))")
        if popover.isShown { popoverVC.refresh() }
    }

    /// A treble clef (𝄞, U+1D11E) as a template image. There's no SF Symbol
    /// for it, so we render the glyph from whichever installed font has it.
    private static func trebleClefImage() -> NSImage {
        let clef = "\u{1D11E}"
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize + 3)
        let font = CTFontCreateForString(
            base, clef as CFString,
            CFRange(location: 0, length: (clef as NSString).length)) as NSFont
        let attributed = NSAttributedString(string: clef,
                                            attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = attributed.size()
        let imageSize = NSSize(width: max(1, ceil(size.width)) + 2, height: max(1, ceil(size.height)))
        let image = NSImage(size: imageSize)
        image.lockFocus()
        attributed.draw(at: NSPoint(x: (imageSize.width - size.width) / 2, y: 0))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Debug-only: render the popover to a PNG (dark appearance) and exit.
    private func snapshotPopover(to path: String) {
        controller.testHooks = (engage: { _, _ in }, disengage: { })
        spotify.injectSnapshotTrack(name: "Human Nature", artist: "Michael Jackson")
        controller.spotifyUpdate(running: true, playing: true, trackID: "snapshot")
        controller.setSemitones(2)

        let vc = PopoverViewController(controller: controller, spotify: spotify)
        let content = vc.view
        content.appearance = NSAppearance(named: .darkAqua)
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)

        let host = NSView(frame: content.bounds)
        host.wantsLayer = true
        host.appearance = NSAppearance(named: .darkAqua)
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        host.addSubview(content)
        host.layoutSubtreeIfNeeded()

        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
        exit(0)
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Transposer",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}
