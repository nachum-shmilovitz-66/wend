// Renders the Wend app icon (double-shift keycap) to a 1024×1024 PNG.
// Pure offscreen CoreGraphics — no running NSApplication needed.
//   swift scripts/icon_render.swift /path/to/out.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("could not create bitmap") }

NSGraphicsContext.saveGraphicsState()
guard let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = nsctx
let cg = nsctx.cgContext

// --- Squircle background with diagonal indigo→cyan gradient ---
let margin = size * 0.05
let rect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let corner = rect.width * 0.2237   // Apple "continuous corner" ratio
let bg = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
cg.saveGState()
cg.addPath(bg)
cg.clip()
let colors = [
    NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1).cgColor,  // indigo
    NSColor(srgbRed: 0.02, green: 0.71, blue: 0.83, alpha: 1).cgColor,  // cyan
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
cg.drawLinearGradient(grad,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
cg.restoreGState()

// --- Inset "keycap" face (subtle lighter rounded rect) ---
let capInset = size * 0.16
let capRect = rect.insetBy(dx: capInset, dy: capInset)
let capCorner = capRect.width * 0.22
let cap = CGPath(roundedRect: capRect, cornerWidth: capCorner, cornerHeight: capCorner, transform: nil)
cg.addPath(cap)
cg.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor)
cg.fillPath()
cg.addPath(cap)
cg.setStrokeColor(NSColor(white: 1, alpha: 0.30).cgColor)
cg.setLineWidth(size * 0.012)
cg.strokePath()

// --- Double up-chevron (the double-Shift gesture), bold white ---
cg.setStrokeColor(NSColor.white.cgColor)
cg.setLineWidth(size * 0.085)
cg.setLineCap(.round)
cg.setLineJoin(.round)
let cx = size / 2
let halfW = size * 0.19
let rise = size * 0.13
func chevron(apexY: CGFloat) {   // y-up: apex points up
    cg.move(to: CGPoint(x: cx - halfW, y: apexY - rise))
    cg.addLine(to: CGPoint(x: cx, y: apexY))
    cg.addLine(to: CGPoint(x: cx + halfW, y: apexY - rise))
}
chevron(apexY: size * 0.61)   // upper
chevron(apexY: size * 0.45)   // lower
cg.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
