import AppKit

/// Slider with a flat gray track and an amber knob, matching the app's look.
private final class TransposeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 4
        var bar = rect
        bar.origin.y = rect.midY - height / 2
        bar.size.height = height
        NSColor(white: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter: CGFloat = 16
        let frame = NSRect(x: knobRect.midX - diameter / 2,
                           y: knobRect.midY - diameter / 2,
                           width: diameter, height: diameter)
        NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(ovalIn: frame).fill()
    }
}

/// The popup shown from the menu bar: now-playing, a one-knob pitch control,
/// a karaoke toggle, and per-song / launch-at-login options. Designed for
/// singers, not musicians — direction and plain language over jargon.
final class PopoverViewController: NSViewController {
    private let controller: AudioController
    private let spotify: SpotifyState

    private let trackLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "0")
    private let slider = NSSlider()
    private let resetButton = NSButton()
    private let karaokeSwitch = NSSwitch()
    private let rememberCheck = NSButton(checkboxWithTitle: "Remember key for this song",
                                         target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Launch at login",
                                      target: nil, action: nil)

    init(controller: AudioController, spotify: SpotifyState) {
        self.controller = controller
        self.spotify = spotify
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let width: CGFloat = 300

        // Now playing -------------------------------------------------------
        // Spotify doesn't reliably expose cover art, so the title gets a small
        // inline music glyph instead of an album thumbnail.
        let titleIcon = NSTextField(labelWithString: "\u{1F3BC}") // 🎼
        titleIcon.font = .systemFont(ofSize: 15)
        titleIcon.setContentHuggingPriority(.required, for: .horizontal)
        titleIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        trackLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        trackLabel.lineBreakMode = .byTruncatingTail
        trackLabel.maximumNumberOfLines = 1
        trackLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1

        let titleRow = NSStackView(views: [titleIcon, trackLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 5
        let nowRow = NSStackView(views: [titleRow, artistLabel])
        nowRow.orientation = .vertical
        nowRow.alignment = .leading
        nowRow.spacing = 1

        // Transpose control (matches mockup) --------------------------------
        let transposeTitle = NSTextField(labelWithString: "Transpose")
        transposeTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        valueLabel.alignment = .center

        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise",
                                    accessibilityDescription: "Reset")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        resetButton.imagePosition = .imageOnly
        resetButton.isBordered = false
        resetButton.focusRingType = .none
        resetButton.contentTintColor = .secondaryLabelColor
        resetButton.target = self
        resetButton.action = #selector(resetTapped)

        // Top row: title (leading) · value (true-centered) · reset (trailing).
        let topRow = NSView()
        for sub in [transposeTitle, valueLabel, resetButton] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            topRow.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            topRow.heightAnchor.constraint(equalToConstant: 22),
            transposeTitle.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            transposeTitle.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            valueLabel.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            resetButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            resetButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
        ])

        // Bottom row: − · slider · +
        let minus = iconButton("minus", 15, #selector(minusTapped))
        let plus = iconButton("plus", 15, #selector(plusTapped))
        slider.cell = TransposeSliderCell()
        slider.minValue = -12
        slider.maxValue = 12
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let bottomRow = NSStackView(views: [minus, slider, plus])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 12

        // Karaoke -----------------------------------------------------------
        karaokeSwitch.target = self
        karaokeSwitch.action = #selector(karaokeToggled)
        let karaokeLabel = NSTextField(labelWithString: "Reduce vocals (karaoke)")
        karaokeLabel.font = .systemFont(ofSize: 12)
        let karaokeRow = NSStackView(views: [karaokeLabel, NSView(), karaokeSwitch])
        karaokeRow.orientation = .horizontal
        karaokeRow.distribution = .fill
        karaokeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let karaokeCaption = NSTextField(labelWithString: "Experimental \u{00B7} best on stereo tracks")
        karaokeCaption.font = .systemFont(ofSize: 10)
        karaokeCaption.textColor = .tertiaryLabelColor

        // Options -----------------------------------------------------------
        rememberCheck.target = self
        rememberCheck.action = #selector(rememberToggled)
        loginCheck.target = self
        loginCheck.action = #selector(loginToggled)
        for box in [rememberCheck, loginCheck] { box.font = .systemFont(ofSize: 12) }

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitTapped))
        quit.bezelStyle = .inline
        quit.controlSize = .small
        let footer = NSStackView(views: [NSView(), quit])
        footer.orientation = .horizontal

        // Assemble ----------------------------------------------------------
        let stack = NSStackView(views: [
            nowRow, separator(),
            topRow, bottomRow, separator(),
            karaokeRow, karaokeCaption, separator(),
            rememberCheck, loginCheck, separator(),
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultHigh, for: .vertical)

        for v in [nowRow, topRow, bottomRow, karaokeRow, footer] {
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        for spanning in [nowRow, topRow, bottomRow, karaokeRow, footer] {
            spanning.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                            constant: -32).isActive = true
        }
        // Fill the now-playing width so the title/artist truncate instead of
        // overflowing.
        titleRow.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        artistLabel.widthAnchor.constraint(equalTo: nowRow.widthAnchor).isActive = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    func refresh() {
        // Now playing (also surfaces a permission alert here, since there's no
        // longer a bottom status line).
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
        slider.integerValue = s
        let shifted = (s != 0)
        resetButton.isEnabled = shifted
        resetButton.alphaValue = shifted ? 1 : 0.35

        karaokeSwitch.state = controller.karaoke ? .on : .off
        rememberCheck.state = controller.rememberThisSong ? .on : .off
        rememberCheck.isEnabled = (spotify.current != nil)
        loginCheck.state = LoginItem.isEnabled ? .on : .off
    }

    private func iconButton(_ symbol: String, _ pointSize: CGFloat, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        // Larger clickable target than the glyph itself; icon stays centered.
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
        slider.integerValue = value // snap thumb to whole semitones
        controller.setSemitones(value)
    }
    @objc private func karaokeToggled() { controller.setKaraoke(karaokeSwitch.state == .on) }
    @objc private func rememberToggled() { controller.setRemember(rememberCheck.state == .on) }
    @objc private func loginToggled() {
        LoginItem.set(loginCheck.state == .on)
        loginCheck.state = LoginItem.isEnabled ? .on : .off
    }
    @objc private func quitTapped() { NSApp.terminate(nil) }
}
