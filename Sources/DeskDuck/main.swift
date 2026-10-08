import AppKit
import SceneKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    // Renders the 1024px app icon: a close-up of the duck's head mid-quack on a cream squircle with a dotted pattern.
    let size: CGFloat = 1024
    let s = DuckScene(theme: DuckTheme.all[0], viewSize: 240)
    s.rig.root.scale = SCNVector3(39, 39, 39)
    s.rig.facing.eulerAngles.y = 0.5
    var pose = DuckPose()
    pose.billOpen = 0.17
    pose.headPitch = 0.08
    pose.headRoll = -0.08
    s.rig.apply(pose: pose, grounded: true)
    s.rig.showHeadOnly()
    // Center the head in frame (a touch high, leaving room for the open bill).
    let c = s.rig.headCenter
    s.rig.root.position = SCNVector3(-c.x, -c.y + 2, -c.z)
    guard let duck = DuckRenderer(scene: s.scene, camera: s.cameraNode).image(pixels: Int(size)) else { exit(1) }

    let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        // macOS icon grid: an 824pt rounded square centered in the 1024 canvas, with a soft drop shadow.
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.hex(0xF7F3EC).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: .hex(0xFBF8F3), ending: .hex(0xEFE7DA))!.draw(in: body, angle: -90)
        // Dot pattern that fades toward the bottom, like the reference photo's backdrop.
        for row in 0..<22 {
            for col in 0..<22 {
                let x = body.minX + 22 + CGFloat(col) * 38 + (row % 2 == 0 ? 0 : 19)
                let y = body.minY + 22 + CGFloat(row) * 38
                let a = 0.05 + 0.22 * (y - body.minY) / body.height
                NSColor.hex(0xF0A07A).withAlphaComponent(a).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)).fill()
            }
        }
        duck.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        // Thin inner highlight on the rim.
        NSColor(white: 1, alpha: 0.6).setStroke()
        let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
        rim.lineWidth = 3
        rim.stroke()
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    // Renders a sheet of poses/themes to a folder for previewing the model.
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (t, theme) in DuckTheme.all.enumerated() {
        let s = DuckScene(theme: DuckTheme.all[0], viewSize: 240)
        s.rig.apply(theme: theme)   // also checks live recoloring
        s.rig.root.scale = SCNVector3(27, 27, 27)
        s.rig.root.position.y = -42
        s.rig.facing.eulerAngles.y = [0.7, 0.3, -0.8, -0.35][t]
        var pose = DuckPose()
        if t == 3 { pose.billOpen = 0.45; pose.headPitch = 0.3 }
        s.rig.apply(pose: pose, grounded: true)
        s.rig.shadow.position = SCNVector3(0, -42 - 27 * DuckRig.centerHeight, 0)
        s.rig.shadow.scale = SCNVector3(27, 27, 27)
        s.snapshot(to: dir.appendingPathComponent("theme\(t).png"))
    }
    let poses: [(String, (inout DuckPose) -> Void)] = [
        ("sit", { $0.left = .init(thigh: 1.45, knee: 2.5); $0.right = .init(thigh: 1.45, knee: 2.5); $0.neckLean = 0.5; $0.headPitch = -0.4 }),
        ("crouch", { $0.left = .init(thigh: 0.8, knee: 1.5); $0.right = .init(thigh: 0.8, knee: 1.5) }),
        ("walk", { $0.left = .init(thigh: 0.75, knee: 1.2); $0.right = .init(thigh: -0.05, knee: 0.55); $0.pelvisRoll = 0.08 }),
    ]
    for (name, f) in poses {
        let s = DuckScene(theme: DuckTheme.all[0], viewSize: 240)
        s.rig.root.scale = SCNVector3(27, 27, 27)
        s.rig.root.position.y = -42
        s.rig.facing.eulerAngles.y = 0.75
        var pose = DuckPose(); f(&pose)
        s.rig.apply(pose: pose, grounded: true)
        s.snapshot(to: dir.appendingPathComponent("pose-\(name).png"))
    }
    exit(0)
}

signal(SIGPIPE, SIG_IGN)   // the icon mover writes to a pipe that may close first

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
