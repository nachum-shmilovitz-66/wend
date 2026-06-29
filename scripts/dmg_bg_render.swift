// Renders the DMG window background (560×400) to a PNG.
//   swift scripts/dmg_bg_render.swift /path/to/bg.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bg.png"
let W: CGFloat = 560, H: CGFloat = 400

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap") }

NSGraphicsContext.saveGraphicsState()
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
let cg = nsctx.cgContext

// Soft light-blue vertical gradient.
let bg = [
    NSColor(srgbRed: 0.97, green: 0.98, blue: 1.00, alpha: 1).cgColor,
    NSColor(srgbRed: 0.89, green: 0.93, blue: 0.98, alpha: 1).cgColor,
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// Centered text (y-up: larger y = higher on screen).
func text(_ s: String, _ pt: CGFloat, _ w: NSFont.Weight, _ c: NSColor, baselineY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pt, weight: w), .foregroundColor: c]
    let str = NSAttributedString(string: s, attributes: attrs)
    str.draw(at: CGPoint(x: (W - str.size().width) / 2, y: baselineY))
}
text("Wend", 30, .bold, NSColor(white: 0.15, alpha: 1), baselineY: H - 72)
text("Drag Wend onto Applications to install", 14, .regular, NSColor(white: 0.42, alpha: 1), baselineY: H - 104)

// Right-pointing arrow between the two icon slots (icon centers at content-y 170 → y-up 230).
let indigo = NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1).cgColor
let ay = H - 170
cg.setStrokeColor(indigo); cg.setFillColor(indigo)
cg.setLineWidth(10); cg.setLineCap(.round)
cg.move(to: CGPoint(x: W / 2 - 42, y: ay))
cg.addLine(to: CGPoint(x: W / 2 + 28, y: ay))
cg.strokePath()
cg.move(to: CGPoint(x: W / 2 + 46, y: ay))           // arrowhead
cg.addLine(to: CGPoint(x: W / 2 + 18, y: ay + 17))
cg.addLine(to: CGPoint(x: W / 2 + 18, y: ay - 17))
cg.closePath(); cg.fillPath()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
