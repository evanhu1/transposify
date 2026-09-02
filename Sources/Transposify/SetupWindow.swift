import AppKit

/// The complete visible state of setup, kept independent of AppKit so every
/// first-run and recovery combination can be exercised without touching the
/// Mac's real privacy settings.
struct SetupFlow {
    enum SpotifyLaunch: Equatable {
        case idle, opening, failed
    }

    struct Input: Equatable {
        var spotifyInstalled: Bool
        var spotifyRunning: Bool
        var spotifyLaunch: SpotifyLaunch = .idle
        var audio: Permission.State
        var control: Permission.State
        var audioRequesting = false
    }

    struct Row: Equatable {
        enum Mark: Equatable { case none, good, warn }
        var mark: Mark = .none
        var status = ""
        /// nil hides the button because the step is already done.
        var button: String? = nil
        var enabled = true
        var busy = false
    }

    struct Output: Equatable {
        var title: String
        var primaryButton: String
        var primaryEnabled: Bool
        var spotify: Row
        var audio: Row
        var control: Row
    }

    static func render(_ input: Input) -> Output {
        let spotify: Row
        if input.spotifyRunning {
            spotify = Row(mark: .good, status: "Open", button: nil)
        } else if !input.spotifyInstalled {
            spotify = Row(mark: .warn, status: "Spotify isn't installed.",
                          button: "Get Spotify")
        } else {
            switch input.spotifyLaunch {
            case .idle:
                spotify = Row(button: "Open Spotify")
            case .opening:
                spotify = Row(status: "Opening Spotify…", button: "Open Spotify",
                              enabled: false, busy: true)
            case .failed:
                spotify = Row(mark: .warn, status: "Spotify didn't open. Try again.",
                              button: "Try Again")
            }
        }

        var audio = permissionRow(input.audio, spotifyRunning: input.spotifyRunning)
        if input.audioRequesting, !input.audio.isAllowed {
            audio.status = "Waiting for macOS…"
            audio.busy = true
        }
        let control = permissionRow(input.control, spotifyRunning: input.spotifyRunning)
        let ready = input.spotifyRunning && input.audio.isAllowed && input.control.isAllowed
        return Output(
            title: ready ? "Transposify is ready" : "Set up Transposify",
            primaryButton: ready ? "Done" : "Continue",
            primaryEnabled: ready,
            spotify: spotify,
            audio: audio,
            control: control)
    }

    /// The menu-bar icon is also the recovery path after the first-run window
    /// is closed. Audio is essential; an unavailable answer while Spotify is
    /// closed is not a denial and should not block the otherwise useful UI.
    static func shouldPresentFromMenu(setupCompleted: Bool,
                                      audio: Permission.State) -> Bool {
        !setupCompleted || audio == .denied
    }

    private static func permissionRow(_ state: Permission.State,
                                      spotifyRunning: Bool) -> Row {
        // A known grant remains a grant when Spotify quits. Keeping the check
        // visible means the user only has to recover the step that changed.
        if state.isAllowed {
            return Row(mark: .good, status: "Allowed", button: nil)
        }
        if !spotifyRunning {
            return Row(status: "Do step 1 first.", button: "Allow…", enabled: false)
        }
        switch state {
        case .denied:
            return Row(mark: .warn, status: "Not allowed", button: "Open Settings")
        case .unavailable(let why):
            return Row(mark: .warn, status: why, button: "Try Again")
        case .notAsked:
            return Row(button: "Allow…")
        case .allowed:
            preconditionFailure("handled above")
        }
    }
}

/// Stable states used by the snapshot and behavioral onboarding rig. None of
/// these inspect, request, or mutate real permissions.
enum SetupScenario: String, CaseIterable {
    case spotifyMissing = "spotify-missing"
    case spotifyClosed = "spotify-closed"
    case spotifyOpening = "spotify-opening"
    case spotifyLaunchFailed = "spotify-launch-failed"
    case fresh
    case audioRequesting = "audio-requesting"
    case controlPending = "control-pending"
    case audioDenied = "audio-denied"
    case controlDenied = "control-denied"
    case spotifyClosedAfterGrants = "spotify-closed-after-grants"
    case ready

