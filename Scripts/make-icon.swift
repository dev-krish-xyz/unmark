// Renders Resources/AppIcon.icns. Run: swift Scripts/make-icon.swift
import AppKit

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with a continuous-corner radius.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    NSColor(white: 0.07, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: size * 185 / 1024, yRadius: size * 185 / 1024).fill()

    // Original glyph (SF Symbols may not be used in app icons): a tilted eraser over a dashed line.
    let unit = size / 1024
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let transform = NSAffineTransform()
    transform.translateX(by: size * 0.445, yBy: size * 0.55)
    transform.rotate(byDegrees: 45)
    let eraser = NSBezierPath(roundedRect: CGRect(x: -150 * unit, y: -95 * unit, width: 300 * unit, height: 190 * unit),
                              xRadius: 42 * unit, yRadius: 42 * unit)
    eraser.lineWidth = 34 * unit
    eraser.transform(using: transform as AffineTransform)
    eraser.stroke()
    let band = NSBezierPath()
    band.move(to: CGPoint(x: -55 * unit, y: -95 * unit))
    band.line(to: CGPoint(x: -55 * unit, y: 95 * unit))
    band.lineWidth = 34 * unit
    band.transform(using: transform as AffineTransform)
    band.stroke()
    for x in [535.0, 655.0] {
        NSBezierPath(roundedRect: CGRect(x: x * unit, y: 318 * unit, width: 90 * unit, height: 34 * unit),
                     xRadius: 17 * unit, yRadius: 17 * unit).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
