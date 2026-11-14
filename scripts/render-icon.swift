// Renders assets/AppIcon.svg's design to a transparent 1024 px PNG with CoreGraphics.
// (QuickLook flattens the SVG onto white, so it cannot be used for an app icon.)
//   swift scripts/render-icon.swift OUT.png
import AppKit

let size = 1024
guard CommandLine.arguments.count == 2 else { print("usage: render-icon.swift OUT.png"); exit(2) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)                       // SVG coordinates: y grows downward

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
let space = CGColorSpaceCreateDeviceRGB()
func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
    CGGradient(colorsSpace: space, colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
}

// Background: rounded square, 824 px at offset 100, radius 185
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
ctx.drawLinearGradient(gradient(0x2b3a55, 0x121a2b), start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
ctx.restoreGState()

// Shield
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 214))
shield.addLine(to: CGPoint(x: 760, y: 308))
shield.addLine(to: CGPoint(x: 760, y: 506))
shield.addCurve(to: CGPoint(x: 512, y: 840), control1: CGPoint(x: 760, y: 662), control2: CGPoint(x: 654, y: 770))
shield.addCurve(to: CGPoint(x: 264, y: 506), control1: CGPoint(x: 370, y: 770), control2: CGPoint(x: 264, y: 662))
shield.addLine(to: CGPoint(x: 264, y: 308))
shield.closeSubpath()
ctx.saveGState()
ctx.addPath(shield); ctx.clip()
ctx.drawLinearGradient(gradient(0x4be08a, 0x1b9a5c), start: CGPoint(x: 0, y: 214), end: CGPoint(x: 0, y: 840), options: [])
ctx.setFillColor(color(0x000000, 0.12))          // darker right half
ctx.fill(CGRect(x: 512, y: 200, width: 260, height: 660))
ctx.restoreGState()

// Keyhole
ctx.setFillColor(color(0x0f2a1c))
ctx.fillEllipse(in: CGRect(x: 450, y: 432, width: 124, height: 124))
ctx.move(to: CGPoint(x: 488, y: 530)); ctx.addLine(to: CGPoint(x: 536, y: 530))
ctx.addLine(to: CGPoint(x: 552, y: 628)); ctx.addLine(to: CGPoint(x: 472, y: 628)); ctx.closePath()
ctx.fillPath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
