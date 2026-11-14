// Renders the TabFlow app icon to a 1024x1024 PNG.  Usage: make-icon <out.png>
import Cocoa

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.98, alpha: 1),
                    NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.98, alpha: 1)])!.draw(in: bg, angle: -60)

func window(_ r: NSRect, alpha: CGFloat) {
    let p = NSBezierPath(roundedRect: r, xRadius: 40, yRadius: 40)
    NSColor(white: 1, alpha: alpha).setFill(); p.fill()
    let bar = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.maxY - 70, width: r.width, height: 70), xRadius: 40, yRadius: 40)
    NSColor(white: 1, alpha: min(1, alpha + 0.25)).setFill(); bar.fill()
}
window(NSRect(x: 230, y: 380, width: 420, height: 330), alpha: 0.35)
window(NSRect(x: 370, y: 280, width: 420, height: 330), alpha: 0.85)

// arrow
let a = NSBezierPath()
a.lineWidth = 46; a.lineCapStyle = .round; a.lineJoinStyle = .round
a.move(to: NSPoint(x: 470, y: 430)); a.line(to: NSPoint(x: 680, y: 430))
a.move(to: NSPoint(x: 610, y: 500)); a.line(to: NSPoint(x: 680, y: 430)); a.line(to: NSPoint(x: 610, y: 360))
NSColor(calibratedRed: 0.27, green: 0.35, blue: 0.98, alpha: 1).setStroke(); a.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
