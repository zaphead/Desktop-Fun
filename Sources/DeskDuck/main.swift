import AppKit
import SceneKit

let args = CommandLine.arguments
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
