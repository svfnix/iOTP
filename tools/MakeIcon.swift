// Draws the app icon PNGs into an .iconset folder. Run: swift tools/MakeIcon.swift <output-iconset-dir>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> Data? {
    let scale: CGFloat = size / 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { return nil }

    // Rounded-rect background with a vertical gradient.
    let inset = 84 * scale
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: 190 * scale, cornerHeight: 190 * scale, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.95, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.85, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: size, y: 0),
                                   options: [])
    }
    context.restoreGState()

    // Key glyph.
    if let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .semibold)
        if let glyph = key.withSymbolConfiguration(config) {
            let tinted = NSImage(size: glyph.size)
            tinted.lockFocus()
            NSColor.white.set()
            let bounds = NSRect(origin: .zero, size: glyph.size)
            glyph.draw(in: bounds)
            bounds.fill(using: .sourceAtop)
            tinted.unlockFocus()

            let target = NSRect(x: (size - glyph.size.width) / 2,
                                y: (size - glyph.size.height) / 2 + 40 * scale,
                                width: glyph.size.width,
                                height: glyph.size.height)
            tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.95)
        }
    }

    // "OTP" wordmark.
    let text = "OTP" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 150 * scale, weight: .heavy),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .kern: 8 * scale
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: 175 * scale), withAttributes: attributes)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let data = drawIcon(size: variant.size) else {
        FileHandle.standardError.write("Failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
}
print("Wrote \(variants.count) icon sizes to \(outputURL.path)")
