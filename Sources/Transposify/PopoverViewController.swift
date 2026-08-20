import AppKit

/// Accent used for the slider knob and the active transpose value.
private let transposeAccent = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)

/// Slider with a flat gray track and an accent knob.
private final class TransposeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 4
        var bar = rect
        bar.origin.y = rect.midY - height / 2
        bar.size.height = height
        NSColor(white: 0.5, alpha: 0.30).setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter: CGFloat = 15
        let frame = NSRect(x: knobRect.midX - diameter / 2,
                           y: knobRect.midY - diameter / 2,
                           width: diameter, height: diameter)
        transposeAccent.setFill()
        NSBezierPath(ovalIn: frame).fill()
    }
}

/// The popup shown from the menu bar: now-playing, a one-knob pitch control,
/// and three toggles. Designed for singers, not musicians — direction and
/// plain language over jargon.
final class PopoverViewController: NSViewController {
    private let controller: AudioController
    private let spotify: SpotifyState

    private static let artworkSize: CGFloat = 40
    private let artworkView = NSImageView()
    private let artworkTile = NSView()
    private let artwork: ArtworkStore
    private let trackLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "0")
    private let slider = NSSlider()
    private let resetButton = NSButton()
    private let powerButton = NSButton()
    private let isolatePicker = NSSegmentedControl()
    private let modelLabel = NSTextField(labelWithString: "")
    private let modelButton = NSButton()
    private var modelRow: NSStackView!
    private let rememberSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()
    private var minusButton: NSButton!
    private var plusButton: NSButton!

    /// Rows greyed out (and disabled) while the app is switched off.
    private var inactiveWhenOff: [NSView] = []

    init(controller: AudioController, spotify: SpotifyState,
         artwork: ArtworkStore = ArtworkStore()) {
        self.controller = controller
        self.spotify = spotify
        self.artwork = artwork
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let width: CGFloat = 296

        // Now playing ------------------------------------------------------
        // Album art, with the note glyph as the placeholder it falls back to
        // when there is no track or no Automation permission.
        //
        // The image view goes inside a plain container: NSImageView sizes
        // itself from its image and ignored width/height constraints outright
        // (it came out 40.5 x 47.5 with three required constraints attached
        // and no conflict logged). A plain NSView honours them, and pinning
        // the image to its edges keeps the tile square.
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        artworkTile.wantsLayer = true
        artworkTile.layer?.cornerRadius = 6
        artworkTile.layer?.masksToBounds = true
        artworkTile.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.16).cgColor
        artworkTile.translatesAutoresizingMaskIntoConstraints = false
        artworkTile.setContentHuggingPriority(.required, for: .horizontal)
        artworkTile.setContentHuggingPriority(.required, for: .vertical)
        artworkTile.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkTile.widthAnchor.constraint(equalToConstant: Self.artworkSize),
            artworkTile.heightAnchor.constraint(equalToConstant: Self.artworkSize),
            artworkView.leadingAnchor.constraint(equalTo: artworkTile.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkTile.trailingAnchor),
            artworkView.topAnchor.constraint(equalTo: artworkTile.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkTile.bottomAnchor),
        ])

        trackLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        trackLabel.lineBreakMode = .byTruncatingTail
        trackLabel.maximumNumberOfLines = 1
        trackLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1

        let titleRow = NSStackView(views: [trackLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        let nowRow = NSStackView(views: [titleRow, artistLabel])
        nowRow.orientation = .vertical
        nowRow.alignment = .leading
        nowRow.spacing = 2

        // Global on/off — disengages the whole pipeline so you can just listen.
        powerButton.image = NSImage(systemSymbolName: "power",
                                    accessibilityDescription: "Enable transposing")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        powerButton.imagePosition = .imageOnly
        powerButton.isBordered = false
        powerButton.focusRingType = .none
        powerButton.target = self
        powerButton.action = #selector(powerToggled)
        powerButton.setContentHuggingPriority(.required, for: .horizontal)
        powerButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        powerButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let nowSpacer = NSView()
        nowSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let nowHeader = NSStackView(views: [artworkTile, nowRow, nowSpacer, powerButton])
        nowHeader.orientation = .horizontal
        nowHeader.alignment = .centerY
        nowHeader.spacing = 8

        // Transpose --------------------------------------------------------
        let transposeTitle = NSTextField(labelWithString: "Transpose")
        transposeTitle.font = .systemFont(ofSize: 13, weight: .medium)
        transposeTitle.textColor = .secondaryLabelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        valueLabel.alignment = .center

        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise",
                                    accessibilityDescription: "Reset")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        resetButton.imagePosition = .imageOnly
        resetButton.isBordered = false
        resetButton.focusRingType = .none
        resetButton.contentTintColor = .secondaryLabelColor
        resetButton.target = self
        resetButton.action = #selector(resetTapped)

        let header = NSView()
        for sub in [transposeTitle, valueLabel, resetButton] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 20),
            transposeTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            transposeTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            valueLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            resetButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            resetButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: 22),
            resetButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        let minus = stepButton("minus", #selector(minusTapped))
        let plus = stepButton("plus", #selector(plusTapped))
        minusButton = minus
        plusButton = plus
        slider.cell = TransposeSliderCell()
        slider.minValue = -12
        slider.maxValue = 12
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let sliderRow = NSStackView(views: [minus, slider, plus])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 10

        // Toggles ----------------------------------------------------------
        configure(rememberSwitch, #selector(rememberToggled))
        configure(loginSwitch, #selector(loginToggled))

        // Segment widths are explicit: the popover is 296 pt wide, and three
        // auto-sized segments plus a full-length row label overflow it.
        isolatePicker.segmentStyle = .rounded
        isolatePicker.segmentCount = IsolateTrack.allCases.count
        isolatePicker.focusRingType = .none
        isolatePicker.font = .systemFont(ofSize: 12)
        isolatePicker.target = self
        isolatePicker.action = #selector(isolateChanged)
        for (i, mode) in IsolateTrack.allCases.enumerated() {
            isolatePicker.setLabel(mode.title, forSegment: i)
            isolatePicker.setWidth(mode.segmentWidth, forSegment: i)
        }
        isolatePicker.setToolTip("Play the mix untouched.", forSegment: 0)
        isolatePicker.setToolTip("Keep the vocal, drop the backing.",
                                 forSegment: 1)
        isolatePicker.setToolTip("Remove the vocal, keep the backing.",
                                 forSegment: 2)

        let karaokeRow = pickerRow("Isolate", isolatePicker)

        // Only shown until the model is on disk (or while it's arriving).
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingTail
        modelButton.isBordered = false
        modelButton.focusRingType = .none
        modelButton.font = .systemFont(ofSize: 11, weight: .medium)
        modelButton.contentTintColor = transposeAccent
        modelButton.target = self
        modelButton.action = #selector(modelButtonTapped)
        modelButton.setContentHuggingPriority(.required, for: .horizontal)
        let modelSpacer = NSView()
        modelSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let modelRow = NSStackView(views: [modelLabel, modelSpacer, modelButton])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 8
        self.modelRow = modelRow

        let rememberRow = toggleRow("Remember key for this song", rememberSwitch,
                                    tooltip: "Re-apply this transpose automatically next time the song plays.")
        let loginRow = toggleRow("Launch at login", loginSwitch, tooltip: nil)

        // Footer -----------------------------------------------------------
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitTapped))
        quit.isBordered = false
        quit.focusRingType = .none
        quit.contentTintColor = .secondaryLabelColor
        quit.font = .systemFont(ofSize: 12)
        let footer = NSStackView(views: [NSView(), quit])
        footer.orientation = .horizontal

        // Assemble ---------------------------------------------------------
        let divider1 = separator()
        let divider2 = separator()
        let stack = NSStackView(views: [
            nowHeader, divider1,
            header, sliderRow,
            karaokeRow, modelRow, rememberRow, loginRow,
            divider2, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: nowHeader)
        stack.setCustomSpacing(14, after: divider1)
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(18, after: sliderRow)
        stack.setCustomSpacing(14, after: loginRow)
        stack.setCustomSpacing(9, after: divider2)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let fullWidth = [nowHeader, divider1, header, sliderRow, karaokeRow, modelRow,
                         rememberRow, loginRow, divider2, footer]
        for v in fullWidth {
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        nowRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        artistLabel.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        artwork.onChange = { [weak self] in self?.refresh() }
        inactiveWhenOff = [header, sliderRow, karaokeRow]
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    func refresh() {
        // May be called (e.g. from togglePopover) before the view is loaded;
        // the controls are nil until loadView runs. viewDidLoad refreshes again.
        guard isViewLoaded else { return }
        if case .error(let message) = controller.mode {
            trackLabel.stringValue = "Microphone access needed"
            trackLabel.textColor = .systemRed
            artistLabel.stringValue = "Enable in System Settings \u{25B8} Privacy"
            artistLabel.isHidden = false
            artistLabel.toolTip = message
        } else if controller.preparingModel {
            trackLabel.stringValue = "Preparing vocal removal\u{2026}"
            trackLabel.textColor = .labelColor
            artistLabel.stringValue = "Loading the model, a few seconds"
            artistLabel.isHidden = false
            artistLabel.toolTip = nil
        } else if spotify.isRunning, let track = spotify.current, !track.name.isEmpty {
            trackLabel.stringValue = track.name
            trackLabel.textColor = .labelColor
            // The neural pipeline needs ~2 s of audio before its first output;
            // without a hint that silence reads as "broken".
            artistLabel.stringValue = controller.priming
                ? "Catching up\u{2026}" : track.artist
            artistLabel.isHidden = false
            artistLabel.toolTip = nil
        } else {
            trackLabel.stringValue = spotify.isRunning ? "Nothing playing" : "Spotify not running"
            trackLabel.textColor = .labelColor
            artistLabel.isHidden = true
            artistLabel.toolTip = nil
        }

        updateArtwork()

        let s = controller.semitones
        valueLabel.stringValue = s == 0 ? "0" : (s > 0 ? "+\(s)" : "\u{2212}\(abs(s))")
        valueLabel.textColor = s == 0 ? .labelColor : transposeAccent
        slider.integerValue = s
        resetButton.isEnabled = (s != 0)
        resetButton.alphaValue = (s != 0) ? 1 : 0

        if let index = IsolateTrack.allCases.firstIndex(of: controller.isolate) {
            isolatePicker.selectedSegment = index
        }
        // Both isolating modes need the model; keep them visible but disabled so
        // the capability is discoverable rather than hidden.
        for (i, mode) in IsolateTrack.allCases.enumerated() where mode.isolating {
            isolatePicker.setEnabled(SeparationModel.isInstalled, forSegment: i)
        }
        refreshModelRow()
        rememberSwitch.state = controller.rememberThisSong ? .on : .off
        rememberSwitch.isEnabled = (spotify.current != nil)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off

        let on = controller.enabled
        powerButton.contentTintColor = on ? transposeAccent : .tertiaryLabelColor
        powerButton.toolTip = on
            ? "Transposing is on \u{2014} click to just listen"
            : "Transposing is off \u{2014} click to enable"
        for row in inactiveWhenOff { row.alphaValue = on ? 1 : 0.4 }
        for control in [slider, minusButton, plusButton, resetButton, isolatePicker] as [NSControl] {
            control.isEnabled = on
        }
        // resetButton still hides itself at 0 even when enabled.
        if on { resetButton.isEnabled = (controller.semitones != 0) }
    }

    // MARK: - Builders

    private func configure(_ toggle: NSSwitch, _ action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
        toggle.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func toggleRow(_ title: String, _ control: NSView, tooltip: String?) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.toolTip = tooltip
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// A label plus a segmented control, matching the toggle rows' metrics.
    private func pickerRow(_ title: String, _ control: NSControl) -> NSStackView {
        control.setContentHuggingPriority(.required, for: .horizontal)
        return toggleRow(title, control, tooltip:
            "Keep only the vocal, or only the backing. Switching is seamless — "
            + "the audio never stops and never jumps.")
    }

    private func stepButton(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func minusTapped() { controller.nudge(-1) }
    @objc private func plusTapped() { controller.nudge(1) }
    @objc private func resetTapped() { controller.resetPitch() }
    @objc private func sliderChanged() {
        let value = slider.integerValue
        slider.integerValue = value
        controller.setSemitones(value)
    }
    @objc private func powerToggled() { controller.setEnabled(!controller.enabled) }
    /// Snapshot/testing only.

    /// Snapshot/testing only.
    func seedArtwork(_ image: NSImage, for trackID: String) {
        artwork.seed(image, for: trackID)
    }

    /// Album art for the current track, or the note placeholder. Requesting is
    /// cheap and idempotent; the store calls back when an image arrives.
    private func updateArtwork() {
        let trackID = spotify.current?.id ?? ""
        if let image = artwork.image(for: trackID) {
            // Cover art fills the tile.
            artworkView.imageScaling = .scaleProportionallyUpOrDown
            artworkView.image = image
            artworkView.contentTintColor = nil
        } else {
            // The placeholder glyph must NOT scale, or it is blown up to fill
            // the tile and the point size has no visible effect.
            artworkView.imageScaling = .scaleNone
            artworkView.image = NSImage(systemSymbolName: "music.note",
                                        accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            artworkView.contentTintColor = .tertiaryLabelColor
        }
    }

    /// The model row is the only place "Best" explains itself, so it carries
    /// the size up front, live progress, and any failure — rather than leaving
    /// a greyed-out segment with no explanation.
    private func refreshModelRow() {
        let installer = controller.modelInstaller
        switch installer.state {
        case .downloading(let fraction, let received, let total):
            modelRow.isHidden = false
            let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_000_000) }
            modelLabel.stringValue =
                "Downloading model \u{2014} \(mb(received)) of \(mb(total)) MB"
            modelLabel.textColor = .secondaryLabelColor
            modelButton.title = "\(Int(fraction * 100))%  Cancel"
        case .verifying:
            modelRow.isHidden = false
            modelLabel.stringValue = "Checking the download\u{2026}"
            modelLabel.textColor = .secondaryLabelColor
            modelButton.title = ""
        case .installing:
            modelRow.isHidden = false
            modelLabel.stringValue = "Installing the model\u{2026}"
            modelLabel.textColor = .secondaryLabelColor
            modelButton.title = ""
        case .failed(let message):
            modelRow.isHidden = false
            modelLabel.stringValue = message
            modelLabel.textColor = .systemRed
            modelButton.title = "Retry"
        case .idle, .installed:
            modelLabel.textColor = .secondaryLabelColor
            if !SeparationModel.isInstalled {
                modelRow.isHidden = false
                modelLabel.stringValue =
                    "Isolating needs a \(SeparationModel.downloadSizeDescription) model"
                modelButton.title = "Download"
            } else if spotify.automation == .denied {
                // Model is fine, so the row is free for the next useful thing.
                modelRow.isHidden = false
                modelLabel.stringValue = "Album art needs Automation access"
                modelButton.title = "Open Settings"
            } else {
                modelRow.isHidden = true
                modelButton.title = ""
            }
        }
        modelButton.isHidden = modelButton.title.isEmpty
        modelLabel.toolTip = SeparationModel.isInstalled
            ? "System Settings \u{25B8} Privacy & Security \u{25B8} Automation "
                + "\u{25B8} Transposify \u{25B8} Spotify"
            : "Neural separation runs on your Mac; the model is downloaded once "
                + "and verified against a checksum."
    }

    @objc private func modelButtonTapped() {
        if SeparationModel.isInstalled, spotify.automation == .denied {
            AutomationPermission.openSettings()
            return
        }
        if controller.modelInstaller.isBusy {
            controller.cancelModelDownload()
        } else {
            controller.downloadModel()
        }
    }

    @objc private func isolateChanged() {
        let index = isolatePicker.selectedSegment
        guard index >= 0, index < IsolateTrack.allCases.count else { return }
        controller.setIsolate(IsolateTrack.allCases[index])
    }
    @objc private func rememberToggled() { controller.setRemember(rememberSwitch.state == .on) }
    @objc private func loginToggled() {
        LoginItem.set(loginSwitch.state == .on)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
    }
    @objc private func quitTapped() { NSApp.terminate(nil) }
}
