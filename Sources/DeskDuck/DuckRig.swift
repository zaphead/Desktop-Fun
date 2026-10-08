import AppKit
import SceneKit

/// Color scheme for the duck, taken from the four reference robots.
struct DuckTheme {
    let name: String
    let shell: NSColor
    let face: NSColor
    let bill: NSColor
    let billAccent: NSColor
    let eyeRing: NSColor
    let shoe: NSColor
    let sole: NSColor

    static let all: [DuckTheme] = [
        DuckTheme(name: "Sky",
                  shell: .hex(0x86CDE0), face: .hex(0xB4B6B8), bill: .hex(0xF0632A), billAccent: .hex(0xF7A21C),
                  eyeRing: .hex(0xF6A41C), shoe: .hex(0xF0632A), sole: .hex(0xF7B21E)),
        DuckTheme(name: "Charcoal",
                  shell: .hex(0x58595D), face: .hex(0xBABCBF), bill: .hex(0xF4CF2E), billAccent: .hex(0xE8B820),
                  eyeRing: .hex(0x8C69D6), shoe: .hex(0xF4CF2E), sole: .hex(0x9A7DD8)),
        DuckTheme(name: "Cream",
                  shell: .hex(0xECE6DD), face: .hex(0xC6C3BE), bill: .hex(0xF0612B), billAccent: .hex(0xF59A1F),
                  eyeRing: .hex(0xF6A21B), shoe: .hex(0xF6A21B), sole: .hex(0xF0752A)),
        DuckTheme(name: "Lavender",
                  shell: .hex(0xB29BDB), face: .hex(0xC2C2C7), bill: .hex(0xF4CF2E), billAccent: .hex(0xE8B820),
                  eyeRing: .hex(0x8BD2E8), shoe: .hex(0xF4CF2E), sole: .hex(0xA387D9)),
    ]
}

extension NSColor {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// A full pose for the duck. Everything the animator controls lives here, so poses can be blended.
struct DuckPose {
    struct Leg { var thigh: CGFloat = 0.35; var knee: CGFloat = 0.75; var foot: CGFloat = 0 }
    var left = Leg()
    var right = Leg()
    var pelvisRoll: CGFloat = 0
    var pelvisPitch: CGFloat = 0
    var neckLean: CGFloat = 0.25      // forward lean of the lower neck
    var neckBend: CGFloat = -0.15     // bend at the middle neck joint
    var headYaw: CGFloat = 0
    var headPitch: CGFloat = 0        // positive looks up
    var headRoll: CGFloat = 0
    var billOpen: CGFloat = 0
    var iris: CGFloat = 1             // camera aperture scale
    var sitting: CGFloat = 0          // lets the body rest on the ground
}

/// Builds the robot duck out of SceneKit primitives and applies poses to it.
/// Model space: y up, +z forward, roughly 10 units tall.
final class DuckRig {
    let root = SCNNode()          // origin = body center, rotated for screen-plane flips
    let facing = SCNNode()        // yaw toward walking direction
    private let pelvis = SCNNode()
    private let neckBase = SCNNode()
    private let neckMid = SCNNode()
    private let head = SCNNode()
    private let jaw = SCNNode()
    private var lenses: [SCNNode] = []
    private var legs: [(hip: SCNNode, knee: SCNNode, ankle: SCNNode, flame: SCNNode)] = []
    private var themed: [(SCNMaterial, KeyPath<DuckTheme, NSColor>)] = []
    let shadow = SCNNode()
    private var staticGroups: [SCNNode] = []

    /// Distance from body center down to the soles when standing, in model units.
    static let centerHeight: CGFloat = 2.9
    static let thighLen: CGFloat = 1.05
    static let shinLen: CGFloat = 0.95
    static let footDrop: CGFloat = 0.75
    static let hipY: CGFloat = -0.3

    init(theme: DuckTheme) {
        root.addChildNode(facing)
        facing.addChildNode(pelvis)
        buildBody()
        buildNeckAndHead()
        for side in [-1.0, 1.0] { buildLeg(side: CGFloat(side)) }
        buildShadow()
        flattenStatic()
        apply(theme: theme)
        apply(pose: DuckPose(), grounded: true)
    }

