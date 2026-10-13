// Generates Resources/AppIcon.icns: a coral squircle with a white speech bubble holding a return arrow.
// Usage: swift scripts/make-icon.swift
import AppKit

let coralTop = NSColor(red: 0.91, green: 0.55, blue: 0.42, alpha: 1)
let coralBottom = NSColor(red: 0.78, green: 0.38, blue: 0.27, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Apple's icon grid: 824 pt body centred on a 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSGradient(starting: coralTop, ending: coralBottom)!.draw(in: squircle, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Speech bubble with a tail at the bottom left.
    let bubbleRect = NSRect(x: 250 * s, y: 330 * s, width: 524 * s, height: 400 * s)
    let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 120 * s, yRadius: 120 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 330 * s, y: 360 * s))
    tail.line(to: NSPoint(x: 290 * s, y: 250 * s))
    tail.line(to: NSPoint(x: 450 * s, y: 340 * s))
    tail.close()
    bubble.append(tail)
    NSGraphicsContext.saveGraphicsState()
    let soft = NSShadow()
    soft.shadowColor = NSColor.black.withAlphaComponent(0.18)
    soft.shadowOffset = NSSize(width: 0, height: -8 * s)
    soft.shadowBlurRadius = 20 * s
    soft.set()
    NSColor.white.setFill()
    bubble.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Return arrow inside the bubble.
    let config = NSImage.SymbolConfiguration(pointSize: 230 * s, weight: .bold)
        .applying(.init(paletteColors: [coralBottom]))
    if let arrow = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let a = arrow.size
        arrow.draw(in: NSRect(x: bubbleRect.midX - a.width / 2, y: bubbleRect.midY - a.height / 2,
                              width: a.width, height: a.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeResume.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 512).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns and docs/icon.png")
