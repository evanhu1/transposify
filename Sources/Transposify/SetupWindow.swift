import AppKit

/// First-run setup: what Transposify needs, in the user's terms, before macOS
/// asks in its own.
///
/// The system's permission dialogs cannot be restyled and give almost no
/// context. "Transposify would like to access the microphone" is alarming for
/// an app that never opens a microphone, so this window says what is about to
/// be asked and why before putting the question. Nothing is asked until a
/// button here is pressed.
///
/// Three steps, and the first one is Spotify itself. Both permissions are
/// answered by talking to Spotify: the audio grant is read by tapping what
/// Spotify plays, and macOS will not put the Automation question about an app
/// that is not running. Asking either one with Spotify closed produced a
/// wrong answer, so the window makes opening Spotify the first step rather
/// than a thing the user is assumed to have done.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let spotify: SpotifyState
    /// Called when the window closes, saying whether setup was finished
    /// rather than simply dismissed.
    private let onFinish: (Bool) -> Void
    private var completed = false

    private var spotifyRow: SetupRow!
    private var audioRow: SetupRow!
    private var controlRow: SetupRow!
    private let titleLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private var poll: Timer?
    /// Set while Spotify is being opened, so the row shows a spinner instead
    /// of a button that has already been pressed.
    private var openingSpotify = false

    private static let completedKey = "setupCompleted"

    static var hasRunSetup: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    init(spotify: SpotifyState, onFinish: @escaping (Bool) -> Void) {
        self.spotify = spotify
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Transposify"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // Watching Spotify sends it nothing. Setup needs to know when it comes
        // up, and Apple Events would put the Automation question early.
        spotify.startObserving()
        let content = buildContent()
        window.contentView = content
        // Size to the content rather than guessing: the copy decides how tall
        // the rows are, and a fixed height would stretch them.
        window.setContentSize(content.fittingSize)
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Spotify can be opened, or permission granted in System Settings,
        // while this is on screen; keep up with it rather than making the
        // user close and reopen.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        // A menu-bar app has no business keeping a Dock icon once its one
        // window is gone.
        NSApp.setActivationPolicy(.accessory)
        onFinish(completed)
    }

    // MARK: - Content

    private func buildContent() -> NSView {
        let title = titleLabel
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.setAccessibilityRole(.staticText)

        let blurb = NSTextField(wrappingLabelWithString:
            "This app needs a few permissions to work properly. All data stays "
            + "local and is only used for audio processing.")
        blurb.font = .systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor

        spotifyRow = SetupRow(
            step: 1,
            title: "Open Spotify",
            detail: nil,
            action: #selector(openSpotify),
            target: self)

        audioRow = SetupRow(
            step: 2,
            title: "Let Transposify hear Spotify",
            detail: "Reads the audio Spotify is playing so it can be shifted. "
                + "macOS calls this System Audio Recording.",
            action: #selector(allowAudio),
            target: self)

        controlRow = SetupRow(
            step: 3,
            title: "Read what's playing",
            detail: "Shows the song title and artwork, and pauses Spotify "
                + "while the separation model loads.",
            action: #selector(allowControl),
            target: self)

        primaryButton.title = "Continue"
        primaryButton.bezelStyle = .push
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(finish)

        let buttons = NSStackView(views: [NSView(), primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let rows = [spotifyRow!, audioRow!, controlRow!]
        let stack = NSStackView(views: [title, blurb] + rows + [buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(18, after: blurb)

        let container = BackdropView()
        container.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            container.widthAnchor.constraint(equalToConstant: 460),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            blurb.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        constraints += rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    // MARK: - State

    /// What the last quiet re-check was run against. Probing is a real
    /// capture, so it runs when Spotify comes up rather than every second.
    private var lastRecheck: Bool?

    private func refresh() {
        // Nothing has started Spotify monitoring yet at this point in launch.
        spotify.refreshRunningState()
        if spotify.isRunning { openingSpotify = false }

        // Opening Spotify can turn an answer we could not read into one we
        // can. Asking again costs a tap and no dialog.
        if spotify.isRunning != lastRecheck {
            lastRecheck = spotify.isRunning
            Permission.recheckIfAsked(running: spotify.isRunning)
        }

        spotifyRow.apply(spotifyStep())
        audioRow.apply(permissionStep(Permission.audio,
                                      blockedUntilSpotifyRuns: true))
        controlRow.apply(permissionStep(Permission.spotifyControl(spotify),
                                        blockedUntilSpotifyRuns: true))

        // "Continue" once every step is in; until then the honest word is that
        // they can leave and come back.
        let ready = spotify.isRunning
            && Permission.audio.isAllowed
            && Permission.spotifyControl(spotify).isAllowed
        titleLabel.stringValue = ready
            ? "Transposify is ready"
            : "Set up Transposify"
        primaryButton.title = ready ? "Done" : "Continue"
        // Every step is needed, so there is nothing to continue to until they
        // are all done.
        primaryButton.isEnabled = ready
        primaryButton.setAccessibilityHelp(ready
            ? nil : "Available once all three steps are done.")
    }

    private func spotifyStep() -> SetupRow.Model {
        guard spotify.isInstalled else {
            // Nothing here can be answered without Spotify, and no amount of
            // waiting will install it, so say so instead of spinning.
            return .init(mark: .warn, status: "Spotify isn't installed.",
                         button: "Get Spotify")
        }
        if spotify.isRunning {
            return .init(mark: .good, status: "Open", button: nil)
        }
        return .init(mark: .none, status: "", button: "Open Spotify",
                     busy: openingSpotify)
    }

    private func permissionStep(_ state: Permission.State,
                                blockedUntilSpotifyRuns: Bool) -> SetupRow.Model {
        if state.isAllowed {
            return .init(mark: .good, status: "Allowed", button: nil)
        }
        if blockedUntilSpotifyRuns, !spotify.isRunning {
            // Pressing this with Spotify closed is what produced a wrong
            // answer, so it cannot be pressed until step 1 is done.
            return .init(mark: .none, status: "Do step 1 first.",
                         button: "Allow…", enabled: false)
        }
        switch state {
        case .denied:
            // Once macOS has been told no it stops asking, so the only honest
            // button is one that opens the pane where it can be changed.
            return .init(mark: .warn, status: "Not allowed",
                         button: "Open Settings")
        case .unavailable(let why):
            return .init(mark: .warn, status: why, button: "Allow…")
        default:
            return .init(mark: .none, status: "", button: "Allow…")
        }
    }

    // MARK: - Actions

    @objc private func openSpotify() {
        guard spotify.isInstalled else {
            if let url = URL(string: "https://www.spotify.com/download/") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        openingSpotify = true
        spotify.launch()
        refresh()
        spotifyRow.announce("Opening Spotify.")
    }

    @objc private func allowAudio() {
        if Permission.audio == .denied {
            Permission.openSettings(for: Permission.audioPane)
            return
        }
        audioRow.setBusy(true)
        Permission.requestAudio { [weak self] state in
            guard let self else { return }
            self.audioRow.setBusy(false)
            self.refresh()
            switch state {
            case .allowed: self.audioRow.announce("Audio access allowed.")
            case .denied: self.audioRow.announce(
                "Not allowed. Open System Settings to change it.")
            case .unavailable(let why): self.audioRow.announce(why)
            case .notAsked: break
            }
        }
    }

    @objc private func allowControl() {
        if Permission.spotifyControl(spotify) == .denied {
            Permission.openSettings(for: .automation)
            return
        }
        guard spotify.isRunning else { return }
        // Sending one Apple Event is what makes macOS ask.
        spotify.refreshNowPlaying()
        refresh()
    }

    @objc private func finish() {
        Self.hasRunSetup = true
        completed = true
        window?.performClose(nil)
    }
}

/// The window's own background. A plain NSView draws nothing, which leaves
/// label text sitting on whatever is behind it.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// One step: what it is for, where it stands, and the one button that moves
/// it along.
private final class SetupRow: NSView {
    /// What the row shows right now. The controller owns every decision; the
    /// row only draws.
    struct Model {
        enum Mark { case none, good, warn }
        var mark: Mark = .none
        var status: String = ""
        /// nil hides the button — there is nothing left to press.
        var button: String?
        var enabled: Bool = true
        var busy: Bool = false
    }

    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private let spinner = NSProgressIndicator()
    /// Set by `setBusy` while a request is in flight, and kept across the
    /// `apply` calls the poll timer makes.
    private var busy = false
    private var model = Model()

    init(step: Int, title: String, detail: String?,
         action: Selector, target: AnyObject) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        // The step number is the icon: the order is the point of this window.
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "\(step).circle.fill",
            accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityHidden(true)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)

        let heading = NSStackView(views: [icon, name, NSView()])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 8

        // A step whose title says everything gets no second line.
        let body = detail.map { text -> NSTextField in
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
        }

        statusIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        statusIcon.setAccessibilityHidden(true)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = target
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let footer = NSStackView(views: [statusIcon, statusLabel, spinner, button])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        // The status text takes the slack, so a long line wraps instead of
        // pushing the button off the row.
        footer.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [heading, body, footer].compactMap { $0 })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        if let body {
            body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Step \(step). \(title)")
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        apply(model)
    }

    func apply(_ model: Model) {
        self.model = model
        // Symbol as well as colour: status must survive being read in
        // greyscale, or by someone who cannot separate red from green.
        switch model.mark {
        case .none:
            statusIcon.image = nil
        case .good:
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemGreen
        case .warn:
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemOrange
        }
        statusLabel.stringValue = model.status
        statusLabel.textColor = model.mark == .warn ? .labelColor : .secondaryLabelColor

        let working = busy || model.busy
        working ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)

        button.isHidden = model.button == nil
        button.title = model.button ?? ""
        button.isEnabled = model.enabled && !working

        setAccessibilityValue(model.status.isEmpty ? "Not done" : model.status)
        button.setAccessibilityLabel("\(button.title) for \(accessibilityLabel() ?? "")")
    }

    func announce(_ message: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
