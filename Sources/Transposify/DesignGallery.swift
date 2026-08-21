import AppKit

/// Dev-only design harness.
///
/// Renders candidate popover layouts as *real AppKit views* into one
/// contact-sheet PNG, so a layout can be judged in about a second rather than
/// through a build / sign / install / relaunch / click cycle. Because the
/// variants are the same kind of object the app ships, whatever looks right
/// here looks identical in the popover — unlike a drawing or an HTML mock.
///
///     ./mock.sh          build, render, open
///
/// Nothing here is reachable from the shipping app: `TRANSPOSIFY_GALLERY`
/// gates it, and it exits as soon as the PNG is written.
enum DesignGallery {

    // MARK: - Tokens

    static let accent = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
    static let popoverBG = NSColor(calibratedWhite: 0.13, alpha: 1)
    static let sheetBG = NSColor(calibratedWhite: 0.07, alpha: 1)

    // MARK: - Entry point

    /// Renders the *real* popover in several states. Rendering the shipping
    /// view rather than a mock of it is the point: there is no second copy to
    /// drift, and a layout that looks right here looks identical in the menu
    /// bar.
    static func run(to path: String) {
        // The controller persists every change, so rendering an "off" card
        // would otherwise leave the app switched off for real. Snapshot the
        // whole preferences domain and put it back before exiting.
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain)