    var input: SetupFlow.Input {
        switch self {
        case .spotifyMissing:
            return .init(spotifyInstalled: false, spotifyRunning: false,
                         audio: .notAsked, control: .notAsked)
        case .spotifyClosed:
            return .init(spotifyInstalled: true, spotifyRunning: false,
                         audio: .notAsked, control: .notAsked)
        case .spotifyOpening:
            return .init(spotifyInstalled: true, spotifyRunning: false,
                         spotifyLaunch: .opening, audio: .notAsked, control: .notAsked)
        case .spotifyLaunchFailed:
            return .init(spotifyInstalled: true, spotifyRunning: false,
                         spotifyLaunch: .failed, audio: .notAsked, control: .notAsked)
        case .fresh:
            return .init(spotifyInstalled: true, spotifyRunning: true,
                         audio: .notAsked, control: .notAsked)
        case .audioRequesting:
            return .init(spotifyInstalled: true, spotifyRunning: true,
                         audio: .notAsked, control: .notAsked, audioRequesting: true)
        case .controlPending:
            return .init(spotifyInstalled: true, spotifyRunning: true,
                         audio: .allowed, control: .notAsked)
        case .audioDenied:
            return .init(spotifyInstalled: true, spotifyRunning: true,
                         audio: .denied, control: .notAsked)
        case .controlDenied:
            return .init(spotifyInstalled: true, spotifyRunning: true,
                         audio: .allowed, control: .denied)
        case .spotifyClosedAfterGrants:
            return .init(spotifyInstalled: true, spotifyRunning: false,
                         audio: .allowed, control: .allowed)
        case .ready:
            return .init(spotifyInstalled: true, spotifyRunning: true,
                         audio: .allowed, control: .allowed)
        }
    }
}

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
    private let fixedState: SetupFlow.Input?
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
    private var spotifyOpenDeadline: Date?
    private var spotifyLaunchFailed = false
    private var audioRequesting = false
    /// A settings button was pressed. When this window becomes key again the
    /// user has returned, and the relevant answer should be re-read.
    private var returningFromSettings: Permission.Pane?
    /// Automation can only be re-read while Spotify is running. Preserve the
    /// retry when the user returns from Settings after Spotify has quit.
    private var needsAutomationRecheck = false

    private static let completedKey = "setupCompleted"

    static var hasRunSetup: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    init(spotify: SpotifyState, fixedState: SetupFlow.Input? = nil,
         onFinish: @escaping (Bool) -> Void) {
        self.spotify = spotify
        self.fixedState = fixedState
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
        if fixedState == nil { spotify.startObserving() }
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
        if fixedState == nil {
            if poll == nil {
                poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                    [weak self] _ in self?.refresh()
                }
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard fixedState == nil else { return }
        let pane = returningFromSettings
        returningFromSettings = nil
        // Revalidate every known answer when the user returns. This covers the
        // buttons below and also a permission changed from System Settings
        // opened independently. Unknown answers are skipped so this can never
        // raise a consent prompt the user did not request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.spotify.refreshRunningState()
            if pane == .audioRecording || pane == .microphone {
                if self.spotify.isRunning {
                    Permission.checkAudio {
                        [weak self] state in
                        self?.refresh()
                        if state.isAllowed {
                            self?.audioRow.announce("Audio access allowed.")
                        }
                    }
                } else {
                    self.refresh()
                }
            } else if Permission.audioAsked, self.spotify.isRunning,
                      !self.audioRequesting {
                Permission.checkAudio {
                    [weak self] state in
                    self?.refresh()
                }
            }

            if pane == .automation {
                if self.spotify.isRunning {
                    self.spotify.refreshNowPlaying()
                    self.needsAutomationRecheck = false
                } else {
                    self.needsAutomationRecheck = true
                }
                self.refresh()
                if Permission.spotifyControl(self.spotify).isAllowed {
                    self.controlRow.announce("Spotify access allowed.")
                }
            } else if self.spotify.isRunning, self.spotify.automation != .unknown {
                self.spotify.refreshNowPlaying()
                self.refresh()
            }
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
            "This app needs a few permissions to work properly. Your audio stays "
            + "on this Mac and is only used for processing.")
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
                + "while the separation model loads. macOS calls this Automation.",
            action: #selector(allowControl),
            target: self)

        primaryButton.title = "Continue"
        primaryButton.bezelStyle = .push
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(finish)

        let buttons = NSView()
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        buttons.addSubview(primaryButton)
        NSLayoutConstraint.activate([
            primaryButton.trailingAnchor.constraint(equalTo: buttons.trailingAnchor),
            primaryButton.topAnchor.constraint(equalTo: buttons.topAnchor),
            primaryButton.bottomAnchor.constraint(equalTo: buttons.bottomAnchor),
        ])

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
        if let fixedState {
            apply(SetupFlow.render(fixedState))
            return
        }
        // Nothing has started Spotify monitoring yet at this point in launch.
        spotify.refreshRunningState()
        if spotify.isRunning {
            openingSpotify = false
            spotifyOpenDeadline = nil
            spotifyLaunchFailed = false
        } else if openingSpotify, let deadline = spotifyOpenDeadline, Date() >= deadline {
            openingSpotify = false
            spotifyOpenDeadline = nil
            spotifyLaunchFailed = true
            spotifyRow.announce("Spotify didn't open. Try again.")
        }

        // Opening Spotify can turn an answer we could not read into one we
        // can. Asking again costs a tap and no dialog.
        if spotify.isRunning != lastRecheck {
            lastRecheck = spotify.isRunning
            Permission.recheckIfAsked(running: spotify.isRunning) { [weak self] _ in
                self?.refresh()
            }
            if spotify.isRunning, needsAutomationRecheck {
                needsAutomationRecheck = false
                spotify.refreshNowPlaying()
            }
        }
        let launch: SetupFlow.SpotifyLaunch = openingSpotify ? .opening
            : (spotifyLaunchFailed ? .failed : .idle)
        apply(SetupFlow.render(.init(
            spotifyInstalled: spotify.isInstalled,
            spotifyRunning: spotify.isRunning,
            spotifyLaunch: launch,
            audio: Permission.audio,
            control: Permission.spotifyControl(spotify),
            audioRequesting: audioRequesting)))
    }

    private func apply(_ output: SetupFlow.Output) {
        spotifyRow.apply(output.spotify)
        audioRow.apply(output.audio)
        controlRow.apply(output.control)
        titleLabel.stringValue = output.title
        primaryButton.title = output.primaryButton
        primaryButton.isEnabled = output.primaryEnabled
        primaryButton.setAccessibilityHelp(output.primaryEnabled
            ? nil : "Available once all three steps are done.")
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
        spotifyLaunchFailed = false
        spotifyOpenDeadline = Date(timeIntervalSinceNow: 12)
        if !spotify.launch() {
            openingSpotify = false
            spotifyOpenDeadline = nil
            spotifyLaunchFailed = true
        }
        refresh()
        spotifyRow.announce(openingSpotify ? "Opening Spotify." : "Spotify didn't open.")
    }

    @objc private func allowAudio() {
        if Permission.audio == .denied {
            let pane = Permission.audioPane
            returningFromSettings = pane
            if !Permission.openSettings(for: pane) {
                returningFromSettings = nil
                audioRow.announce("System Settings couldn't be opened. Try again.")
            }
            return
        }
        audioRequesting = true
        refresh()
        Permission.requestAudio { [weak self] state in
            guard let self else { return }
            self.audioRequesting = false
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
            returningFromSettings = .automation
            if !Permission.openSettings(for: .automation) {
                returningFromSettings = nil
                controlRow.announce("System Settings couldn't be opened. Try again.")
            }
            return
        }
        guard spotify.isRunning else { return }
        // Sending one Apple Event is what makes macOS ask.
        spotify.refreshNowPlaying()
        refresh()
    }

    @objc private func finish() {
        let ready: Bool
        if let fixedState {
            ready = SetupFlow.render(fixedState).primaryEnabled
        } else {
            spotify.refreshRunningState()
            ready = spotify.isRunning
                && Permission.audio.isAllowed
                && Permission.spotifyControl(spotify).isAllowed
        }
        guard ready else {
            refresh()
            return
        }
        // Fixed states belong to the UI rig and must never alter the real
        // first-run preference.
        if fixedState == nil { Self.hasRunSetup = true }
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
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private let spinner = NSProgressIndicator()
    private var model = SetupFlow.Row()
    private var statusLabelWithIcon: NSLayoutConstraint!
    private var statusLabelWithoutIcon: NSLayoutConstraint!

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

        let headingSpacer = NSView()
        headingSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let heading = NSStackView(views: [icon, name, headingSpacer])
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
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)

        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = target
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Pin this row explicitly. NSStackView leaves stopped progress
        // indicators and hidden buttons under-constrained, which rendered
        // correctly by accident but could change across layout passes.
        let footer = NSView()
        for view in [statusIcon, statusLabel, spinner, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        statusLabelWithIcon = statusLabel.leadingAnchor.constraint(
            equalTo: statusIcon.trailingAnchor, constant: 6)
        statusLabelWithoutIcon = statusLabel.leadingAnchor.constraint(
            equalTo: footer.leadingAnchor)
        NSLayoutConstraint.activate([
            statusIcon.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
            statusLabelWithoutIcon,
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor,
                                                  constant: -6),
            spinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            spinner.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            button.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            button.topAnchor.constraint(equalTo: footer.topAnchor),
            button.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])

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

    func apply(_ model: SetupFlow.Row) {
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
        let hasStatusIcon = model.mark != .none
        statusIcon.isHidden = !hasStatusIcon
        statusLabelWithoutIcon.isActive = !hasStatusIcon
        statusLabelWithIcon.isActive = hasStatusIcon
        statusLabel.stringValue = model.status
        statusLabel.textColor = model.mark == .warn ? .labelColor : .secondaryLabelColor

        let working = model.busy
        spinner.isHidden = !working
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
