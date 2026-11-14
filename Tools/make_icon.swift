// Zeichnet das App-Symbol („Aurora“) und schreibt alle Größen nach
// JellyDesk/Assets.xcassets/AppIcon.appiconset.
// Aufruf im Projektordner: swift Tools/make_icon.swift
import AppKit

let outDir = URL(fileURLWithPath: "JellyDesk/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

/// Das Motiv: der Farbschein hinter der Anmeldung des Themes (Blau, Orange, Violett auf Nachtblau),
/// darauf eine Glas-Scheibe mit weißem Wiedergabe-Dreieck.
func draw(_ ctx: CGContext, size s: CGFloat) {
    // macOS-Raster: Fläche 824 von 1024, Eckenradius rund 22,4 %.
    let inset = s * 100 / 1024
    let plate = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let platePath = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.2237, cornerHeight: plate.width * 0.2237, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.4))
    ctx.addPath(platePath)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    // Hintergrund mit drei weichen Farbquellen
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    ctx.setFillColor(color(0x0A0C16))
    ctx.fill(plate)
    func glow(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
        let center = CGPoint(x: plate.minX + plate.width * x, y: plate.minY + plate.height * y)
        ctx.drawRadialGradient(gradient([color(hex, alpha), color(hex, 0)]), startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: plate.width * radius, options: [])
    }
    glow(0.95, 0.95, 0.85, 0x0A84FF, 0.85)
    glow(0.02, 0.90, 0.70, 0xFF9F0A, 0.70)
    glow(0.30, 0.00, 0.75, 0xBF5AF2, 0.60)
    ctx.addPath(platePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(s * 0.006)
    ctx.strokePath()
    ctx.restoreGState()

    // Glas-Scheibe
    let d = plate.width * 0.58
    let circle = CGRect(x: plate.midX - d / 2, y: plate.midY - d / 2, width: d, height: d)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.04, color: color(0x000000, 0.35))
    ctx.setFillColor(color(0xFFFFFF, 0.16))
    ctx.fillEllipse(in: circle)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: circle)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0.02)]),
                           start: CGPoint(x: circle.midX, y: circle.maxY), end: CGPoint(x: circle.midX, y: circle.minY), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.45))
    ctx.setLineWidth(s * 0.007)
    ctx.strokeEllipse(in: circle.insetBy(dx: s * 0.0035, dy: s * 0.0035))

    // Wiedergabe-Dreieck mit runden Ecken, optisch mittig (leicht nach rechts versetzt)
    let side = d * 0.46
    let h = side * 0.866
    let center = CGPoint(x: plate.midX + h * 0.08, y: plate.midY)
    let p1 = CGPoint(x: center.x - h / 2, y: center.y + side / 2)
    let p2 = CGPoint(x: center.x - h / 2, y: center.y - side / 2)
    let p3 = CGPoint(x: center.x + h / 2, y: center.y)
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2))
    triangle.addArc(tangent1End: p2, tangent2End: p3, radius: d * 0.055)
    triangle.addArc(tangent1End: p3, tangent2End: p1, radius: d * 0.055)
    triangle.addArc(tangent1End: p1, tangent2End: p2, radius: d * 0.055)
    triangle.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.02, color: color(0x000000, 0.35))
    ctx.addPath(triangle)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    draw(graphics.cgContext, size: CGFloat(pixels))
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try png(pixels: points * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("Symbol geschrieben nach \(outDir.path)")
