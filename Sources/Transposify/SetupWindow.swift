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
/// Two rows, not three: System Audio Recording and Microphone are two grants
/// behind one capability, and splitting them would make the app look three
/// times as hungry as it is.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let spotify: SpotifyState
    private let onFinish: () -> Void

    private var audioRow: PermissionRow!
    private var spotifyRow: PermissionRow!
    private let titleLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private var poll: Timer?

    private static let completedKey = "setupCompleted"

    static var hasRunSetup: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    init(spotify: SpotifyState, onFinish: @escaping () -> Void) {
        self.spotify = spotify
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Transposify"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
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
        onFinish()
    }

    // MARK: - Content

    private func buildContent() -> NSView {
        let title = titleLabel
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.setAccessibilityRole(.staticText)

        let blurb = NSTextField(wrappingLabelWithString:
            "This app requires a few permissions to work correctly.")
        blurb.font = .systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor

        audioRow = PermissionRow(
            symbol: "waveform",
            title: "Hear Spotify",
            detail: "Reads the audio Spotify is playing so it can be shifted. "
                + "macOS calls this System Audio Recording.",
            action: #selector(allowAudio),
            target: self)

        spotifyRow = PermissionRow(
            symbol: "music.note.list",
            title: "Read what's playing",
            detail: "Shows the song title and artwork, and pauses Spotify "
                + "while the separation model loads.",
            action: #selector(allowSpotify),
            target: self)

        primaryButton.title = "Continue"
        primaryButton.bezelStyle = .push
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(finish)

        let buttons = NSStackView(views: [NSView(), primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, blurb, audioRow, spotifyRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: title)

        let container = BackdropView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 460),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            audioRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            spotifyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            blurb.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    // MARK: - State

    private func refresh() {
        audioRow.apply(Permission.audio, settings: Permission.audioPane)
        spotifyRow.apply(Permission.spotifyControl(spotify), settings: .automation)
        // "Continue" once the required grant is in; until then the honest word
        // is that they can leave and come back.
        let ready = Permission.audio.isAllowed
        titleLabel.stringValue = ready
            ? "Transposify is ready"
            : "Grant Transposify permissions"
        primaryButton.title = ready ? "Done" : "Continue"
        // Nothing to continue to until the app can hear Spotify.
        primaryButton.isEnabled = ready
        primaryButton.setAccessibilityHelp(ready
            ? nil : "Available once audio access is granted.")
    }

    @objc private func allowAudio() {
        // Once macOS has been told no it stops asking, so the only honest
        // button is one that opens the pane where it can be changed.
        if audioRow.openSettingsIfDenied() { return }
        audioRow.setBusy(true)
        Permission.requestAudio { [weak self] state in
            guard let self else { return }
            self.audioRow.setBusy(false)
            self.refresh()
            if state == .denied {
                self.audioRow.announce(
                    "Not allowed. Open System Settings to change it.")
            } else if state == .allowed {
                self.audioRow.announce("Audio access allowed.")
            }
        }
    }

    @objc private func allowSpotify() {
        if spotifyRow.openSettingsIfDenied() { return }
        // Sending one Apple Event is what makes macOS ask.
        Permission.spotifySkipped = false
        spotify.refreshNowPlaying()
        refresh()
    }

    @objc private func finish() {
        Self.hasRunSetup = true
        // Leaving without granting Spotify control is a decision, and it is
        // kept: the app will not put the question again on its own.
        if case .allowed = Permission.spotifyControl(spotify) {
            Permission.spotifySkipped = false
        } else {
            Permission.spotifySkipped = true
        }
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

/// One capability: what it is for, whether it has been granted, and the one
/// button that changes that.
private final class PermissionRow: NSView {
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let button = NSButton()
    private let spinner = NSProgressIndicator()
    private var settings: Permission.Pane = .microphone
    private var state: Permission.State = .notAsked

    init(symbol: String, title: String, detail: String,
         action: Selector, target: AnyObject) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        let icon = NSImageView(image: NSImage(
            systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityHidden(true)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)

        let heading = NSStackView(views: [icon, name, NSView()])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 8

        let body = NSTextField(wrappingLabelWithString: detail)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        statusIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        statusIcon.setAccessibilityHidden(true)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = target
        button.action = action

        let footer = NSStackView(views: [statusIcon, statusLabel, spinner, NSView(), button])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6

        let stack = NSStackView(views: [heading, body, footer])
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
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
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
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        button.isEnabled = !busy
    }

    func apply(_ state: Permission.State, settings: Permission.Pane) {
        self.state = state
        self.settings = settings
        // Symbol as well as colour: status must survive being read in
        // greyscale, or by someone who cannot separate red from green.
        switch state {
        case .allowed:
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemGreen
            statusLabel.stringValue = "Allowed"
            statusLabel.textColor = .secondaryLabelColor
            button.isHidden = true
        case .notAsked, .unavailable:
            statusIcon.image = nil
            statusLabel.stringValue = ""
            button.isHidden = false
            button.title = "Allow…"
            button.keyEquivalent = ""
        case .denied:
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemOrange
            statusLabel.stringValue = "Not allowed"
            statusLabel.textColor = .labelColor
            button.isHidden = false
            button.title = "Open Settings"
        }
        setAccessibilityValue(statusLabel.stringValue.isEmpty
            ? "Not granted" : statusLabel.stringValue)
        button.setAccessibilityLabel("\(button.title) for \(accessibilityLabel() ?? "")")
    }

    /// Denied rows send the user to the right pane rather than repeating a
    /// question macOS will no longer put.
    @discardableResult
    func openSettingsIfDenied() -> Bool {
        guard state == .denied else { return false }
        Permission.openSettings(for: settings)
        return true
    }

    func announce(_ message: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
