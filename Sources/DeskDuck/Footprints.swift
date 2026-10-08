import AppKit
import QuartzCore

/// Muddy webbed footprints that fade away on their own. One click-through overlay window per screen;
/// each print is a Core Animation layer that fades itself out, so there's no redrawing.
final class FootprintOverlay {
    private var windows: [String: NSWindow] = [:]   // keyed by screen frame
    private static let lifetime: CFTimeInterval = 55
    private static let mud = NSColor(srgbRed: 0.36, green: 0.24, blue: 0.13, alpha: 0.8).cgColor

    /// `at` is the point on the surface (AppKit global coords) under the foot.
    func add(at p: CGPoint, facing: CGFloat, scale: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: p.x, y: p.y + 1)) }),
              let host = window(for: screen.frame).contentView?.layer else { return }
        let print = CAShapeLayer()
        print.path = FootprintOverlay.footPath
        print.fillColor = FootprintOverlay.mud
        print.position = CGPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY - 2 * scale)
        // Toes point the way it's walking; squashed flat because we see the surface nearly edge-on.
        let tilt = CGFloat.random(in: -0.15...0.15)
        print.setAffineTransform(CGAffineTransform(scaleX: facing * scale, y: scale * 0.42).rotated(by: tilt))
        host.addSublayer(print)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.01, 0.85, 1]
        fade.duration = FootprintOverlay.lifetime
        print.opacity = 0
        print.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + FootprintOverlay.lifetime) { [weak self] in
            print.removeFromSuperlayer()
            self?.hideEmptyWindows()
        }
    }

    private func window(for frame: NSRect) -> NSWindow {
        if let w = windows[NSStringFromRect(frame)] {
            if !w.isVisible { w.orderFrontRegardless() }
            return w
        }
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar   // just under the duck
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        w.contentView = v
        w.setFrame(frame, display: false)
        w.orderFrontRegardless()
        windows[NSStringFromRect(frame)] = w
        return w
    }

    private func hideEmptyWindows() {
        for w in windows.values where (w.contentView?.layer?.sublayers ?? []).isEmpty { w.orderOut(nil) }
    }

    /// A duck footprint: three webbed toes pointing along +x from a rounded heel, about 20 units long.
    private static let footPath: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -2, y: 0))
        p.addQuadCurve(to: CGPoint(x: 15, y: 9), control: CGPoint(x: 4, y: 8))
        p.addQuadCurve(to: CGPoint(x: 12, y: 3.5), control: CGPoint(x: 15, y: 5))
        p.addQuadCurve(to: CGPoint(x: 19, y: 0), control: CGPoint(x: 17, y: 3))
        p.addQuadCurve(to: CGPoint(x: 12, y: -3.5), control: CGPoint(x: 17, y: -3))
        p.addQuadCurve(to: CGPoint(x: 15, y: -9), control: CGPoint(x: 15, y: -5))
        p.addQuadCurve(to: CGPoint(x: -2, y: 0), control: CGPoint(x: 4, y: -8))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: -5, y: -3, width: 6, height: 6))
        return p
    }()
}
