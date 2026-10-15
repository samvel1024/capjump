// Renders an SVG to a square PNG with AppKit (macOS 14+ reads SVG natively).
// usage: svg2png <in.svg> <out.png> <size>
import AppKit
let args = CommandLine.arguments
let size = CGFloat(Double(args[3]) ?? 1024)
guard let img = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else { print("cannot load svg"); exit(1) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
