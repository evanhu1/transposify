import AppKit

/// Accent used for the slider knob and the active transpose value.
private let transposeAccent = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)

/// Slider with a flat gray track and an accent knob.
final class TransposeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 4
        var bar = rect
        bar.origin.y = rect.midY - height / 2
        bar.size.height = height
        // Alpha over a mid grey rather than a fixed colour, so the track keeps
        // its contrast in both appearances.
        NSColor(white: 0.5, alpha: 0.48).setFill()
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

/// A deliberately quiet checkbox for footer actions. AppKit's standard
/// checkbox reverses to a bright fill in dark mode; this keeps the selected
/// state dark with a soft white check instead.
private final class FooterCheckbox: NSButton {
    override var intrinsicContentSize: NSSize {
        let titleSize = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12),
        ])
        return NSSize(width: 13 + 5 + ceil(titleSize.width),
                      height: max(13, ceil(titleSize.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let boxSize: CGFloat = 13
        let boxRect = NSRect(x: 0, y: (bounds.height - boxSize) / 2,
                             width: boxSize, height: boxSize)
        let box = NSBezierPath(roundedRect: boxRect, xRadius: 3, yRadius: 3)

        if state == .on {
            NSColor(calibratedWhite: 0.18, alpha: 0.9).setFill()
            box.fill()

            let check = NSBezierPath()
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: 2.8, y: boxRect.midY))
            check.line(to: NSPoint(x: 5.4, y: boxRect.maxY - 3.2))
            check.line(to: NSPoint(x: 10.3, y: boxRect.minY + 3.1))
            NSColor(white: 1, alpha: 0.82).setStroke()
            check.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            box.lineWidth = 1
            box.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        let titleRect = NSRect(x: boxRect.maxX + 5,
                               y: (bounds.height - titleSize.height) / 2,
                               width: bounds.width - boxRect.maxX - 5,
                               height: titleSize.height)
        (title as NSString).draw(in: titleRect, withAttributes: attributes)
    }
}

/// The popup shown from the menu bar: now-playing, a one-knob pitch control,
/// and three toggles. Designed for singers, not musicians — direction and
/// plain language over jargon.
final class PopoverViewController: NSViewController {
    private let controller: AudioController
    private let spotify: SpotifyState

