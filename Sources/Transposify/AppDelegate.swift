import AppKit
import AVFoundation
import CoreText

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spotify = SpotifyState()
    private let controller = AudioController()
    private let popover = NSPopover()
    private let artwork = ArtworkStore()
    private var statusItem: NSStatusItem!
    private var popoverVC: PopoverViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if ProcessInfo.processInfo.environment["TRANSPOSIFY_SELFTEST"] == "1" {
            SelfTest.run(controller)
            return
        }

        if let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_SNAPSHOT"] {
            snapshotPopover(to: path)
            return
        }

        if let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_ICON_SNAPSHOT"] {
            Self.snapshotIcon(to: path)
            return
        }

        if ProcessInfo.processInfo.environment["TRANSPOSIFY_RBTEST"] == "1" {
            RubberBandTest.run()
            return
        }

        installMenu()

        // Fixed-width status item (treble clef + signed value) so the value and
        // neighboring menu-bar items never shift between e.g. "0", "−1", "−12".
        // 11 pt rather than the 13 pt system size: the item is fixed-width and
        // has to reserve room for the widest value, so the digit size sets the
        // whole item's width.
        let menuFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let numberWidth = ("\u{2212}12" as NSString).size(withAttributes: [.font: menuFont]).width
        let clef = Self.trebleClefImage()
        // Fixed width so the value and its neighbours never shift, but with no
        // slack beyond what "−12" actually measures. A literal 25% cut would
        // clip the digits: the glyph plus "−12" genuinely needs this much.
        // The +2 is not slack: NSStatusItem insets its button's content, and
        // without it the last digit of "−12" is clipped.
        let statusWidth = ceil(clef.size.width + numberWidth) + 2
        statusItem = NSStatusBar.system.statusItem(withLength: statusWidth)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.font = menuFont
            button.alignment = .center
            button.image = clef
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }

        popoverVC = PopoverViewController(controller: controller, spotify: spotify,
                                          artwork: artwork)
        // Prefetch on track change so the art is already there when the popover
        // opens, rather than appearing a beat later.
        artwork.onChange = { [weak self] in
            DispatchQueue.main.async { self?.popoverVC.refresh() }
        }
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
            log.notice("""
                started: spotify running \(self?.spotify.isRunning == true, privacy: .public) \
                playing \(self?.spotify.isPlaying == true, privacy: .public)
                """)
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log.notice("launched; microphone authorization = \(status.rawValue, privacy: .public)")
        switch status {
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
        if let v = env["TRANSPOSIFY_DEBUG_PITCH"], let n = Int(v) { controller.setSemitones(n) }
        if let v = env["TRANSPOSIFY_DEBUG_ISOLATE"], let mode = IsolateTrack(rawValue: v) {
            controller.setIsolate(mode)
        }
        if let q = env["TRANSPOSIFY_DEBUG_QUIT_AFTER"], let secs = Double(q) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
        }
    }

    private func syncSpotifyToController() {
        if let id = spotify.current?.id { artwork.request(trackID: id) }
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

    /// A treble clef (𝄞, U+1D11E) as a template image, scaled so the glyph's
    /// ink fills the menu bar instead of floating inside the font's line box.
    ///
    /// There's no SF Symbol for a treble clef, so the glyph comes from whichever
    /// installed font has it. Sizing it is the fiddly part: typographic metrics
    /// (`NSAttributedString.size()`) describe the whole font — ascent, descent
    /// and leading — not this glyph, and a clef doesn't fill that box. Measuring
    /// the glyph path bounds instead lets the drawn ink run edge to edge.
    private static func trebleClefImage() -> NSImage {
        let clef = "\u{1D11E}"
        // Leave a hairline top and bottom so the clef doesn't touch the edges.
        let targetHeight = max(12, NSStatusBar.system.thickness - 4)

        func measure(at pointSize: CGFloat) -> (line: CTLine, ink: CGRect) {
            let base = NSFont.systemFont(ofSize: pointSize)
            let font = CTFontCreateForString(
                base, clef as CFString,
                CFRange(location: 0, length: (clef as NSString).length)) as NSFont
            let attributed = NSAttributedString(
                string: clef, attributes: [.font: font, .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(attributed)
            return (line, CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
        }

        // Measure large, then pick the point size whose ink is exactly the
        // height we want. One rescale is enough: glyph outlines scale linearly.
        let probe = measure(at: 100)
        guard probe.ink.height > 0 else { return NSImage(size: NSSize(width: 1, height: 1)) }
        let (line, ink) = measure(at: 100 * targetHeight / probe.ink.height)

        let padding: CGFloat = 0.5   // breathing room before the semitone value
        let size = NSSize(width: max(1, ceil(ink.width + 2 * padding)),
                          height: max(1, ceil(ink.height)))
        let image = NSImage(size: size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            // Shift the ink's own origin to (0, 0) so it sits flush.
            context.textPosition = CGPoint(x: padding - ink.minX, y: -ink.minY)
            CTLineDraw(line, context)
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Debug-only: render the menu-bar icon inside a mock status bar so the
    /// glyph's fit (and any leftover margin) is visible. Magnified 8x.
    private static func snapshotIcon(to path: String) {
        let icon = trebleClefImage()
        let bar = NSStatusBar.system.thickness
        let scale: CGFloat = 8
        let size = NSSize(width: icon.size.width * scale, height: bar * scale)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        // Guide lines at the status bar's top and bottom edges.
        NSColor.systemRed.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: size.width, height: 1).fill()
        NSRect(x: 0, y: size.height - 1, width: size.width, height: 1).fill()

        NSColor.black.setFill()
        let target = NSRect(x: 0, y: (bar - icon.size.height) / 2 * scale,
                            width: icon.size.width * scale,
                            height: icon.size.height * scale)
        icon.draw(in: target)
        image.unlockFocus()

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        FileHandle.standardError.write("""
            icon \(icon.size.width) x \(icon.size.height) pt, status bar \(bar) pt\n
            """.data(using: .utf8)!)
        exit(0)
    }

    /// Debug-only: render the popover to a PNG (dark appearance) and exit.
    private func snapshotPopover(to path: String) {
        controller.testHooks = (engage: { _, _ in }, disengage: { })
        spotify.injectSnapshotTrack(name: "Human Nature", artist: "Michael Jackson")
        controller.spotifyUpdate(running: true, playing: true, trackID: "snapshot")
        controller.setSemitones(2)

        let vc = PopoverViewController(controller: controller, spotify: spotify)
        if let art = ProcessInfo.processInfo.environment["TRANSPOSIFY_SNAPSHOT_ART"],
           let image = NSImage(contentsOfFile: art) {
            vc.seedArtwork(image, for: "snapshot")
        }
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
        appMenu.addItem(withTitle: "Quit Transposify",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}
