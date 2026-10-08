import AppKit
import Metal
import QuartzCore
import SceneKit

/// Small transparent, click-through panel that follows the duck around. It floats above everything
/// (including the menu bar) on every Space, and never steals focus.
final class DuckPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Let the duck hang off screen edges and into the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Draws the SceneKit scene into a transparent CAMetalLayer, only when asked.
/// Driving SCNRenderer ourselves (instead of SCNView) skips SceneKit's own display link and
/// render thread, which was most of the app's CPU use.
final class DuckRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    let renderer: SCNRenderer
    private var msaa: MTLTexture?
    private var depth: MTLTexture?
    static let samples = 4

    init(scene: SCNScene, camera: SCNNode) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
    }

    /// Renders into `target` (resolving MSAA into it). Returns the command buffer so callers can present or wait.
    @discardableResult
    func render(into target: MTLTexture, time: CFTimeInterval, then: ((MTLCommandBuffer) -> Void)? = nil) -> MTLCommandBuffer? {
        let w = target.width, h = target.height
        if msaa?.width != w || msaa?.height != h {
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat, width: w, height: h, mipmapped: false)
            cd.textureType = .type2DMultisample
            cd.sampleCount = DuckRenderer.samples
            cd.usage = .renderTarget
            cd.storageMode = .private
            msaa = device.makeTexture(descriptor: cd)
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            dd.textureType = .type2DMultisample
            dd.sampleCount = DuckRenderer.samples
            dd.usage = .renderTarget
            dd.storageMode = .private
            depth = device.makeTexture(descriptor: dd)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let cb = queue.makeCommandBuffer() else { return nil }
        renderer.render(atTime: time, viewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: cb, passDescriptor: pass)
        then?(cb)
        cb.commit()
        return cb
    }

    /// Offscreen render to an image, for previews and debugging.
    func image(pixels: Int, time: CFTimeInterval = 0) -> NSImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: pixels, height: pixels, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let cb = render(into: tex, time: time) { cb in
            let blit = cb.makeBlitCommandEncoder()
            blit?.synchronize(resource: tex)
            blit?.endEncoding()
        }
        cb?.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        tex.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        // BGRA premultiplied -> CGImage
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &bytes, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                  space: cs, bitmapInfo: info.rawValue), let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: pixels, height: pixels))
    }
}

/// The view the duck is drawn in; forwards mouse input to the controller.
final class DuckView: NSView {
    weak var controller: DuckController?
    let duckRenderer: DuckRenderer
    private let metalLayer = CAMetalLayer()

    init(frame: NSRect, renderer: DuckRenderer) {
        duckRenderer = renderer
        super.init(frame: frame)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.backgroundColor = .clear
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func draw(time: CFTimeInterval) {
        guard metalLayer.drawableSize.width > 0, let drawable = metalLayer.nextDrawable() else { return }
        duckRenderer.render(into: drawable.texture, time: time) { $0.present(drawable) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp() }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = controller?.contextMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