    // MARK: Materials

    private func plastic(_ key: KeyPath<DuckTheme, NSColor>, rough: CGFloat = 0.5) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.roughness.contents = rough
        m.metalness.contents = 0.0
        themed.append((m, key))
        return m
    }

    private static func fixed(_ c: NSColor, rough: CGFloat, metal: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = rough
        m.metalness.contents = metal
        return m
    }

    private let black = DuckRig.fixed(.hex(0x1D1D20), rough: 0.42)
    private let darkGray = DuckRig.fixed(.hex(0x2E2F33), rough: 0.6)
    private let metal = DuckRig.fixed(.hex(0xB8BABD), rough: 0.32, metal: 0.85)
    private let lensGlass = DuckRig.fixed(.hex(0x0B0B0E), rough: 0.08, metal: 0.2)

    func apply(theme: DuckTheme) {
        for (m, key) in themed { m.diffuse.contents = theme[keyPath: key] }
    }

    // MARK: Geometry helpers

    /// Rigid parts attached to a joint go in one group, which is merged into a single mesh after building.
    /// ~150 primitives become ~12 meshes, which keeps SceneKit's per-frame cost tiny.
    private func geo(_ joint: SCNNode) -> SCNNode {
        if let g = joint.childNode(withName: "geo", recursively: false) { return g }
        let g = SCNNode()
        g.name = "geo"
        joint.addChildNode(g)
        staticGroups.append(g)
        return g
    }

    private func flattenStatic() {
        for g in staticGroups {
            let flat = g.flattenedClone()
            flat.name = "geo"
            g.parent?.replaceChildNode(g, with: flat)
        }
        staticGroups = []
    }

    @discardableResult
    private func box(_ parent: SCNNode, _ w: CGFloat, _ h: CGFloat, _ l: CGFloat, r: CGFloat,
                     at p: SCNVector3, _ mat: SCNMaterial) -> SCNNode {
        let g = SCNBox(width: w, height: h, length: l, chamferRadius: min(r, min(w, h, l) / 2))
        g.chamferSegmentCount = 4
        g.materials = [mat]
        let n = SCNNode(geometry: g)
        n.position = p
        parent.addChildNode(n)
        return n
    }

    @discardableResult
    private func disc(_ parent: SCNNode, radius: CGFloat, height: CGFloat, axis: String,
                      at p: SCNVector3, _ mat: SCNMaterial) -> SCNNode {
        let g = SCNCylinder(radius: radius, height: height)
        g.radialSegmentCount = 24
        g.materials = [mat]
        let n = SCNNode(geometry: g)
        n.position = p
        if axis == "x" { n.eulerAngles.z = .pi / 2 } else if axis == "z" { n.eulerAngles.x = .pi / 2 }
        parent.addChildNode(n)
        return n
    }

