// Generates AppIcon PNGs: dark squircle, red mic, white level bars —
// the HUD's visual language. Run from the repo root:
//   swift scripts/make_icon.swift PushToTalk/PushToTalk/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : ".")

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    result.unlockFocus()
    return result
}

// ---- Compose the 1024pt master ----------------------------------------
let canvas: CGFloat = 1024
let master = NSImage(size: NSSize(width: canvas, height: canvas))
master.lockFocus()

// Squircle on transparent background. Apple's icon grid leaves ~10% margin;
// 22.37% corner radius approximates the system squircle.
let inset: CGFloat = 100
let plate = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let squircle = NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237)
NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1),
])!.draw(in: plate, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// Red mic (SF Symbol), upper-center.
let config = NSImage.SymbolConfiguration(pointSize: 380, weight: .medium)
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let red = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    let img = tinted(mic, red)
    let s = img.size
    img.draw(in: NSRect(x: 512 - s.width / 2, y: 600 - s.height / 2,
                        width: s.width, height: s.height))
}

// White level bars, lower third (the HUD waveform).
let heights: [CGFloat] = [70, 130, 190, 130, 70]
let barWidth: CGFloat = 40, gap: CGFloat = 32
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = 512 - total / 2
NSColor(calibratedWhite: 0.95, alpha: 1).set()
for h in heights {
    NSBezierPath(roundedRect: NSRect(x: x, y: 270 - h / 2, width: barWidth, height: h),
                 xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}
master.unlockFocus()

// ---- Emit every macOS icon slot ----------------------------------------
func save(_ pixels: Int, _ name: String) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: outputDir.appendingPathComponent(name))
}

let slots: [(Int, String)] = [
    (16, "icon_16.png"), (32, "icon_16@2x.png"),
    (32, "icon_32.png"), (64, "icon_32@2x.png"),
    (128, "icon_128.png"), (256, "icon_128@2x.png"),
    (256, "icon_256.png"), (512, "icon_256@2x.png"),
    (512, "icon_512.png"), (1024, "icon_512@2x.png"),
]
for (pixels, name) in slots { try save(pixels, name) }
print("wrote \(slots.count) icons to \(outputDir.path)")
