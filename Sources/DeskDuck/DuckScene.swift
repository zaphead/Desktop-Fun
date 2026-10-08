import AppKit
import SceneKit

/// The SceneKit scene the duck lives in: orthographic camera, studio-ish lighting, transparent background.
/// World units are screen points, so the duck's on-screen size is just `rig.root.scale`.
final class DuckScene {
    let scene = SCNScene()
    let rig: DuckRig
    let cameraNode = SCNNode()
    /// Width/height of the view in points; the duck's body center sits in the middle.
    let viewSize: CGFloat

    init(theme: DuckTheme, viewSize: CGFloat) {
        self.viewSize = viewSize
        rig = DuckRig(theme: theme)
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(rig.root)
        scene.rootNode.addChildNode(rig.shadow)

        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = Double(viewSize / 2)
        cam.zNear = 1
        cam.zFar = 4000
        cameraNode.camera = cam
        let elevation: CGFloat = 0.16
        cameraNode.position = SCNVector3(0, 1000 * sin(elevation), 1000 * cos(elevation))
        cameraNode.eulerAngles.x = -elevation
        scene.rootNode.addChildNode(cameraNode)

        scene.lightingEnvironment.contents = DuckScene.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.0

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.color = NSColor(white: 1, alpha: 1)
        let keyNode = SCNNode(); keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.85, -0.55, 0)
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 450
        rim.color = NSColor(calibratedRed: 0.85, green: 0.9, blue: 1, alpha: 1)
        let rimNode = SCNNode(); rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(-0.3, 2.6, 0)
        scene.rootNode.addChildNode(rimNode)
    }

    /// A soft gradient "studio" environment map for plastic-looking reflections.
    static func studioEnvironment() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 128), flipped: false) { r in
            let g = NSGradient(colorsAndLocations:
                (NSColor(white: 0.32, alpha: 1), 0.0),
                (NSColor(white: 0.55, alpha: 1), 0.45),
                (NSColor(white: 0.95, alpha: 1), 0.62),
                (NSColor(white: 1.0, alpha: 1), 1.0))!
            g.draw(in: r, angle: 90)
            NSColor(white: 1, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: 60, y: 92, width: 50, height: 22)).fill()
            return true
        }
    }

    /// Render a PNG offscreen through the same Metal path the app uses.
    func snapshot(to url: URL, pixels: Int = 600) {
        guard let img = DuckRenderer(scene: scene, camera: cameraNode).image(pixels: pixels),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