    private static let artworkSize: CGFloat = 40
    private static let popoverWidth: CGFloat = 296
    private static let contentInset: CGFloat = 16
    private static let contentWidth = popoverWidth - contentInset * 2
    private let artworkView = NSImageView()
    private let artworkTile = NSView()
    private let artwork: ArtworkStore
    private let trackLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "0")
    private let slider = NSSlider()
    private let resetButton = NSButton()
    private let powerButton = NSButton()
    private var presetChips: [MixPreset: MixChip] = [:]
    private var stemGrid: NSStackView!
    private var stemTiles: [StemTile] = []
    private var builtStemCount = 0
    private let modelLabel = NSTextField(labelWithString: "")
    private let modelButton = NSButton()
    private var modelRow: NSStackView!
    /// One text button above the mix controls: the reason they are greyed
    /// out and the way to fix it, in the same place.
    private let downloadButton = NSButton()
    private lazy var downloadPill = NSStackView(views: [downloadButton])
    private let rememberSwitch = NSSwitch()
    private var formantChips: [FormantMode: MixChip] = [:]
    private let loginCheckbox = FooterCheckbox(
        checkboxWithTitle: "Launch at login", target: nil, action: nil)
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
        let width = Self.popoverWidth

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

        // Truncation. A long title or artist must end in an ellipsis rather
        // than widen the popover, so both labels give up their width first:
        // low compression resistance lets the text clip.
        trackLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        trackLabel.lineBreakMode = .byTruncatingTail
        trackLabel.maximumNumberOfLines = 1
        trackLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Both labels also hug weakly. An NSTextField hugs at 750 by default,
        // and the two share one width, so a hugging artist name would pull the
        // row in and truncate a title that had room to spare.
        artistLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [trackLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        let nowRow = NSStackView(views: [titleRow, artistLabel])
        nowRow.orientation = .vertical
        nowRow.alignment = .leading
        nowRow.spacing = 2
        // An NSStackView refuses to be clipped at `required` priority, so
        // these two would have pushed the row past the 296 pt width and
        // stretched the whole popover. They yield instead; nowHeader keeps the
        // required setting, which is what holds the width and forces them to.
        for row in [titleRow, nowRow] {
            row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        }

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

        // Laid out by hand rather than by a stack view. A stack negotiates
        // widths from its arranged views' priorities, and that negotiation is
        // what let a long title claim the power button's space and draw over
        // it. Here the artwork is pinned left, the button right, and the text
        // gets whatever is between them and not one point more.
        let nowHeader = NSView()
        for v in [artworkTile, nowRow, powerButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            nowHeader.addSubview(v)
        }
        NSLayoutConstraint.activate([
            artworkTile.leadingAnchor.constraint(equalTo: nowHeader.leadingAnchor),
            artworkTile.centerYAnchor.constraint(equalTo: nowHeader.centerYAnchor),
            powerButton.trailingAnchor.constraint(equalTo: nowHeader.trailingAnchor),
            powerButton.centerYAnchor.constraint(equalTo: nowHeader.centerYAnchor),
            nowRow.leadingAnchor.constraint(equalTo: artworkTile.trailingAnchor, constant: 8),
            nowRow.centerYAnchor.constraint(equalTo: nowHeader.centerYAnchor),
            nowRow.trailingAnchor.constraint(lessThanOrEqualTo: powerButton.leadingAnchor,
                                             constant: -10),
            nowHeader.heightAnchor.constraint(greaterThanOrEqualTo: artworkTile.heightAnchor),
            nowHeader.heightAnchor.constraint(greaterThanOrEqualTo: nowRow.heightAnchor),
        ])

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
        loginCheckbox.controlSize = .small
        loginCheckbox.focusRingType = .none
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginToggled)
        loginCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        loginCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Mix ----------------------------------------------------------
        // One piece of state, shown twice. The chips name the three common
        // masks; the tiles are the mask itself. Editing a tile simply stops
        // matching a chip, so there is no mode to enter or leave and the
        // section never changes height.
        let mixTitle = NSTextField(labelWithString: "Mix")
        mixTitle.font = .systemFont(ofSize: 13, weight: .medium)
        mixTitle.textColor = .secondaryLabelColor

        var chips: [NSView] = []
        for preset in MixPreset.allCases {
            let chip = MixChip(title: preset.title, target: self,
                               action: #selector(presetTapped(_:)))
            chip.toolTip = preset.summary
            presetChips[preset] = chip
            chips.append(chip)
        }
        let chipSpacer = NSView()
        chipSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let chipRow = NSStackView(views: chips + [chipSpacer])
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 6

        let grid = NSStackView(views: [])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        grid.distribution = .fill
        stemGrid = grid

        downloadButton.isBordered = false
        downloadButton.focusRingType = .none
        downloadButton.font = .systemFont(ofSize: 12, weight: .medium)
        downloadButton.contentTintColor = transposeAccent
        downloadButton.alignment = .center
        downloadButton.target = self
        downloadButton.action = #selector(modelButtonTapped)
        downloadButton.toolTip = "A \(SeparationModel.downloadSizeDescription) download, once. "
            + "Separation then runs on your Mac; the file is verified against a checksum."

        // The chips and tiles sit in a host view so the download button can
        // float over their centre: the greyed-out controls are the question
        // and the button on top of them is the answer.
        let mixBody = NSStackView(views: [chipRow, grid])
        mixBody.orientation = .vertical
        mixBody.alignment = .leading
        mixBody.spacing = 10
        mixBody.translatesAutoresizingMaskIntoConstraints = false
        downloadPill.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        downloadPill.wantsLayer = true
        downloadPill.layer?.cornerRadius = 10
        downloadPill.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        downloadPill.layer?.borderWidth = 1
        downloadPill.layer?.borderColor = NSColor.separatorColor.cgColor
        downloadPill.translatesAutoresizingMaskIntoConstraints = false
        let mixHost = NSView()
        mixHost.addSubview(mixBody)
        mixHost.addSubview(downloadPill)
        NSLayoutConstraint.activate([
            mixBody.leadingAnchor.constraint(equalTo: mixHost.leadingAnchor),
            mixBody.trailingAnchor.constraint(equalTo: mixHost.trailingAnchor),
            mixBody.topAnchor.constraint(equalTo: mixHost.topAnchor),
            mixBody.bottomAnchor.constraint(equalTo: mixHost.bottomAnchor),
            downloadPill.centerXAnchor.constraint(equalTo: mixHost.centerXAnchor),
            downloadPill.centerYAnchor.constraint(equalTo: mixHost.centerYAnchor),
        ])

        let mixStack = NSStackView(views: [mixTitle, mixHost])
        mixStack.orientation = .vertical
        mixStack.alignment = .leading
        mixStack.spacing = 8
        mixHost.widthAnchor.constraint(equalTo: mixStack.widthAnchor).isActive = true
        let karaokeRow: NSView = mixStack

        // Notice row: the Automation hint.
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
        let noticeRow = NSStackView(views: [modelLabel, modelSpacer, modelButton])
        noticeRow.orientation = .horizontal
        noticeRow.alignment = .centerY
        noticeRow.spacing = 8
        modelRow = noticeRow

        // Voice tone: the same chip row the Mix section uses, because it is
        // the same kind of choice — one of a few named settings.
        let formantTitle = NSTextField(labelWithString: "Voice tone")
        formantTitle.font = .systemFont(ofSize: 13, weight: .medium)
        formantTitle.textColor = .secondaryLabelColor
        var fChips: [NSView] = []
        for mode in FormantMode.allCases {
            let chip = MixChip(title: mode.title, target: self,
                               action: #selector(formantTapped(_:)))
            chip.toolTip = mode.summary
            formantChips[mode] = chip
            fChips.append(chip)
        }
        let fSpacer = NSView()
        fSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let fChipRow = NSStackView(views: fChips + [fSpacer])
        fChipRow.orientation = .horizontal
        fChipRow.alignment = .centerY
        fChipRow.spacing = 6
        let formantRow = NSStackView(views: [formantTitle, fChipRow])
        formantRow.orientation = .vertical
        formantRow.alignment = .leading
        formantRow.spacing = 8
        let rememberRow = toggleRow("Remember key for this song", rememberSwitch,
                                    tooltip: "Re-apply this transpose automatically next time the song plays.")

        // Footer -----------------------------------------------------------
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitTapped))
        quit.isBordered = false
        quit.focusRingType = .none
        quit.contentTintColor = .secondaryLabelColor
        quit.font = .systemFont(ofSize: 12)
        let footer = NSStackView(views: [loginCheckbox, NSView(), quit])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        // Assemble ---------------------------------------------------------
        let divider1 = separator()
        let divider2 = separator()
        let stack = NSStackView(views: [
            nowHeader, divider1,
            header, sliderRow, formantRow,
            karaokeRow, modelRow, rememberRow,
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
        stack.setCustomSpacing(14, after: sliderRow)
        stack.setCustomSpacing(18, after: formantRow)
        stack.setCustomSpacing(14, after: rememberRow)
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
        let fullWidth: [NSView] = [nowHeader, divider1, header, sliderRow, formantRow, karaokeRow,
                                   modelRow, rememberRow, divider2, footer]
        for v in fullWidth {
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        titleRow.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        artistLabel.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        artwork.onChange = { [weak self] in self?.refresh() }
        inactiveWhenOff = [header, sliderRow, formantRow, karaokeRow, rememberRow]
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
            trackLabel.toolTip = nil
        } else if controller.preparingModel {
            trackLabel.stringValue = "Preparing separation\u{2026}"
            trackLabel.textColor = .labelColor
            artistLabel.stringValue = controller.pausedForModelLoad
                ? "Paused while the model loads, a few seconds"
                : "Loading the model, a few seconds"
            artistLabel.isHidden = false
            artistLabel.toolTip = nil
            trackLabel.toolTip = nil
        } else if spotify.isRunning, let track = spotify.current, !track.name.isEmpty {
            trackLabel.stringValue = track.name
            trackLabel.textColor = .labelColor
            // Every mix change takes seconds to reach the ears — the pipeline
            // has to fill, and a change travels its whole delay. Without a
            // hint, that wait reads as a click that did nothing.
            artistLabel.stringValue = controller.catchingUp
                ? "Loading\u{2026}" : track.artist
            artistLabel.isHidden = false
            // A long name truncates, so the tooltip is where the rest of it is.
            trackLabel.toolTip = track.name
            artistLabel.toolTip = controller.catchingUp ? nil : track.artist
        } else {
            trackLabel.stringValue = spotify.isRunning ? "Nothing playing" : "Spotify not running"
            trackLabel.textColor = .labelColor
            artistLabel.isHidden = true
            artistLabel.toolTip = nil
            trackLabel.toolTip = nil
        }

        updateArtwork()
        if Self.headerDebug {
            view.layoutSubtreeIfNeeded()
            reportHeaderFrames()
        }

        let s = controller.semitones
        valueLabel.stringValue = s == 0 ? "0" : (s > 0 ? "+\(s)" : "\u{2212}\(abs(s))")
        valueLabel.textColor = s == 0 ? .labelColor : transposeAccent
        slider.integerValue = s
        resetButton.isEnabled = (s != 0)
        resetButton.alphaValue = (s != 0) ? 1 : 0

        rebuildStemTilesIfNeeded()
        let installed = SeparationModel.isInstalled
        for (preset, chip) in presetChips {
            chip.lit = (controller.preset == preset)
            chip.isEnabled = controller.enabled && (installed || preset == .all)
        }
        for tile in stemTiles {
            tile.lit = controller.includes(tile.stem)
            tile.isEnabled = controller.enabled && installed
        }
        refreshModelRow()
        updatePreferredSize()
        for (mode, chip) in formantChips {
            chip.lit = (controller.formantMode == mode)
            chip.isEnabled = controller.enabled
        }
        rememberSwitch.state = controller.rememberThisSong ? .on : .off
        rememberSwitch.isEnabled = controller.enabled && (spotify.current != nil)
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off

        let on = controller.enabled
        powerButton.contentTintColor = on ? transposeAccent : .tertiaryLabelColor
        powerButton.toolTip = on
            ? "Transposing is on \u{2014} click to just listen"
            : "Transposing is off \u{2014} click to enable"
        // Catching up dims the same rows as Off, for the same reason: the
        // controls are showing a mix the audio is not playing yet. The dim
        // says "not in effect", so it belongs to both.
        let inEffect = on && !controller.catchingUp
        for row in inactiveWhenOff { row.alphaValue = inEffect ? 1 : 0.4 }
        for control in [slider, minusButton, plusButton, resetButton] as [NSControl] {
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
        // Same weight as the "Transpose" and "Mix" headings: this row names a
        // setting, so it must not read louder than the sections above it.
        label.textColor = .secondaryLabelColor
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
        // Full-strength label colour: these two are the control you reach for
        // most, so they read as primary rather than as secondary chrome.
        button.contentTintColor = .labelColor
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

    /// NSPopover sizes itself from the content controller's preferred size and
    /// keeps whatever it measured first, so the size has to be republished
    /// whenever the content's height changes — a four-stem model shows four
    /// tiles where a six-stem model shows six.
    ///
    /// Only the height is taken. The width is a design constant, and a long
    /// track title reports a `fittingSize` a few points wider than it, which
    /// would nudge the popover sideways as songs change.
    /// TRANSPOSIFY_HEADER_DEBUG=1 prints the header's widths on every refresh,
    /// so a real session can be measured instead of guessed at.
    private static let headerDebug =
        ProcessInfo.processInfo.environment["TRANSPOSIFY_HEADER_DEBUG"] == "1"

    /// What width the header's parts ended up with, for `popoverSnapshot`.
    func reportHeaderFrames() {
        func f(_ name: String, _ v: NSView?) {
            guard let v else { return }
            print(String(format: "  %-12@ w %6.1f  right edge %6.1f",
                         name, v.frame.width, v.convert(v.bounds, to: nil).maxX))
        }
        print("popover width \(view.frame.width)")
        f("trackLabel", trackLabel)
        f("artistLabel", artistLabel)
        f("nowRow", artistLabel.superview)
        f("powerButton", powerButton)
    }

    private func updatePreferredSize() {
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        if abs(preferredContentSize.height - height) > 0.5
            || abs(preferredContentSize.width - Self.popoverWidth) > 0.5 {
            preferredContentSize = NSSize(width: Self.popoverWidth, height: height)
        }
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
        // The download lives above the mix controls it unlocks; the button's
        // title is the whole status, so there is nothing else to read.
        var title = ""
        var enabled = true
        var tint = transposeAccent
        switch installer.state {
        case .downloading(let fraction, let received, let total):
            let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_000_000) }
            title = "Downloading \(mb(received)) of \(mb(total)) MB (\(Int(fraction * 100))%) \u{2014} Cancel"
        case .verifying:
            title = "Checking the download\u{2026}"
            enabled = false
        case .installing:
            title = "Installing the model\u{2026}"
            enabled = false
        case .failed(let message):
            title = "\(message) \u{2014} Retry"
            tint = .systemRed
        case .idle, .installed:
            if !SeparationModel.isInstalled {
                title = "Download Mix model"
            }
        }
        downloadButton.title = title
        downloadPill.isHidden = title.isEmpty
        downloadPill.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        downloadPill.layer?.borderColor = NSColor.separatorColor.cgColor
        downloadButton.isEnabled = enabled
        downloadButton.contentTintColor = tint

        // The notice row is for the Automation hint alone now.
        if SeparationModel.isInstalled, spotify.automation == .denied {
            modelRow.isHidden = false
            modelLabel.stringValue = "Album art needs Automation access"
            modelLabel.textColor = .secondaryLabelColor
            modelButton.title = "Open Settings"
        } else {
            modelRow.isHidden = true
            modelButton.title = ""
        }
        modelButton.isHidden = modelButton.title.isEmpty
        modelLabel.toolTip = "System Settings \u{25B8} Privacy & Security \u{25B8} Automation "
            + "\u{25B8} Transposify \u{25B8} Spotify"
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

    /// The tile grid, rebuilt when the model's stem count changes — a four-stem
    /// model has no guitar or piano to offer.
    ///
    /// Three columns divide six stems evenly; four go in two columns rather
    /// than leaving a lone tile on a second row.
    private func rebuildStemTilesIfNeeded() {
        let count = controller.stemCount
        guard count != builtStemCount else { return }
        builtStemCount = count

        stemTiles.removeAll()
        for row in stemGrid.arrangedSubviews {
            stemGrid.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        let stems = Stem.displayOrder.filter { $0.rawValue < count }
        let columns = stems.count % 3 == 0 ? 3 : 2
        let spacing: CGFloat = 6
        for start in stride(from: 0, to: stems.count, by: columns) {
            let slice = stems[start..<min(start + columns, stems.count)]
            let tiles = slice.map {
                StemTile(stem: $0, target: self, action: #selector(stemTapped(_:)))
            }
            stemTiles.append(contentsOf: tiles)
            let row = NSStackView(views: tiles)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = spacing
            // Rows have no intrinsic width of their own, so without this the
            // equal-width tiles collapse on top of each other.
            row.widthAnchor.constraint(
                equalToConstant: Self.contentWidth).isActive = true
            stemGrid.addArrangedSubview(row)
        }
    }

    @objc private func stemTapped(_ sender: StemTile) {
        controller.setStem(sender.stem, included: !controller.includes(sender.stem))
    }

    @objc private func presetTapped(_ sender: MixChip) {
        guard let preset = presetChips.first(where: { $0.value === sender })?.key
        else { return }
        controller.setPreset(preset)
    }

    @objc private func formantTapped(_ sender: MixChip) {
        guard let mode = formantChips.first(where: { $0.value === sender })?.key else { return }
        controller.setFormantMode(mode)
    }

    @objc private func rememberToggled() { controller.setRemember(rememberSwitch.state == .on) }
    @objc private func loginToggled() {
        LoginItem.set(loginCheckbox.state == .on)
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
    }
    @objc private func quitTapped() { NSApp.terminate(nil) }
}