        let controller = makeController()
        waitForModel(controller)
        let full = (1 << controller.stemCount) - 1
        let cards: [(String, String, NSView)] = [
            ("All", "every stem — the pipeline stays out of the way",
             popover(controller, mask: full)),
            ("Backing", "the common case: drop the vocal",
             popover(controller, mask: full & ~1)),
            ("Vocals", "the other common case", popover(controller, mask: 1)),
            ("Custom", "no chip lit — the tiles are the state",
             popover(controller, mask: 0b100110)),
            ("Off", "switched off; the mix controls go quiet",
             popover(controller, mask: full & ~1, enabled: false)),
            ("Palette", "what AppKit will give you", ingredients()),
        ]
        writePNG(contactSheet(cards), to: path)
        FileHandle.standardError.write(
            "gallery: \(cards.count) cards -> \(path)\n".data(using: .utf8)!)
        // Not a `defer`: `exit` does not unwind.
        defaults.setPersistentDomain(saved ?? [:], forName: domain)
        exit(0)
    }

    /// Prints the view tree with frames — the quickest way to find which row
    /// is wider than the popover when `fittingSize` disagrees with the width
    /// constraint. Enabled with TRANSPOSIFY_GALLERY_DEBUG.
    static func dumpTree(_ v: NSView, _ depth: Int = 0) {
        var extra = ""
        if let t = v as? NSTextField { extra = " \"\(t.stringValue)\"" }
        FileHandle.standardError.write(
            "\(String(repeating: "  ", count: depth))\(type(of: v)) \(v.frame)\(extra)\n"
                .data(using: .utf8)!)
        for sub in v.subviews { dumpTree(sub, depth + 1) }
    }

    /// One popover, driven through the real controller so every state shown is
    /// a state the audio pipeline would actually be in.
    ///
    /// All the cards share one controller, and therefore one loaded model:
    /// building six would load the model six times, which is slow and would put
    /// six copies of a gigabyte-scale network in memory at once.
    private static func popover(_ controller: AudioController,
                                mask: Int, enabled: Bool = true) -> NSView {
        controller.setEnabled(true)
        for stem in Stem.allCases {
            controller.setStem(stem, included: mask & (1 << stem.rawValue) != 0)
        }
        controller.setEnabled(enabled)
        let spotify = SpotifyState()
        spotify.injectSnapshotTrack(name: "Human Nature", artist: "Michael Jackson")
        let vc = PopoverViewController(controller: controller, spotify: spotify)
        vc.seedArtwork(fakeArtwork(), for: "snapshot")
        let view = vc.view
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        // The controller is shared, so this view has to be snapshotted before
        // the next card changes the mask under it.
        return freeze(view)
    }

    private static func makeController() -> AudioController {
        let controller = AudioController()
        controller.testHooks = (engage: { _, _ in }, disengage: { })
        controller.spotifyUpdate(running: true, playing: true, trackID: "snapshot")
        controller.setSemitones(2)
        return controller
    }

    /// Waits for the model, so the cards show the loaded state rather than
    /// "Preparing separation…" six times over. Skipped when there is no model.
    private static func waitForModel(_ controller: AudioController) {
        guard SeparationModel.isInstalled else { return }
        controller.setPreset(.backing)
        let deadline = Date().addingTimeInterval(20)
        while controller.preparingModel && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// Renders a live view into a flat image view, so later state changes
    /// cannot alter what was already laid out.
    private static func freeze(_ view: NSView) -> NSView {
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return view }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let host = NSImageView(frame: NSRect(origin: .zero, size: size))
        host.image = image
        host.imageScaling = .scaleNone
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: size.width),
            host.heightAnchor.constraint(equalToConstant: size.height),
        ])
        return host
    }

    // MARK: - Shared pieces

    private static func text(_ s: String, _ size: CGFloat,
                             _ weight: NSFont.Weight = .regular,
                             _ color: NSColor = .labelColor,
                             mono: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                      : .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        // Spacers are greedy; without this, labels lose the negotiation and
        // render as an ellipsis. Rows that must truncate opt out explicitly.
        f.setContentCompressionResistancePriority(.required, for: .horizontal)
        f.setContentHuggingPriority(.required, for: .horizontal)
        return f
    }

    private static func sectionTitle(_ s: String) -> NSTextField {
        text(s.uppercased(), 10, .semibold, .tertiaryLabelColor)
    }

    private static func vstack(_ views: [NSView], _ spacing: CGFloat,
                               _ align: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = align
        s.spacing = spacing
        return s
    }

    private static func hstack(_ views: [NSView], _ spacing: CGFloat,
                               _ align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = align
        s.spacing = spacing
        return s
    }

    /// A view that eats leftover horizontal space, pushing its neighbours apart.
    private static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private static func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        return v
    }

    private static func segmented(_ titles: [String], selected: Set<Int>,
                                  multi: Bool = false,
                                  size: CGFloat = 12) -> NSSegmentedControl {
        let c = NSSegmentedControl()
        c.segmentStyle = .rounded
        c.segmentCount = titles.count
        c.font = .systemFont(ofSize: size)
        c.focusRingType = .none
        c.trackingMode = multi ? .selectAny : .selectOne
        for (i, t) in titles.enumerated() {
            c.setLabel(t, forSegment: i)
            c.setSelected(selected.contains(i), forSegment: i)
        }
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return c
    }

    private static func transposeSlider(_ value: Double) -> NSSlider {
        let s = NSSlider()
        s.cell = TransposeSliderCell()
        s.minValue = -12
        s.maxValue = 12
        s.doubleValue = value
        s.focusRingType = .none
        s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        s.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return s
    }

    /// A stand-in album cover, so the mocks read like the real thing.
    private static func fakeArtwork() -> NSImage {
        let size = NSSize(width: 120, height: 120)
        let img = NSImage(size: size)
        img.lockFocus()
        let gradient = NSGradient(
            colors: [NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.25, alpha: 1),
                     NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.45, alpha: 1)])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -60)
        NSColor(white: 1, alpha: 0.20).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 34, y: 34, width: 52, height: 52))
        ring.lineWidth = 10
        ring.stroke()
        img.unlockFocus()
        return img
    }

    /// Wraps a card's content in a fixed-width, padded panel — the popover's
    /// own geometry, so `fittingSize` reports the height it would really be.
    private static func panel(_ content: NSStackView, width: CGFloat,
                              inset: CGFloat = 16) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: inset, left: inset,
                                          bottom: inset - 2, right: inset)
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        for v in content.arrangedSubviews {
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.widthAnchor.constraint(equalTo: content.widthAnchor,
                                     constant: -inset * 2).isActive = true
        }
        return container
    }

    // MARK: - The palette

    private static func ingredients() -> NSView {
        func row(_ caption: String, _ control: NSView) -> NSView {
            let c = text(caption, 11, .regular, .tertiaryLabelColor)
            c.widthAnchor.constraint(equalToConstant: 104).isActive = true
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return hstack([c, control], 10)
        }

        let sw = NSSwitch(); sw.state = .on; sw.controlSize = .mini
        let check = NSButton(checkboxWithTitle: "Checkbox", target: nil, action: nil)
        check.state = .on
        check.font = .systemFont(ofSize: 12)
        let radio = NSButton(radioButtonWithTitle: "Radio", target: nil, action: nil)
        radio.state = .on
        radio.font = .systemFont(ofSize: 12)

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["Backing", "Vocals", "All"])
        popup.font = .systemFont(ofSize: 12)

        let stepper = NSStepper()
        let field = NSTextField(string: "+2")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let level = NSLevelIndicator()
        level.levelIndicatorStyle = .continuousCapacity
        level.minValue = 0; level.maxValue = 10; level.doubleValue = 7

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = 0.62

        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.isIndeterminate = true

        var symbolStrip: [NSView] = []
        for stem in Stem.displayOrder {
            let v = NSImageView()
            v.image = NSImage(systemSymbolName: stem.symbolName,
                              accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            v.contentTintColor = .secondaryLabelColor
            symbolStrip.append(v)
        }

        let stack = vstack([
            sectionTitle("AppKit controls"),
            row("Switch", hstack([sw, spacer()], 0)),
            row("Checkbox", hstack([check, spacer()], 0)),
            row("Radio", hstack([radio, spacer()], 0)),
            row("Segmented", segmented(["A", "B", "C"], selected: [1])),
            row("Multi-select", segmented(["V", "D", "B"], selected: [0, 2], multi: true)),
            row("Pop-up", hstack([popup, spacer()], 0)),
            row("Stepper", hstack([field, stepper, spacer()], 4)),
            row("Slider", transposeSlider(2)),
            row("Level", level),
            row("Progress", bar),
            row("Spinner", hstack([spin, spacer()], 0)),
            sectionTitle("Drawn by hand"),
            row("Tiles", hstack([litTile(.bass), litTile(.piano), spacer()], 6)),
            row("Chips", hstack([litChip("On", true), litChip("Off", false),
                                 spacer()], 5)),
            row("SF Symbols", hstack(symbolStrip + [spacer()], 10)),
        ], 8)
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[11])
        spin.startAnimation(nil)
        return panel(stack, width: 300)
    }

    private static func litTile(_ stem: Stem) -> StemTile {
        let t = StemTile(stem: stem, target: nil, action: nil)
        t.lit = stem == .bass
        t.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return t
    }

    private static func litChip(_ title: String, _ lit: Bool) -> MixChip {
        let c = MixChip(title: title, target: nil, action: nil)
        c.lit = lit
        return c
    }

    // MARK: - Contact sheet

    /// Lays the variants out in rows of three, each on a labelled panel.
    private static func contactSheet(_ cards: [(String, String, NSView)]) -> NSView {
        let perRow = 3
        let gap: CGFloat = 26
        let margin: CGFloat = 26
        let captionHeight: CGFloat = 40

        var sized: [(String, String, NSView, NSSize)] = []
        for (title, note, view) in cards {
            view.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            view.frame = NSRect(origin: .zero, size: size)
            sized.append((title, note, view, size))
        }

        // Column widths and row heights, so ragged sizes still line up.
        var colWidth = [CGFloat](repeating: 0, count: perRow)
        var rowHeight: [CGFloat] = []
        for (i, entry) in sized.enumerated() {
            colWidth[i % perRow] = max(colWidth[i % perRow], entry.3.width)
            if i % perRow == 0 { rowHeight.append(0) }
            rowHeight[i / perRow] = max(rowHeight[i / perRow], entry.3.height)
        }

        let totalWidth = margin * 2 + colWidth.reduce(0, +) + gap * CGFloat(perRow - 1)
        let totalHeight = margin * 2
            + rowHeight.reduce(0, +) + (captionHeight + gap) * CGFloat(rowHeight.count)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        host.wantsLayer = true
        host.appearance = NSAppearance(named: .darkAqua)
        host.layer?.backgroundColor = sheetBG.cgColor

        // Top-down placement, converted to AppKit's bottom-left origin.
        var y = totalHeight - margin
        for r in 0..<rowHeight.count {
            var x = margin
            for c in 0..<perRow {
                let i = r * perRow + c
                guard i < sized.count else { break }
                let (title, note, view, size) = sized[i]

                let label = text(title, 13, .semibold, .labelColor)
                label.frame = NSRect(x: x, y: y - 17, width: colWidth[c], height: 17)
                host.addSubview(label)
                let sub = text(note, 11, .regular, .tertiaryLabelColor)
                sub.frame = NSRect(x: x, y: y - 33, width: colWidth[c], height: 14)
                host.addSubview(sub)

                let top = y - captionHeight
                let frame = NSRect(x: x, y: top - size.height,
                                   width: size.width, height: size.height)
                let plate = NSView(frame: frame)
                plate.wantsLayer = true
                plate.layer?.backgroundColor = popoverBG.cgColor
                plate.layer?.cornerRadius = 10
                plate.layer?.masksToBounds = true
                view.frame = plate.bounds
                plate.addSubview(view)
                host.addSubview(plate)

                x += colWidth[c] + gap
            }
            y -= captionHeight + rowHeight[r] + gap
        }
        host.layoutSubtreeIfNeeded()
        return host
    }

    private static func writePNG(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
