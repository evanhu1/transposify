import AppKit

/// The blue used for anything the user has switched on.
let accentColor = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)

extension Stem {
    /// The order stems are shown in. "Other" is the catch-all — everything the
    /// model could not name — so it reads last, even though the model emits it
    /// third. `rawValue` stays the model's channel index and must not move.
    static let displayOrder: [Stem] = [.vocals, .drums, .bass, .guitar, .piano, .other]

    /// SF Symbols has no drum kit and no standalone bass, so two of these are
    /// the nearest glyph that still reads at 15 pt rather than an exact match.
    var symbolName: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums: return "metronome"
        case .bass: return "hifispeaker"
        case .other: return "music.quarternote.3"
        case .guitar: return "guitars"
        case .piano: return "pianokeys"
        }
    }
}

/// Shared behaviour for the two hand-drawn mix controls.
///
/// Both are `NSButton`s that draw themselves, which is worth the few lines: it
/// keeps target/action, `isEnabled`, keyboard focus and accessibility working
/// exactly as they do for a system control. `lit` is set from the controller on
/// every refresh rather than toggled on click, so the button can never show a
/// state the audio pipeline does not have.
class MixToggle: NSButton {
    var lit: Bool = false {
        didSet { if lit != oldValue { needsDisplay = true } }
    }

    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    init(label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        setAccessibilityLabel(label)
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Fill, border and text colour for the current state, so the two shapes
    /// stay in step with each other.
    func palette() -> (fill: NSColor, stroke: NSColor?, text: NSColor) {
        guard isEnabled else {
            return (NSColor(white: 0.5, alpha: 0.06), nil, .tertiaryLabelColor)
        }
        if lit {
            return (accentColor.withAlphaComponent(hovering ? 0.34 : 0.24),
                    accentColor.withAlphaComponent(0.9),
                    .labelColor)
        }
        // Unselected, but still an offer: a secondary-grey pill reads as
        // disabled chrome, so the off state keeps a visible fill, a defined
        // edge, and text just under full strength.
        return (NSColor(white: 0.5, alpha: hovering ? 0.24 : 0.15),
                NSColor(white: 0.5, alpha: 0.34),
                NSColor.labelColor.withAlphaComponent(0.78))
    }

    func paint(_ path: NSBezierPath) {
        let colors = palette()
        colors.fill.setFill()
        path.fill()
        if let stroke = colors.stroke {
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// One stem, drawn as a tile: icon over name, lit when that stem reaches the
/// output. The tile *is* the state — there is no separate mode to enter — so
/// the interface cannot show a selection the audio does not have.
final class StemTile: MixToggle {
    let stem: Stem

    init(stem: Stem, target: AnyObject?, action: Selector?) {
        self.stem = stem
        super.init(label: stem.title, target: target, action: action)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 50)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        paint(NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7))

        // NSButton is a flipped view: y grows downward, so both offsets below
        // are measured from the top edge.
        let fg = palette().text
        if let icon = NSImage(systemSymbolName: stem.symbolName,
                              accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
            let tint = icon.tinted(fg)
            tint.draw(in: NSRect(x: bounds.midX - tint.size.width / 2, y: 9,
                                 width: tint.size.width, height: tint.size.height))
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: lit ? .medium : .regular),
            .foregroundColor: fg,
        ]
        let text = stem.title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.height - size.height - 8),
                  withAttributes: attributes)
    }
}

/// A preset, drawn as a pill. Lighter than a segmented control, and unlike one
/// it can sit next to shapes of a different kind without looking like a
/// separate panel.
final class MixChip: MixToggle {
    private let text: String

    init(title: String, target: AnyObject?, action: Selector?) {
        text = title
        super.init(label: title, target: target, action: action)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: lit ? .medium : .regular),
         .foregroundColor: lit && isEnabled ? NSColor.white : palette().text]
    }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width) + 22, height: 22)
    }

    override func palette() -> (fill: NSColor, stroke: NSColor?, text: NSColor) {
        // The chip is a solid fill when lit, so it reads as the current answer
        // at a glance; the tiles below only tint.
        guard isEnabled, lit else { return super.palette() }
        return (accentColor.withAlphaComponent(0.95), nil, .white)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        paint(NSBezierPath(roundedRect: rect,
                           xRadius: rect.height / 2, yRadius: rect.height / 2))
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                y: bounds.midY - size.height / 2),
                    withAttributes: attributes)
    }
}

extension NSImage {
    /// Recolours a template symbol. `contentTintColor` only applies to views,
    /// and these controls draw the image directly.
    func tinted(_ color: NSColor) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        draw(at: .zero, from: NSRect(origin: .zero, size: size),
             operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}
