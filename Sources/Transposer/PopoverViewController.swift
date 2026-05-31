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

    private let trackLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "0")
    private let slider = NSSlider()
    private let resetButton = NSButton()
    private let karaokeSwitch = NSSwitch()
    private let rememberSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()

    init(controller: AudioController, spotify: SpotifyState) {
        self.controller = controller
        self.spotify = spotify
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let width: CGFloat = 296

        // Now playing ------------------------------------------------------
        let nowIcon = NSImageView()
        nowIcon.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        nowIcon.contentTintColor = .tertiaryLabelColor
        nowIcon.setContentHuggingPriority(.required, for: .horizontal)

        trackLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        trackLabel.lineBreakMode = .byTruncatingTail
        trackLabel.maximumNumberOfLines = 1
        trackLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1

        let titleRow = NSStackView(views: [nowIcon, trackLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6
        let nowRow = NSStackView(views: [titleRow, artistLabel])
        nowRow.orientation = .vertical
        nowRow.alignment = .leading
        nowRow.spacing = 2

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
        configure(karaokeSwitch, #selector(karaokeToggled))
        configure(rememberSwitch, #selector(rememberToggled))
        configure(loginSwitch, #selector(loginToggled))
        let karaokeRow = toggleRow("Reduce vocals", karaokeSwitch,
                                   tooltip: "Karaoke-style center-channel reduction. Experimental — best on stereo tracks.")
        let rememberRow = toggleRow("Remember this key", rememberSwitch,
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
            nowRow, divider1,
            header, sliderRow,
            karaokeRow, rememberRow, loginRow,
            divider2, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: nowRow)
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
        let fullWidth = [nowRow, divider1, header, sliderRow, karaokeRow, rememberRow,
                         loginRow, divider2, footer]
        for v in fullWidth {
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        titleRow.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        artistLabel.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    func refresh() {
        if case .error(let message) = controller.mode {
            trackLabel.stringValue = "Microphone access needed"
            trackLabel.textColor = .systemRed
            artistLabel.stringValue = "Enable in System Settings \u{25B8} Privacy"
            artistLabel.isHidden = false
            artistLabel.toolTip = message
        } else if spotify.isRunning, let track = spotify.current, !track.name.isEmpty {
            trackLabel.stringValue = track.name
            trackLabel.textColor = .labelColor
            artistLabel.stringValue = track.artist
            artistLabel.isHidden = false
            artistLabel.toolTip = nil
        } else {
            trackLabel.stringValue = spotify.isRunning ? "Nothing playing" : "Spotify not running"
            trackLabel.textColor = .labelColor
            artistLabel.isHidden = true
            artistLabel.toolTip = nil
        }

        let s = controller.semitones
        valueLabel.stringValue = s == 0 ? "0" : (s > 0 ? "+\(s)" : "\u{2212}\(abs(s))")
        valueLabel.textColor = s == 0 ? .labelColor : transposeAccent
        slider.integerValue = s
        resetButton.isEnabled = (s != 0)
        resetButton.alphaValue = (s != 0) ? 1 : 0

        karaokeSwitch.state = controller.karaoke ? .on : .off
        rememberSwitch.state = controller.rememberThisSong ? .on : .off
        rememberSwitch.isEnabled = (spotify.current != nil)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
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
    @objc private func karaokeToggled() { controller.setKaraoke(karaokeSwitch.state == .on) }
    @objc private func rememberToggled() { controller.setRemember(rememberSwitch.state == .on) }
    @objc private func loginToggled() {
        LoginItem.set(loginSwitch.state == .on)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
    }
    @objc private func quitTapped() { NSApp.terminate(nil) }
}
