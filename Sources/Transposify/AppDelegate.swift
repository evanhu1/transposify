import AppKit
import AVFoundation
import CoreText

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let spotify = SpotifyState()
    private let controller = AudioController()
    private let popover = NSPopover()
    private let artwork = ArtworkStore()
    private var statusItem: NSStatusItem!
    private var popoverVC: PopoverViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if ProcessInfo.processInfo.environment["TRANSPOSIFY_ONBOARDING_UI_TEST"] == "1" {
            OnboardingUITest.run(spotify: spotify)
        }

        if ProcessInfo.processInfo.environment["TRANSPOSIFY_SELFTEST"] == "1" {
            SelfTest.run(controller)
            return
        }

        if let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_SETUP_SNAPSHOT"] {
            let scenarioName = ProcessInfo.processInfo.environment[
                "TRANSPOSIFY_SETUP_SCENARIO"]
            let scenario = scenarioName.flatMap(SetupScenario.init(rawValue:))
            if let scenarioName, scenario == nil {
                FileHandle.standardError.write(
                    "Unknown onboarding scenario: \(scenarioName)\n".data(using: .utf8)!)
                exit(2)
            }
            let window = SetupWindowController(spotify: spotify,
                                               fixedState: scenario?.input) { _ in }
            switch ProcessInfo.processInfo.environment["TRANSPOSIFY_SETUP_APPEARANCE"] {
            case "light": window.window?.appearance = NSAppearance(named: .aqua)
            case "dark": window.window?.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
            window.present()
            for _ in 0..<30 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
            if let content = window.window?.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }

        if let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_SNAPSHOT"] {
            snapshotPopover(to: path)
            return
        }

        if let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_POPOVER_SNAPSHOT"] {
            popoverSnapshot(to: path)
            return
        }


        if let path = ProcessInfo.processInfo.environment["TRANSPOSIFY_GALLERY"] {
            DesignGallery.run(to: path)
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
        // Not `.transient`: that closes on any loss of focus, and opening the
        // popover pokes Spotify over Apple Events, which can bring Spotify
        // forward for a moment — the popover then vanished as it appeared.
        // Dismissal is handled here instead: a click anywhere outside, Esc,
        // or a real switch to another app (not one in the first second).
        popover.behavior = .applicationDefined
        popover.delegate = self

        controller.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshUI() }
        }
        controller.setSpotifyPlaying = { [weak self] playing in
            self?.spotify.setPlaying(playing) ?? false
        }

        requestMicrophoneThenStart()
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private var setupWindow: SetupWindowController?

    /// Nothing is asked of macOS until the setup window asks it. The raw
    /// prompts used to fire at launch with no explanation, and a third
    /// appeared later when Spotify was first queried — three system dialogs,
    /// one of them naming the microphone, for an app that never opens one.
    private func requestMicrophoneThenStart() {
        // Watching Spotify sends it nothing, and setup needs to know whether
        // it is playing before any question is put.
        spotify.startObserving()

        let begin: () -> Void = { [weak self] in
            // Wired here, not at launch: it fetches artwork, which is an Apple
            // Event, and during setup that would put the Automation question
            // the moment a song started playing.
            self?.spotify.onChange = { [weak self] in
                DispatchQueue.main.async { self?.syncSpotifyToController() }
            }
            // Sending Spotify an Apple Event is what makes macOS ask about
            // Automation, so it is only done on behalf of someone who has
            // already said yes. Anyone else is watched over playback
            // notifications, which need no permission, until they open the
            // popover and ask for themselves.
            if SetupWindowController.hasRunSetup {
                self?.spotify.start()
            } else {
                self?.spotify.startObserving()
            }
            self?.syncSpotifyToController()
            self?.applyDebugHooks()
            log.notice("""
                started: spotify running \(self?.spotify.isRunning == true, privacy: .public) \
                playing \(self?.spotify.isPlaying == true, privacy: .public)
                """)
        }
        // Setup is for people who have not done it, and for a grant that has
        // since been taken away. Anything else — Spotify closed, Spotify
        // paused — leaves the probe unable to tell, and a window that opens
        // every time the Mac starts before Spotify does is worse than no
        // window at all.
        guard Permission.audioAsked else {
            presentSetup(then: begin)
            return
        }
        // Settle the audio answer before deciding, but only where doing so
        // cannot put a question: probing is a real capture, and for a user
        // who has never been asked that would be a dialog out of nowhere.
        Permission.checkAudio { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                if state.isAllowed {
                    // Nothing to explain, including for anyone upgrading from
                    // a version that asked at launch.
                    SetupWindowController.hasRunSetup = true
                    begin()
                } else if state == .denied || !SetupWindowController.hasRunSetup {
                    self.presentSetup(then: begin)
                } else {
                    begin()
                }
            }
        }
    }

    /// Show setup, and carry on once it closes either way — a person who
    /// closes it should still get a working menu bar item.
    func presentSetup(then done: (() -> Void)? = nil) {
        if let setupWindow {
            setupWindow.present()
            return
        }
        let window = SetupWindowController(spotify: spotify) { [weak self] completed in
            guard let self else { return }
            self.setupWindow = nil
            if Permission.audio.isAllowed {
                self.controller.reportPermissionAllowed()
            } else {
                self.controller.reportPermissionDenied()
            }
            done?()
            self.refreshUI()
            // Finishing setup should end somewhere, and the somewhere is the
            // thing they have just been given permission to use. A short wait
            // lets the window finish closing and the app drop back to being
            // an accessory before the popover is shown.
            guard completed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showPopover()
            }
        }
        setupWindow = window
        window.present()
    }

    /// Env-gated affordances for headless testing (no-ops in normal use).
    private func applyDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        if let v = env["TRANSPOSIFY_DEBUG_PITCH"], let n = Int(v) { controller.setSemitones(n) }
        if let v = env["TRANSPOSIFY_DEBUG_ISOLATE"], let p = MixPreset(rawValue: v) {
            controller.setPreset(p)
        }
        // "12:vocals" — flip isolation mid-playback, to exercise the model
        // load happening under live audio.
        // "8:vocals,14:off,18:vocals" — several switches, comma separated.
        if let spec = env["TRANSPOSIFY_DEBUG_SWITCH_AFTER"] {
            for step in spec.split(separator: ",") {
                let parts = step.split(separator: ":").map(String.init)
                guard parts.count == 2, let delay = Double(parts[0]),
                      let preset = MixPreset(rawValue: parts[1]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    log.notice("debug: switching to \(preset.rawValue, privacy: .public)")
                    self?.controller.setPreset(preset)
                }
            }
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

    private func showPopover() {
        guard !popover.isShown else { return }
        togglePopover()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Closing the first-run window is allowed, but it must not strand
            // the user or make the next click raise an unexplained Automation
            // prompt. The menu-bar icon is the natural way back into setup.
            guard !SetupFlow.shouldPresentFromMenu(
                setupCompleted: SetupWindowController.hasRunSetup,
                audio: Permission.audio) else {
                presentSetup()
                return
            }
            // Playback notifications keep now-playing current; the Apple
            // Events query is only for the first look, and for recovering
            // once Automation is granted after the fact.
            if spotify.current == nil || spotify.automation != .granted {
                spotify.refreshNowPlaying()
            }
            if let id = spotify.current?.id { artwork.request(trackID: id) }
            popoverVC.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            beginDismissWatch()
        }
    }

    // MARK: - Popover dismissal

    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var popoverShownAt = Date.distantPast

    /// Processes whose windows are system prompts — permission consent,
    /// password entry — rather than the user going somewhere else. The
    /// popover stays open while one of these is in front, so answering
    /// "Allow" to the System Audio Recording or Automation prompt lands
    /// the user back where they were.
    private static let systemPromptBundleIDs: Set<String> = [
        "com.apple.UserNotificationCenter",
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
    ]

    private var systemPromptIsFrontmost: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.systemPromptBundleIDs.contains(id)
    }

    private func beginDismissWatch() {
        popoverShownAt = Date()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, !self.systemPromptIsFrontmost else { return }
            self.popover.performClose(nil)
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.popover.isShown else { return event }
            self.popover.performClose(nil)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // A focus wobble while the popover is still appearing is not the
            // user leaving, and neither is a system prompt taking the front;
            // a switch to another app a second or more later is.
            if Date().timeIntervalSince(self.popoverShownAt) > 1.0,
               !self.systemPromptIsFrontmost {
                self.popover.performClose(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
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
    /// Render the popover the way it is actually used — inside an NSPopover on
    /// a window — and report the header's frames.
    ///
    /// Worth keeping: `snapshotPopover` lays the view out on its own, which
    /// sizes it to `fittingSize` and so quietly grants every label its full
    /// intrinsic width. The popover imposes a width instead, and header bugs
    /// that only appear under an imposed width have got past that snapshot
    /// twice now — once truncating too late, once far too early.
    private func popoverSnapshot(to path: String) {
        controller.testHooks = (engage: { _, _ in }, disengage: { })
        let env = ProcessInfo.processInfo.environment
        spotify.injectSnapshotTrack(
            name: env["TRANSPOSIFY_SNAPSHOT_TITLE"] ?? "Human Nature",
            artist: env["TRANSPOSIFY_SNAPSHOT_ARTIST"] ?? "Michael Jackson")
        controller.spotifyUpdate(running: true, playing: true, trackID: "snapshot")
        controller.setPreset(.all)

        let vc = PopoverViewController(controller: controller, spotify: spotify)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 280, y: 300, width: 20, height: 20))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .applicationDefined
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        for _ in 0..<40 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        vc.refresh()
        vc.view.layoutSubtreeIfNeeded()
        for _ in 0..<20 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        vc.reportHeaderFrames()

        let content = vc.view
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        exit(0)
    }

    private func snapshotPopover(to path: String) {
        controller.testHooks = (engage: { _, _ in }, disengage: { })
        // Overridable so a long title can be checked against the header's width.
        let env = ProcessInfo.processInfo.environment
        spotify.injectSnapshotTrack(
            name: env["TRANSPOSIFY_SNAPSHOT_TITLE"] ?? "Human Nature",
            artist: env["TRANSPOSIFY_SNAPSHOT_ARTIST"] ?? "Michael Jackson")
        controller.spotifyUpdate(running: true, playing: true, trackID: "snapshot")
        controller.setSemitones(2)

        // TRANSPOSIFY_SNAPSHOT_MIX picks the mix shown; anything but "all"
        // needs the model, so optionally wait for it rather than capturing the
        // "Preparing separation…" state.
        let wanted = ProcessInfo.processInfo.environment["TRANSPOSIFY_SNAPSHOT_MIX"]
        controller.setPreset(wanted.flatMap(MixPreset.init(rawValue:)) ?? .backing)
        if ProcessInfo.processInfo.environment["TRANSPOSIFY_SNAPSHOT_WAIT"] == "1" {
            let deadline = Date().addingTimeInterval(20)
            while controller.preparingModel && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }
        let vc = PopoverViewController(controller: controller, spotify: spotify)
        if let art = ProcessInfo.processInfo.environment["TRANSPOSIFY_SNAPSHOT_ART"],
           let image = NSImage(contentsOfFile: art) {
            vc.seedArtwork(image, for: "snapshot")
        }
        let content = vc.view
        content.appearance = NSAppearance(named: .darkAqua)
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let report = "popover fits \(Int(size.width))x\(Int(size.height)) pt, "
            + "preferred \(Int(vc.preferredContentSize.width))x"
            + "\(Int(vc.preferredContentSize.height))\n"
        FileHandle.standardError.write(report.data(using: .utf8)!)
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["TRANSPOSIFY_GALLERY_DEBUG"] != nil {
            DesignGallery.dumpTree(content)
        }

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
