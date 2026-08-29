#!/usr/bin/env swift
import AppKit

// Draws the app icon (a warm↔cool gradient tile with TrueTone's half-circle
// motif) at every iconset size and runs iconutil to produce Resources/AppIcon.icns.
// Run from the repo root:  swift scripts/make-icon.swift

let outDir = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let inset = s * 0.098          // Apple macOS grid: 824/1024 body on the canvas
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect,
                            xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    tile.addClip()

    // pale tile — cool tint top-left → warm tint bottom-right, so the mark pops
    NSGradient(starting: NSColor(srgbRed: 0.92, green: 0.95, blue: 0.99, alpha: 1),
               ending:   NSColor(srgbRed: 0.99, green: 0.94, blue: 0.87, alpha: 1))!
        .draw(in: rect, angle: -55)

    // the mark: a circle split cool | warm
    let d = rect.width * 0.56
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let box = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)

    let left = NSBezierPath()
    left.appendArc(withCenter: c, radius: d / 2, startAngle: 90, endAngle: 270)
    left.close()
    NSColor(srgbRed: 0.37, green: 0.60, blue: 0.87, alpha: 1).setFill()   // cool
    left.fill()

    let right = NSBezierPath()
    right.appendArc(withCenter: c, radius: d / 2, startAngle: 270, endAngle: 90)
    right.close()
    NSColor(srgbRed: 0.95, green: 0.65, blue: 0.29, alpha: 1).setFill()   // warm
    right.fill()

    let divider = NSBezierPath()
    divider.move(to: CGPoint(x: c.x, y: c.y - d / 2))
    divider.line(to: CGPoint(x: c.x, y: c.y + d / 2))
    divider.lineWidth = max(1, s * 0.018)
    NSColor.white.setStroke()
    divider.stroke()

    let ring = NSBezierPath(ovalIn: box)
    ring.lineWidth = max(1, s * 0.02)
    NSColor(white: 0, alpha: 0.10).setStroke()
    ring.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ name: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

for base in [16, 32, 128, 256, 512] {
    write(render(base), "icon_\(base)x\(base).png")
    write(render(base * 2), "icon_\(base)x\(base)@2x.png")
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", outDir, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