    /// Rounded-corner extruded polygon lying in the y-z plane (normal along x).
    /// Points are (z, y) pairs.
    private func plate(_ parent: SCNNode, _ pts: [CGPoint], corner: CGFloat, depth: CGFloat,
                       at p: SCNVector3, _ mat: SCNMaterial) -> SCNNode {
        let path = NSBezierPath()
        let n = pts.count
        let start = CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2)
        path.move(to: start)
        for i in 0..<n { path.appendArc(from: pts[i], to: pts[(i + 1) % n], radius: corner) }
        path.close()
        path.flatness = 0.01
        let g = SCNShape(path: path, extrusionDepth: depth)
        g.chamferRadius = depth * 0.35
        g.materials = [mat]
        let node = SCNNode(geometry: g)
        node.eulerAngles.y = -.pi / 2   // path x -> model +z
        node.position = p
        parent.addChildNode(node)
        return node
    }

    // MARK: Parts
    // Chibi proportions: big hooded head, short servo neck, chunky body, short legs, big shoes.

    private func buildBody() {
        let shell = plastic(\.shell)
        let g = geo(pelvis)
        // Main body shell
        box(g, 2.4, 1.4, 2.15, r: 0.55, at: SCNVector3(0, 0.62, -0.15), shell)
        // Black hip servo block under the body
        box(g, 2.0, 0.55, 0.95, r: 0.1, at: SCNVector3(0, -0.12, 0), black)
        for s in [-1.0, 1.0] {
            let x = CGFloat(s)
            disc(g, radius: 0.24, height: 0.1, axis: "x", at: SCNVector3(x * 1.02, -0.12, 0.05), metal)
            // Little bracket with holes near the neck, like the reference
            box(g, 0.14, 0.6, 0.62, r: 0.06, at: SCNVector3(x * 1.2, 0.8, 0.5), shell)
            for (dy, dz) in [(0.14, -0.12), (-0.1, 0.04), (0.1, 0.18)] {
                disc(g, radius: 0.06, height: 0.04, axis: "x",
                     at: SCNVector3(x * 1.27, 0.8 + CGFloat(dy), 0.5 + CGFloat(dz)), darkGray)
            }
        }
    }

    private func neckSegment(_ parent: SCNNode) {
        box(parent, 0.62, 0.78, 0.7, r: 0.08, at: SCNVector3(0, 0.38, 0), black)
        box(parent, 0.44, 0.18, 0.76, r: 0.04, at: SCNVector3(0, 0.62, 0), darkGray)
        for s in [-1.0, 1.0] {
            disc(parent, radius: 0.2, height: 0.08, axis: "x", at: SCNVector3(CGFloat(s) * 0.35, 0.2, 0.04), metal)
        }
    }

    private func buildNeckAndHead() {
        neckBase.position = SCNVector3(0, 1.2, 0.45)
        pelvis.addChildNode(neckBase)
        neckSegment(geo(neckBase))
        neckMid.position = SCNVector3(0, 0.7, 0)
        neckBase.addChildNode(neckMid)
        neckSegment(geo(neckMid))
        head.position = SCNVector3(0, 0.72, 0)
        neckMid.addChildNode(head)

        let g = geo(head)
        let shell = plastic(\.shell, rough: 0.45)
        let face = plastic(\.face, rough: 0.6)
        let bill = plastic(\.bill, rough: 0.5)
        let billAccent = plastic(\.billAccent, rough: 0.5)
        let ring = plastic(\.eyeRing, rough: 0.4)

        // neck-to-head servo
        box(g, 0.72, 0.42, 0.7, r: 0.1, at: SCNVector3(0, 0.12, -0.15), black)

        // Hood: a rounded shell over the top, sides and back, open at the front.
        box(g, 2.7, 2.1, 2.6, r: 1.02, at: SCNVector3(0, 1.32, -0.3), shell)
        // Rim around the face opening (top lip and two sides), sticking out past the face.
        box(g, 2.3, 0.4, 0.62, r: 0.2, at: SCNVector3(0, 2.13, 0.92), shell)
        for s in [-1.0, 1.0] {
            box(g, 0.34, 1.55, 0.62, r: 0.17, at: SCNVector3(CGFloat(s) * 1.18, 1.25, 0.92), shell)
        }
        // Recessed gray face plate
        box(g, 2.25, 1.65, 0.5, r: 0.25, at: SCNVector3(0, 1.3, 0.85), face)

        // One big camera eye, a little left of center, with a sensor slot beside it
        disc(g, radius: 0.62, height: 0.36, axis: "z", at: SCNVector3(-0.28, 1.36, 1.15), ring)
        disc(g, radius: 0.41, height: 0.36, axis: "z", at: SCNVector3(-0.28, 1.36, 1.17), darkGray)
        let lens = SCNNode()
        lens.position = SCNVector3(-0.28, 1.36, 1.34)
        head.addChildNode(lens)
        let glass = SCNNode(geometry: SCNSphere(radius: 0.35))
        glass.geometry?.firstMaterial = lensGlass
        glass.scale = SCNVector3(1, 1, 0.35)
        lens.addChildNode(glass)
        let glint = SCNNode(geometry: SCNSphere(radius: 0.075))
        glint.geometry?.firstMaterial = DuckRig.fixed(.white, rough: 0.2)
        glint.geometry?.firstMaterial?.emission.contents = NSColor(white: 0.85, alpha: 1)
        glint.position = SCNVector3(0.1, 0.11, 0.09)
        lens.addChildNode(glint)
        lenses.append(lens)
        box(g, 0.34, 0.13, 0.1, r: 0.06, at: SCNVector3(0.62, 1.36, 1.12), darkGray)

        // Bill: the bottom lip of the face opening, wide and flat, poking out the front
        box(g, 2.75, 0.26, 1.25, r: 0.12, at: SCNVector3(0, 0.4, 0.95), bill)
        box(g, 2.55, 0.08, 1.1, r: 0.04, at: SCNVector3(0, 0.26, 1.0), billAccent)
        // Lower bill hinges at the back so the mouth can open
        jaw.position = SCNVector3(0, 0.25, -0.15)
        head.addChildNode(jaw)
        box(geo(jaw), 2.6, 0.22, 1.75, r: 0.1, at: SCNVector3(0, -0.12, 0.98), bill)
        // Hinge brackets on the sides
        for s in [-1.0, 1.0] {
            let x = CGFloat(s)
            box(g, 0.1, 0.42, 0.42, r: 0.05, at: SCNVector3(x * 1.38, 0.36, 0.15), bill)
            disc(g, radius: 0.08, height: 0.04, axis: "x", at: SCNVector3(x * 1.44, 0.44, 0.1), darkGray)
            disc(g, radius: 0.08, height: 0.04, axis: "x", at: SCNVector3(x * 1.44, 0.28, 0.22), darkGray)
        }
    }

    private func buildLeg(side: CGFloat) {
        let shell = plastic(\.shell)
        let shoe = plastic(\.shoe, rough: 0.5)
        let sole = plastic(\.sole, rough: 0.6)
        let T = DuckRig.thighLen, S = DuckRig.shinLen

        let hip = SCNNode()
        hip.position = SCNVector3(side * 0.78, DuckRig.hipY, 0)
        pelvis.addChildNode(hip)
        let hg = geo(hip)
        // Hip servo + thigh strut
        box(hg, 0.56, 0.62, 0.78, r: 0.1, at: SCNVector3(0, -0.1, 0), black)
        disc(hg, radius: 0.24, height: 0.1, axis: "x", at: SCNVector3(side * 0.31, -0.1, 0), metal)
        box(hg, 0.4, T, 0.42, r: 0.08, at: SCNVector3(0, -T / 2, 0), black)
        // Triangular thigh plate on the outside
        _ = plate(hg, [CGPoint(x: 0.6, y: 0.28), CGPoint(x: -0.75, y: 0.2), CGPoint(x: 0.1, y: -1.05)],
                  corner: 0.26, depth: 0.18, at: SCNVector3(side * 0.38 - 0.09, -0.15, 0), shell)

        let knee = SCNNode()
        knee.position = SCNVector3(0, -T, 0)
        hip.addChildNode(knee)
        let kg = geo(knee)
        box(kg, 0.52, 0.5, 0.58, r: 0.1, at: SCNVector3(0, 0, 0), black)
        disc(kg, radius: 0.17, height: 0.08, axis: "x", at: SCNVector3(side * 0.27, 0, 0), metal)
        box(kg, 0.18, S, 0.18, r: 0.05, at: SCNVector3(side * 0.11, -S / 2, 0.1), metal)
        box(kg, 0.38, S * 0.7, 0.4, r: 0.07, at: SCNVector3(-side * 0.04, -S * 0.45, -0.1), black)

        let ankle = SCNNode()
        ankle.position = SCNVector3(0, -S, 0)
        knee.addChildNode(ankle)
        let ag = geo(ankle)
        box(ag, 0.5, 0.42, 0.52, r: 0.1, at: SCNVector3(0, 0, -0.05), black)
        // Chunky two-tone shoe
        box(ag, 1.0, 0.44, 1.5, r: 0.21, at: SCNVector3(side * 0.05, -0.36, 0.22), shoe)
        box(ag, 1.05, 0.26, 1.62, r: 0.12, at: SCNVector3(side * 0.05, -0.62, 0.24), sole)
        for (i, dz) in [-0.2, 0.05, 0.3].enumerated() {
            disc(ag, radius: 0.055, height: 0.04, axis: "x",
                 at: SCNVector3(side * 0.56, CGFloat(i % 2) * 0.1 - 0.4, CGFloat(dz)), darkGray)
        }

        // Rocket flame, hidden until a big jump
        let flame = SCNNode()
        flame.position = SCNVector3(side * 0.05, -0.75, 0.2)
        let outer = SCNCone(topRadius: 0.36, bottomRadius: 0.0, height: 1.2)
        let om = SCNMaterial(); om.lightingModel = .constant
        om.diffuse.contents = NSColor.hex(0xFF7A1A); om.transparency = 0.85
        outer.materials = [om]
        let on = SCNNode(geometry: outer); on.position.y = -0.6
        let inner = SCNCone(topRadius: 0.19, bottomRadius: 0.0, height: 0.7)
        let im = SCNMaterial(); im.lightingModel = .constant; im.diffuse.contents = NSColor.hex(0xFFE36B)
        inner.materials = [im]
        let inn = SCNNode(geometry: inner); inn.position.y = -0.36
        flame.addChildNode(on); flame.addChildNode(inn)
        flame.isHidden = true
        ankle.addChildNode(flame)

        legs.append((hip, knee, ankle, flame))
    }

    private func buildShadow() {
        let size = 64
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let g = NSGradient(colors: [NSColor(white: 0, alpha: 0.42), NSColor(white: 0, alpha: 0)])!
            g.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
        let plane = SCNPlane(width: 4.4, height: 2.2)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        plane.materials = [m]
        shadow.geometry = plane
        shadow.eulerAngles.x = -.pi / 2
        shadow.renderingOrder = -1
    }

    // MARK: Posing

    /// Lowest point of a leg's sole relative to the pelvis, using the same joint math SceneKit uses.
    private static func soleY(_ leg: DuckPose.Leg, pitch: CGFloat) -> CGFloat {
        let a1 = -leg.thigh - pitch
        let a2 = a1 + leg.knee
        let a3 = a2 + ankleAngle(leg)
        return hipY - thighLen * cos(a1) - shinLen * cos(a2) - footDrop * cos(a3)
    }

    private static func ankleAngle(_ leg: DuckPose.Leg) -> CGFloat { leg.thigh - leg.knee - leg.foot }

    /// Apply a pose. When grounded, the pelvis height is solved so the lowest sole sits on the floor.
    func apply(pose p: DuckPose, grounded: Bool) {
        for (i, legPose) in [p.left, p.right].enumerated() {
            let l = legs[i]
            l.hip.eulerAngles.x = -legPose.thigh
            l.knee.eulerAngles.x = legPose.knee
            l.ankle.eulerAngles.x = DuckRig.ankleAngle(legPose)
        }
        pelvis.eulerAngles = SCNVector3(-p.pelvisPitch, 0, p.pelvisRoll)
        neckBase.eulerAngles.x = -p.neckLean
        neckMid.eulerAngles.x = -p.neckBend
        head.eulerAngles = SCNVector3(p.neckLean + p.neckBend - p.headPitch + p.pelvisPitch, p.headYaw, p.headRoll)
        jaw.eulerAngles.x = p.billOpen
        for lens in lenses { lens.scale = p.iris < 0.3 ? SCNVector3(1.1, p.iris, 1) : SCNVector3(p.iris, p.iris, 1) }

        var low = min(DuckRig.soleY(p.left, pitch: p.pelvisPitch), DuckRig.soleY(p.right, pitch: p.pelvisPitch))
        low = min(low, -0.5)   // the hip block rests on the ground when the legs fold up
        let standing = DuckRig.soleY(DuckPose.Leg(), pitch: 0)
        let y = grounded ? (-DuckRig.centerHeight - low) : (-DuckRig.centerHeight - standing)
        pelvis.position = SCNVector3(0, y, 0)
    }

    func setFlames(_ on: Bool, flicker: CGFloat) {
        for l in legs {
            l.flame.isHidden = !on
            l.flame.scale = SCNVector3(1, 0.8 + flicker * 0.5, 1)
        }
    }
}
