import AppKit
import CoreText

// Renders the Transposify app icon (blue squircle + white treble clef) into a
// .iconset directory. Usage: swift tools/make-icon.swift <out.iconset>

func renderPNG(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Rounded-rectangle body with macOS-style margins.
    let margin = s * 0.085
    let body = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                 color: NSColor.black.withAlphaComponent(0.28).cgColor)
    cg.addPath(path); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
    cg.restoreGState()

    // Blue gradient fill.
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let fill = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.33, green: 0.64, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.13, green: 0.39, blue: 0.90, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(fill, start: CGPoint(x: body.midX, y: body.maxY),
                          end: CGPoint(x: body.midX, y: body.minY), options: [])
    // Subtle top highlight.
    let hl = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.20).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(hl, start: CGPoint(x: body.midX, y: body.maxY),
                          end: CGPoint(x: body.midX, y: body.midY), options: [])
    cg.restoreGState()

    // White treble clef, sized to its actual ink and visually centered. The
    // glyph carries lots of internal whitespace, so we measure its image bounds
    // (not the font's line box) to fill the body and center precisely.
    let clef = "\u{1D11E}"
    func clefLine(_ fontSize: CGFloat) -> CTLine {
        let base = NSFont.systemFont(ofSize: fontSize)
        let font = CTFontCreateForString(
            base, clef as CFString, CFRange(location: 0, length: (clef as NSString).length))
        let attributed = NSAttributedString(string: clef, attributes: [
            .font: font, .foregroundColor: NSColor.white,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }
    let referenceSize = s * 0.6
    let referenceBounds = CTLineGetImageBounds(clefLine(referenceSize), cg)
    let targetHeight = body.height * 0.80
    let finalSize = referenceSize * (targetHeight / referenceBounds.height)
    let line = clefLine(finalSize)
    let inkBounds = CTLineGetImageBounds(line, cg)
    cg.textPosition = CGPoint(x: body.midX - inkBounds.midX, y: body.midY - inkBounds.midY)
    CTLineDraw(line, cg)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    try! renderPNG(px: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(entries.count) images to \(outDir)")
