import AppKit
import KillSwitchClient

/// Template status icons drawn in code from the shield in assets/menubar-*.svg
/// (16 x 16 viewBox, y down). Drawn into a bitmap so the cut-outs are real transparency.
enum StatusIcons {
    private static let px = 36            // 18 pt at 2x

    static func image(for kind: UIKind) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 18, height: 18)
        let gctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        // rep.size is 18 pt, so the context is in points (the 36 px backing is only for sharpness)
        let s = CGFloat(18) / 16
        let t = NSAffineTransform()
        t.translateX(by: 0, yBy: 18); t.scaleX(by: s, yBy: -s)             // SVG coordinates, y down
        t.concat()
        NSColor.black.set()
        draw(kind, gctx)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: 18, height: 18))
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }

    private static func shield() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 8, y: 1.5)); p.line(to: NSPoint(x: 13, y: 3.4)); p.line(to: NSPoint(x: 13, y: 7.6))
        p.curve(to: NSPoint(x: 8, y: 14.5), controlPoint1: NSPoint(x: 13, y: 10.6), controlPoint2: NSPoint(x: 10.9, y: 12.8))
        p.curve(to: NSPoint(x: 3, y: 7.6), controlPoint1: NSPoint(x: 5.1, y: 12.8), controlPoint2: NSPoint(x: 3, y: 10.6))
        p.line(to: NSPoint(x: 3, y: 3.4)); p.close()
        return p
    }

    private static func stroke(_ p: NSBezierPath, _ w: CGFloat = 1.2) {
        p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
    }

    private static func line(_ a: NSPoint, _ b: NSPoint, _ w: CGFloat = 1.4) {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b); stroke(p, w)
    }

    private static func draw(_ kind: UIKind, _ g: NSGraphicsContext) {
        switch kind {
        case .protected:
            shield().fill()
        case .blocked:
            shield().fill()
            g.compositingOperation = .clear
            line(NSPoint(x: 6, y: 6), NSPoint(x: 10, y: 10)); line(NSPoint(x: 10, y: 6), NSPoint(x: 6, y: 10))
            g.compositingOperation = .sourceOver
        case .off:
            stroke(shield())
        case .paused:
            stroke(shield())
            NSBezierPath(rect: NSRect(x: 5.9, y: 5.2, width: 1.5, height: 5)).fill()
            NSBezierPath(rect: NSRect(x: 8.6, y: 5.2, width: 1.5, height: 5)).fill()
        case .degraded:
            stroke(shield())
            line(NSPoint(x: 8, y: 4.8), NSPoint(x: 8, y: 8.6))
            NSBezierPath(ovalIn: NSRect(x: 7.2, y: 9.7, width: 1.6, height: 1.6)).fill()
        case .unreachable:
            g.cgContext.setAlpha(0.55)
            stroke(shield())
            let q = NSBezierPath()
            q.move(to: NSPoint(x: 6.3, y: 6.4))
            q.curve(to: NSPoint(x: 9.7, y: 6.4), controlPoint1: NSPoint(x: 6.3, y: 4), controlPoint2: NSPoint(x: 9.7, y: 4))
            q.curve(to: NSPoint(x: 8, y: 8.4), controlPoint1: NSPoint(x: 9.7, y: 7.5), controlPoint2: NSPoint(x: 8, y: 7.6))
            stroke(q, 1.2)
            NSBezierPath(ovalIn: NSRect(x: 7.2, y: 9.6, width: 1.6, height: 1.6)).fill()
        }
    }
}
