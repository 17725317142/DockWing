import AppKit
import CoreGraphics
import Foundation

// Generate a crisp, native macOS-style squircle icon with an upward triangle (Windows-tray inspired)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func drawIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS standard icon inset (~10% padding)
    let inset = s * 0.095
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Subtle drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.23, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background rich dark-glass gradient
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(calibratedRed: 0.26, green: 0.30, blue: 0.38, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.21, alpha: 1.0).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )
    }

    // Soft top highlight glow
    let glowColors = [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: rect.midX, y: rect.maxY),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.maxY),
            endRadius: rect.width * 0.85,
            options: []
        )
    }
    ctx.restoreGState()

    // Inner glass rim stroke
    ctx.saveGState()
    let borderRect = rect.insetBy(dx: max(0.5, s * 0.008), dy: max(0.5, s * 0.008))
    let borderPath = CGPath(roundedRect: borderRect, cornerWidth: cornerRadius * 0.96, cornerHeight: cornerRadius * 0.96, transform: nil)
    ctx.addPath(borderPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
    ctx.setLineWidth(max(1.0, s * 0.014))
    ctx.strokePath()
    ctx.restoreGState()

    // Upward chevron / triangle (crisp, rounded corners, Windows tray inspired)
    ctx.saveGState()
    let cx = rect.midX
    let cy = rect.midY
    let halfW = rect.width * 0.255
    let topY = cy + rect.height * 0.12
    let botY = cy - rect.height * 0.10

    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: cx - halfW, y: botY))
    chevron.addLine(to: CGPoint(x: cx, y: topY))
    chevron.addLine(to: CGPoint(x: cx + halfW, y: botY))

    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(chevron)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    ctx.setLineWidth(max(2.0, rect.width * 0.115))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Subtle tray indicator pill below the chevron
    let dotW = rect.width * 0.22
    let dotH = max(1.5, rect.height * 0.055)
    let dotRect = CGRect(x: cx - dotW / 2, y: botY - rect.height * 0.16, width: dotW, height: dotH)
    let dotPath = CGPath(roundedRect: dotRect, cornerWidth: dotH / 2, cornerHeight: dotH / 2, transform: nil)
    ctx.addPath(dotPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.42, green: 0.78, blue: 1.0, alpha: 0.92).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (size, filename) in sizes {
    if let data = drawIcon(pixelSize: size) {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(filename)
        try data.write(to: url)
    }
}
print("Generated iconset at \(outDir)")
