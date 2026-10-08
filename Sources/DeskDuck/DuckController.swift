import AppKit
import SceneKit

/// The duck's brain and body: a small state machine on top of 2D platformer physics in screen space.
/// The 3D model is only how it's drawn; all movement happens in AppKit global coordinates.
final class DuckController: NSObject {
    // MARK: Collaborators
    let world: World
    let quacker = Quacker()
    let mover = IconMover()
    let scene: DuckScene
    let panel: DuckPanel
    let view: DuckView
    var link: CADisplayLink?
    var menuProvider: (() -> NSMenu)?

    // MARK: Settings
    let settings: DuckSettings
    let scanner = AXScanner()
    private(set) var sizeMul: CGFloat = 1
    var unit: CGFloat { 7.6 * sizeMul }                 // points per model unit
    var hc: CGFloat { DuckRig.centerHeight * unit }     // body center to soles
    var panelSize: CGFloat { 160 * sizeMul }
    let gravity: CGFloat = 1900

    // MARK: Body state
    enum State { case idle, walk, crouch, air, land, sit, hang, held, quack, surf, prank, hide, dance, innocent }
    var state: State = .air
    var stateT: Double = 0
    var stateDur: Double = 0
    var pos = CGPoint.zero          // body center
    var vel = CGVector.zero
    var groundID: String?
    var groundX0: CGFloat?
    var onCeiling = false
    var facing: CGFloat = 1
    var yawVis: CGFloat = 0
    var roll: CGFloat = 0
    var spin: CGFloat = 0
    var flip: (from: CGFloat, by: CGFloat, dur: Double)?
    var airT: Double = 0
    var rocket = false
    var ceilingTarget: Platform?
    var pendingLaunch: CGVector?
    var hardLanding = false
    var walkTarget: CGFloat = 0
    var walkOffEdge = false
    /// Height of the surface an aimed jump is going for; it falls through anything above that on the way.
    var jumpTargetY: CGFloat?
    var gait: Gait = .tiptoe

    /// Different ways of getting around. Speed is relative to the normal tiptoe; `cadence` scales step rate.
    enum Gait: CaseIterable {
        case tiptoe, waddle, strut, scurry, sneak, skip, moonwalk
        var speed: CGFloat {
            switch self {
            case .tiptoe: 1.0
            case .waddle: 0.8
            case .strut: 1.15
            case .scurry: 2.7
            case .sneak: 0.55
            case .skip: 1.45
            case .moonwalk: 0.75
            }
        }
        var cadence: CGFloat {
            switch self {
            case .tiptoe: 1.0
            case .waddle: 1.0
            case .strut: 0.55
            case .scurry: 0.9
            case .sneak: 0.6
            case .skip: 0.75
            case .moonwalk: 0.8
            }
        }
    }

    /// Pick a walk style for a stroll of a given length.
    func randomGait(distance: CGFloat) -> Gait {
        if onCeiling { return Double.random(in: 0...1) < 0.8 ? .tiptoe : .waddle }
        var options: [(Double, Gait)] = [(4, .tiptoe), (2, .waddle), (1.6, .strut), (1.1, .skip)]
        options.append((distance > 400 ? 3 : 0.8, .scurry))
        if distance > 120 { options.append((0.6, .moonwalk)) }
        var r = Double.random(in: 0..<options.reduce(0) { $0 + $1.0 })
        for (w, g) in options {
            r -= w
            if r < 0 { return g }
        }
        return .tiptoe
    }
    var goal: CGPoint?
    var goalSince: Double = 0
    var walkPhase: CGFloat = 0
    var asleep = false
    var zTimer: Double = 0

    // MARK: Animation state
    var pose = DuckPose()
    var time: Double = 0
    var lastTick: CFTimeInterval = 0
    var glance = CGPoint.zero
    var glanceTimer: Double = 0
    var blinkTimer: Double = 3
    var blinkT: Double = -1
    var billT: Double = -1

    // MARK: Input
    var mouse = CGPoint.zero
    var mouseIdle: Double = 0
    var hovering = false
    var pressed = false
    var pressPoint = CGPoint.zero
    var grabOffset = CGVector.zero
    var dragHistory: [(t: Double, p: CGPoint)] = []

    // MARK: Icon surfing
    struct Surf { let name: String; let from: CGPoint; let to: CGPoint; let dur: Double; let offsetX: CGFloat }
    var surf: Surf?
    var lastSurf: Double = -30
    var lastCeiling: Double = -30

    // MARK: Timers
    var windowRefresh: Double = 0
    var iconRefresh: Double = 0
    var contentScan: Double = 0
    var lastGround: Platform?

    // MARK: Mischief state (behavior lives in Mischief.swift)
    var prank: Prank?
    var pendingTry: Prank?
    var prankDeadline: Double = 0
    var lastMischief: Double = 0
    var guiltyUntil: Double = -1
    var heistJobs: [(name: String, dest: CGPoint)] = []
    var heistFinaleX: CGFloat?
    var heistAction: HeistAction = .none
    var carried: String?
    var carryFrom = CGPoint.zero
    var carryBlend: CGFloat = 0
    var toss: (name: String, from: CGPoint, to: CGPoint, t: Double)?
    var squatting = false
    var squatTarget: (id: String, x: CGFloat)?
    var cursorPhase: CursorPhase = .approach
    var cursorHeld = false
    var cursorWarp: CGPoint?
    var cursorGrabArmed = false
    var hideSpot: (platformID: String, y: CGFloat, edge: CGFloat, dir: CGFloat)?
    var hidePhase: HidePhase = .sneakIn
    var hideNext: Double = 0
    var bounceLeft = 0
    var bounceWindow: (num: Int, pid: pid_t, orig: CGRect)?
    var bounceTarget: String?
    var muddySteps = 0
    var lastStepIndex = 0
    var innocentWhistled = false
    let footprints = FootprintOverlay()
    var lastScan = "-"

    init(settings: DuckSettings) {
        self.settings = settings
        let theme = DuckTheme.all[settings.theme]
        let sizeMul = CGFloat(settings.size)
        self.sizeMul = sizeMul
        world = World()
        scene = DuckScene(theme: theme, viewSize: 160 * sizeMul)
        panel = DuckPanel(size: 160 * sizeMul)
        view = DuckView(frame: NSRect(x: 0, y: 0, width: 160 * sizeMul, height: 160 * sizeMul),
                        renderer: DuckRenderer(scene: scene.scene, camera: scene.cameraNode))
        super.init()
        view.controller = self
        panel.contentView = view
        applySize()

        scene.rig.shadow.categoryBitMask = 2
        world.refreshWindows()
        world.refreshIcons()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // A different app in front means a different window to explore.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appQuit(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        applySettings()
        // Debug builds of the experience: when the debug log is on, pranks can be triggered from the terminal.
        if debugPath != nil {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("cloud.sharpstack.deskduck.try"),
                                                                object: nil, queue: .main) { [weak self] n in
                guard let name = n.object as? String else { return }
                if name == "footprints" { self?.tryFootprints() }
                else if name == "putback" { self?.putEverythingBack() }
                else if let p = Prank(rawValue: name) { self?.tryPrank(p) }
            }
        }
        mouse = NSEvent.mouseLocation
        spawn(at: mouse)
    }

    func start() {
        panel.orderFrontRegardless()
        attachDisplayLink()
        lastTick = CACurrentMediaTime()
        // Watchdog: a view's display link can stall while its window hops between displays.
        // If frames stop arriving, step on a plain timer and re-attach the link.
        let w = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.watchdog() }
        RunLoop.main.add(w, forMode: .common)
    }

    func attachDisplayLink() {
        link?.invalidate()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    var stalledSince: CFTimeInterval?

    func watchdog() {
        guard panel.isVisible else { return }
        let now = CACurrentMediaTime()
        guard now - lastTick > 0.08 else { stalledSince = nil; return }
        if stalledSince == nil { stalledSince = now }
        step()
        if let since = stalledSince, now - since > 0.5 {
            attachDisplayLink()
            stalledSince = now
        }
    }

    var isHidden: Bool { !panel.isVisible }

    func setHidden(_ hide: Bool) {
        if hide {
            panel.orderOut(nil)
            link?.isPaused = true
            endSurf()
        } else {
            panel.orderFrontRegardless()
            lastTick = CACurrentMediaTime()
            link?.isPaused = false
        }
    }

    func setTheme(_ t: DuckTheme) { scene.rig.apply(theme: t) }

    /// Push the cheap-to-apply settings down to the parts that use them.
    func applySettings() {
        world.useIcons = settings.useIcons
        world.useWindowTops = settings.useWindowTops
        world.useAppContent = settings.useAppContent
        scanner.wakeWebContent = settings.wakeWebContent
        quacker.muted = settings.muted
        quacker.volumeScale = Float(settings.volume)
        if !settings.useAppContent { world.clearContent() }
        contentScan = 0
    }

    @objc private func appActivated() {
        world.clearContent()
        contentScan = 0.15
    }

    @objc private func appQuit(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            scanner.forget(pid: app.processIdentifier)
        }
    }

    func setSize(_ m: CGFloat) {
        sizeMul = m
        applySize()
        if let g = currentGround() { snap(to: g) }
    }

    func applySize() {
        panel.setContentSize(NSSize(width: panelSize, height: panelSize))
        view.frame = NSRect(x: 0, y: 0, width: panelSize, height: panelSize)
        scene.cameraNode.camera?.orthographicScale = Double(panelSize / 2)
        scene.rig.root.scale = SCNVector3(unit, unit, unit)
        scene.rig.shadow.scale = SCNVector3(unit, unit, unit)
        world.duckHeight = 8.2 * unit
    }

    @objc private func screensChanged() {
        world.refreshScreens()
        if !world.isInsideScreens(pos) { spawn(at: NSEvent.mouseLocation) }
    }

    func contextMenu() -> NSMenu? { menuProvider?() }

    // MARK: Public actions

    func summon() {
        endSurf()
        abortPrank()
        spawn(at: NSEvent.mouseLocation)
        quacker.play("quack")
    }

    func quackNow() {
        if state == .sit { wake() }
        if [.idle, .walk, .land, .hang].contains(state) { enter(.quack, dur: 0.55) }
        billT = 0
        quacker.play("quack")
    }

    func spawn(at p: CGPoint) {
        jumpTargetY = nil
        let screen = world.screen(containing: p) ?? world.screens.first ?? .zero
        pos = CGPoint(x: min(max(p.x, screen.minX + 40), screen.maxX - 40), y: screen.maxY - 50)
        vel = CGVector(dx: 0, dy: -100)
        onCeiling = false
        groundID = nil
        roll = 0
        flip = nil
        spin = 0
        enter(.air)
    }

    // MARK: Frame loop

    @objc private func tick(_ l: CADisplayLink) { step() }

    func step() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240), 1.0 / 20)
        lastTick = now
        time += dt

        let m = NSEvent.mouseLocation
        let ours = cursorWarp.map { hypot(m.x - $0.x, m.y - $0.y) < 12 } ?? false
        if hypot(m.x - mouse.x, m.y - mouse.y) > 1 && !ours { mouseIdle = 0 } else { mouseIdle += dt }
        mouse = m

        windowRefresh -= dt
        if windowRefresh <= 0 {
            world.refreshWindows()
            // Riding a window needs fresh positions; otherwise poll lazily (this call isn't free).
            // Standing on a window top: poll often so it can ride the window when you drag it.
            // Hanging under a maximized window: those rarely move, so poll gently.
            let riding = groundID?.hasPrefix("w:") == true && state != .sit
            let hangingOnWindow = groundID?.hasPrefix("c:w") == true
            windowRefresh = riding ? 1.0 / 15 : (state == .sit ? 2 : (state == .air ? 0.15 : (hangingOnWindow ? 0.3 : 0.4)))
        }
        iconRefresh -= dt
        if iconRefresh <= 0 && surf == nil {
            world.refreshIcons()
            iconRefresh = world.iconLookupFailed ? 60 : (state == .sit ? 8 : 4)
        }

        contentScan -= dt
        if contentScan <= 0 {
            scanContent()
        }

        // Stereo: pan sounds by where the duck is across the whole row of screens.
        if let minX = world.screens.map(\.minX).min(), let maxX = world.screens.map(\.maxX).max(), maxX > minX {
            quacker.pan = Float(((pos.x - minX) / (maxX - minX) * 2 - 1) * 0.9)
        }

        update(dt)
        mischiefFrame(dt)
        animate(dt)
        render()
        view.draw(time: time)
        updateHover()
        debugLog()
    }

    var debugT: Double = 0
    lazy var debugPath = UserDefaults.standard.string(forKey: "debugLog")

    /// `defaults write cloud.sharpstack.deskduck debugLog /path/to/file` to trace what the duck is doing.
    func debugLog() {
        guard let path = debugPath, time - debugT > 0.5 else { return }
        debugT = time
        let line = String(format: "%.1f %@ pos=(%.0f,%.0f) ground=%@ ceil=%d roll=%.2f icons=%d iconFail=%d winTops=%d content=%d ax=%d scan=%@ surf=%@ prank=%@ gait=%@ carried=%@ cursor=%d\n",
                          time, "\(state)", pos.x, pos.y, groundID ?? "-", onCeiling ? 1 : 0, roll,
                          world.icons.count, world.iconLookupFailed ? 1 : 0, world.windowTops.count,
                          world.contentPlatforms.count, AXScanner.isTrusted ? 1 : 0, lastScan, surf?.name ?? "-",
                          prank?.rawValue ?? "-", "\(gait)", carried ?? toss?.name ?? "-", cursorHeld ? 1 : 0)
        if Int(time * 2) % 16 == 0 {
            if let img = view.duckRenderer.image(pixels: 360, time: time), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path + "-\(state)-\(onCeiling ? "ceil" : "up").png"))
            }
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    // MARK: State machine

    func enter(_ s: State, dur: Double = 0) {
        state = s
        stateT = 0
        stateDur = dur
        if s != .sit { asleep = false }
    }

    func currentGround() -> Platform? {
        if let id = groundID, let p = world.platform(id: id) { return p }
        // The surface moved or was re-laid out (e.g. you scrolled): follow it if we can tell where it went.
        if let old = lastGround, groundID != nil, let p = world.replacement(for: old, near: pos.x, ceiling: onCeiling) {
            groundID = p.id
            groundX0 = p.x0
            return p
        }
        return nil
    }

    func scanContent() {
        guard settings.useAppContent, AXScanner.isTrusted, panel.isVisible else {
            contentScan = 2
            return
        }
        let onContent = groundID?.hasPrefix("a:") == true
        // Scanning costs the scanned app CPU too, so keep it gentle: more often only while standing on its contents.
        contentScan = onContent ? 0.7 : (state == .sit ? 6 : 2)
        scanner.scan { [weak self] result in
            guard let self, self.settings.useAppContent else { return }
            self.world.setContent(result)
            self.lastScan = result.map { "\($0.pid):\($0.rects.count)/\(Int($0.elapsed * 1000))ms" } ?? "none"
        }
    }

    func snap(to p: Platform) {
        pos.y = onCeiling ? p.y - hc : p.y + hc
    }

    func update(_ dt: Double) {
        stateT += dt
        switch state {
        case .held:
            updateHeld(dt)
            return
        case .air:
            updateAir(dt)
            return
        case .surf:
            updateSurf(dt)
            return
        case .hide:
            updateHide(dt)
            return
        default:
            break
        }

        // Every grounded state: stay attached to the platform, ride it if it moves, fall if it's gone.
        guard let g = currentGround(), pos.x >= g.x0 - 6, pos.x <= g.x1 + 6 else { return startFall() }
        if let x0 = groundX0, World.isWindowPlatform(g.id), abs(g.x0 - x0) < 200 { pos.x += g.x0 - x0 }
        groundX0 = g.x0
        lastGround = g
        snap(to: g)
        let rollTarget: CGFloat = onCeiling ? .pi : 0
        roll += (rollTarget - roll) * CGFloat(min(1, dt * 12))

        switch state {
        case .idle:
            if stateT >= stateDur { decide() }
        case .walk:
            // Big ducks lumber: speed grows slower than size, so strides get slow and heavy.
            let speed: CGFloat = (onCeiling ? 50 : 74) * sqrt(sizeMul) * CGFloat(settings.walkSpeed) * gait.speed
            let target = walkOffEdge ? walkTarget : min(max(walkTarget, g.x0 + 8), g.x1 - 8)
            let dx = target - pos.x
            if abs(dx) < 2 || stateT > 10 {
                enter(.idle, dur: prank != nil ? 0.1 : .random(in: 0.4...1.6))
            } else {
                let dir: CGFloat = dx > 0 ? 1 : -1
                facing = gait == .moonwalk ? -dir : dir     // moonwalking faces away from where it's going
                let step = min(abs(dx), speed * CGFloat(dt))
                pos.x += dir * step
                walkPhase += CGFloat(dt) * speed / (13 * sizeMul) * .pi * gait.cadence
            }
        case .crouch:
            if stateT >= stateDur, let v = pendingLaunch { launch(v) }
        case .land:
            if stateT >= stateDur {
                enter(.idle, dur: hardLanding ? 1.2 : (prank != nil ? 0.12 : .random(in: 0.3...1.2)))
                hardLanding = false
            }
        case .quack:
            if stateT >= stateDur { enter(onCeiling ? .hang : .idle, dur: .random(in: 0.5...1.5)) }
        case .prank:
            if stateT >= stateDur { prankActionDone() }
        case .dance, .innocent:
            if state == .innocent && stateT > 0.9 && !innocentWhistled { innocentWhistled = true; quacker.play("whistle", volume: 0.3) }
            if state == .dance { yawVis += CGFloat(dt) * (stateT < 1.1 ? 9 : 0) }
            if stateT >= stateDur { enter(.idle, dur: 0.6) }
        case .sit:
            if squatting { updateSquat(); break }
            if stateT > 1.2 && !asleep { asleep = true }
            if asleep {
                zTimer -= dt
                if zTimer <= 0 { spawnZ(); zTimer = 1.1 }
            }
            let near = hypot(mouse.x - pos.x, mouse.y - pos.y) < 90 * sizeMul && mouseIdle < 0.2
            if stateT >= stateDur || (near && stateT > 1) { wake() }
        case .hang:
            if stateT >= stateDur { decide() }
        default:
            break
        }
    }

    func wake() {
        asleep = false
        quacker.play("chirp")
        enter(.idle, dur: 0.8)
    }

    /// Pick what to do next, weighted by what's possible from here.
    func decide() {
        guard let g = currentGround() else { return startFall() }
        if prankStep(g) { return }
        if onCeiling {
            if Double.random(in: 0...1) < 0.6 && g.width > 90 {
                let x = min(max(pos.x + .random(in: -420...420), g.x0 + 20), g.x1 - 20)
                walk(to: x)
            } else if Double.random(in: 0...1) < 0.3 {
                enter(.hang, dur: .random(in: 1.5...3))
            } else {
                dropFromCeiling()
            }
            return
        }
        // Wandering: sometimes set off for somewhere far away, and keep heading there across decisions.
        if let gl = goal, hypot(gl.x - pos.x, gl.y - (pos.y - hc)) < 100 || time - goalSince > 45 { goal = nil }
        if goal == nil && Double.random(in: 0...1) < 0.1 + 0.6 * settings.wanderlust { pickGoal() }
        if let gl = goal, Double.random(in: 0...1) < 0.85 {
            if pursueGoal(from: g, to: gl) { return }
            goal = nil
        }

        if maybeStartMischief(g) { return }

        var options: [(Double, () -> Void)] = []
        let calm = 1.5 - settings.energy          // 1.5 (sleepy) ... 0.5 (hyper)
        options.append((1.2 * calm, { self.enter(.idle, dur: .random(in: 0.8...2.5) * calm) }))
        if g.width > 70 {
            options.append((3.0, {
                // Prefer a real stroll over a shuffle.
                var x = CGFloat.random(in: g.x0 + 12...g.x1 - 12)
                if abs(x - self.pos.x) < 120 { x = CGFloat.random(in: g.x0 + 12...g.x1 - 12) }
                self.walk(to: x)
            }))
        }
        let hops = jumpTargets(from: g, rocket: false)
        if !hops.isEmpty { options.append(((g.kind == .floor ? 6 : 4) * (0.2 + 1.6 * settings.jumpiness), { self.jump(to: hops.randomElement()!, rocket: false) })) }
        let far = jumpTargets(from: g, rocket: true)
        if !far.isEmpty { options.append(((g.kind == .floor ? 2.0 : 0.9) * 2 * settings.rockets, { self.jump(to: far.randomElement()!, rocket: true) })) }
        if settings.hanging > 0.02, time - lastCeiling > 45 - 35 * settings.hanging, let c = reachableCeiling() {
            options.append(((c.id.hasSuffix("notch") ? 1.4 : 1.1) * 2 * settings.hanging, { self.jumpToCeiling(c) }))
        }
        if settings.moveIcons, settings.useIcons, g.kind == .icon, time - lastSurf > 60 - 45 * settings.surfing, world.iconsAvailable {
            options.append((0.5 + 3 * settings.surfing, { self.startSurf(on: g) }))
        }
        options.append(((mouseIdle > 90 ? 5 : 0.7) * 2 * settings.naps, { self.enter(.sit, dur: .random(in: 6...16) * (0.5 + self.settings.naps)) }))
        options.append((0.5, { self.quackNow() }))
        let d = hypot(mouse.x - pos.x, mouse.y - pos.y)
        if d < 200 + 400 * settings.curiosity && mouseIdle < 3 && mouse.x > g.x0 && mouse.x < g.x1 {
            options.append((6.0 * settings.curiosity, { self.walk(to: self.mouse.x - self.facing * 20) }))
        }

        var r = Double.random(in: 0..<options.reduce(0) { $0 + $1.0 })
        for (w, act) in options {
            r -= w
            if r < 0 { return act() }
        }
        options.last?.1()
    }

    func walk(to x: CGFloat, offEdge: Bool = false, gait chosen: Gait? = nil) {
        walkTarget = x
        walkOffEdge = offEdge
        gait = chosen ?? randomGait(distance: abs(x - pos.x))
        if gait == .scurry && Double.random(in: 0...1) < 0.35 { quacker.play("beepbeep", volume: 0.25) }
        enter(.walk)
    }

    // MARK: Wandering

    /// Pick somewhere worth going, preferring far-away spots (other windows, other screens).
    func pickGoal() {
        let feet = pos.y - hc
        let spots = world.allStandable.filter { $0.width > 30 && hypot($0.midX - pos.x, $0.y - feet) > 350 }
        guard let p = spots.randomElement() ?? world.allStandable.randomElement() else { return }
        goal = CGPoint(x: .random(in: (p.x0 + 10)...max(p.x0 + 10, p.x1 - 10)), y: p.y)
        goalSince = time
    }

    /// Take one step toward the current goal. Returns false if there's no sensible move.
    func pursueGoal(from g: Platform, to gl: CGPoint) -> Bool {
        let feet = g.y
        func dist(_ x: CGFloat, _ y: CGFloat) -> CGFloat { hypot(gl.x - x, (gl.y - y) * 1.3) }
        let here = dist(pos.x, feet)
        // Already on the goal's platform: just walk there.
        if abs(gl.y - feet) < 2 && gl.x >= g.x0 - 1 && gl.x <= g.x1 + 1 {
            goal = nil
            walk(to: gl.x)
            return true
        }
        if let best = jumpTargets(from: g, rocket: false).min(by: { dist($0.1, $0.0.y) < dist($1.1, $1.0.y) }),
           dist(best.1, best.0.y) < here - 50 {
            jump(to: best, rocket: false)
            return true
        }
        // Goal is below: hop off the edge on that side.
        if gl.y < feet - 40 && g.kind != .floor && Double.random(in: 0...1) < 0.6 {
            walk(to: gl.x < pos.x ? g.x0 - 30 : g.x1 + 30, offEdge: true)
            return true
        }
        if let best = jumpTargets(from: g, rocket: true).min(by: { dist($0.1, $0.0.y) < dist($1.1, $1.0.y) }),
           dist(best.1, best.0.y) < here - 150 {
            jump(to: best, rocket: true)
            return true
        }
        // Walk toward the goal side of this platform to get a better angle.
        let edgeX = min(max(gl.x, g.x0 + 15), g.x1 - 15)
        if abs(edgeX - pos.x) > 40 {
            walk(to: edgeX)
            return true
        }
        return false
    }

    // MARK: Jumping

    func jumpTargets(from g: Platform, rocket: Bool) -> [(Platform, CGFloat)] {
        let reach = CGFloat(0.75 + 0.5 * settings.jumpiness)
        let feet = g.y
        var out: [(Platform, CGFloat)] = []
        for q in world.allStandable where q.id != g.id && q.width > 24 {
            let inset = min(16, q.width / 3)
            var tx = min(max(pos.x, q.x0 + inset), q.x1 - inset)
            tx += CGFloat.random(in: -1...1) * max(0, (q.width / 2 - inset) * 0.5)
            tx = min(max(tx, q.x0 + inset), q.x1 - inset)
            let dx = tx - pos.x, dy = q.y - feet
            guard world.isInsideScreens(CGPoint(x: tx, y: q.y + hc)) else { continue }
            if rocket {
                if hypot(dx, dy) > 300, abs(dx) < 1100, dy > -900, dy < 1000 { out.append((q, tx)) }
            } else {
                if abs(dx) < reach * 340 * sizeMul, dy > -480, dy < reach * 180 * sizeMul, abs(dx) + abs(dy) > 30 { out.append((q, tx)) }
            }
        }
        return out
    }

    func jump(to target: (Platform, CGFloat), rocket isRocket: Bool) {
        guard let g = currentGround() else { return }
        let dx = target.1 - pos.x, dy = target.0.y - g.y
        let h = max(dy, 0) + (isRocket ? 150 : 40 + 0.12 * abs(dx))
        let vy = sqrt(2 * gravity * h)
        let t = (vy + sqrt(max(0, vy * vy - 2 * gravity * dy))) / gravity
        let v = CGVector(dx: dx / t, dy: vy)
        facing = dx >= 0 ? 1 : -1
        rocket = isRocket
        ceilingTarget = nil
        jumpTargetY = target.0.y
        let flips = (isRocket ? 0.45 : (h > 100 ? 0.15 : 0)) > Double.random(in: 0...1)
        flip = flips ? (0, -facing * 2 * .pi, Double(t) * 0.75) : nil
        pendingLaunch = v
        enter(.crouch, dur: isRocket ? 0.4 : 0.17)
    }

    func reachableCeiling() -> Platform? {
        let options = world.ceilings.filter { c in
            let h = c.y - hc - pos.y
            let tx = min(max(pos.x, c.x0 + 20), c.x1 - 20)
            return h > 40 && h < 1400 && abs(tx - pos.x) < 450
                && world.isInsideScreens(CGPoint(x: tx, y: c.y - hc))
        }
        return options.first { $0.id.hasSuffix("notch") } ?? options.randomElement()
    }

    func jumpToCeiling(_ c: Platform) {
        let tx = min(max(pos.x + .random(in: -160...160), c.x0 + 20), c.x1 - 20)
        let h = (c.y - hc) - pos.y
        let vy = sqrt(2 * gravity * h)
        let t = vy / gravity
        facing = tx >= pos.x ? 1 : -1
        rocket = h > 240
        ceilingTarget = c
        jumpTargetY = nil
        flip = (0, -facing * .pi, Double(t) * 0.95)
        pendingLaunch = CGVector(dx: (tx - pos.x) / t, dy: vy)
        enter(.crouch, dur: rocket ? 0.4 : 0.2)
    }

    func launch(_ v: CGVector) {
        vel = v
        groundID = nil
        groundX0 = nil
        airT = 0
        spin = 0
        pendingLaunch = nil
        quacker.play(rocket ? "wee" : "boing", volume: rocket ? 0.3 : 0.18)
        enter(.air)
    }

    func startFall() {
        jumpTargetY = nil
        groundID = nil
        groundX0 = nil
        vel = state == .walk ? CGVector(dx: facing * 70 * sizeMul, dy: 60) : CGVector(dx: vel.dx * 0.3, dy: 0)
        airT = 0
        rocket = false
        ceilingTarget = nil
        if onCeiling {
            onCeiling = false
            flip = (roll, facing * .pi, 0.45)
        }
        enter(.air)
    }

    func dropFromCeiling() {
        jumpTargetY = nil
        onCeiling = false
        groundID = nil
        groundX0 = nil
        vel = CGVector(dx: facing * 40, dy: -40)
        airT = 0
        rocket = false
        ceilingTarget = nil
        flip = (roll, facing * .pi, 0.5)
        quacker.play("wee", volume: 0.22)
        enter(.air)
    }

    func updateAir(_ dt: Double) {
        airT += dt
        let prev = pos
        vel.dy -= gravity * CGFloat(dt)
        pos.x += vel.dx * CGFloat(dt)
        pos.y += vel.dy * CGFloat(dt)

        // Screen edges act as walls.
        if !world.isInsideScreens(CGPoint(x: pos.x, y: min(max(pos.y, prev.y), pos.y))) &&
            world.isInsideScreens(CGPoint(x: prev.x, y: pos.y)) {
            pos.x = prev.x
            vel.dx *= -0.35
            spin *= 0.5
            quacker.play("bonk", volume: 0.15)
        }

        if let f = flip {
            roll = f.from + f.by * CGFloat(min(1, airT / max(f.dur, 0.01)))
        } else {
            roll += spin * CGFloat(dt)
        }

        // Grab the ceiling at the top of a ceiling jump.
        if let c = ceilingTarget, vel.dy <= 0 {
            if pos.x >= c.x0 && pos.x <= c.x1 {
                onCeiling = true
                groundID = c.id
                groundX0 = nil
                roll = .pi
                flip = nil
                ceilingTarget = nil
                vel = .zero
                snap(to: c)
                lastCeiling = time
                quacker.play("chirp", volume: 0.25)
                enter(.hang, dur: .random(in: 2.5...6))
                return
            }
            ceilingTarget = nil
        }

        if vel.dy <= 0 {
            let feetPrev = prev.y - hc, feetNow = pos.y - hc
            let hits = world.allStandable.filter { p in
                pos.x >= p.x0 - 2 && pos.x <= p.x1 + 2 && feetPrev >= p.y - 1 && feetNow <= p.y
                    && p.y <= (jumpTargetY ?? .infinity) + 2
            }
            if let p = hits.max(by: { $0.y < $1.y }) {
                land(on: p)
                return
            }
        }

        // Lost? Put it back somewhere sensible.
        if airT > 6 || pos.y < (world.screens.map(\.minY).min() ?? 0) - 400 {
            spawn(at: NSEvent.mouseLocation)
        }
    }

    func land(on p: Platform) {
        jumpTargetY = nil
        let impact = -vel.dy
        let wasRocket = rocket
        groundID = p.id
        groundX0 = p.x0
        onCeiling = false
        snap(to: p)
        vel = .zero
        flip = nil
        spin = 0
        rocket = false
        roll = roll.remainder(dividingBy: 2 * .pi)
        hardLanding = impact > 1500 || abs(roll) > 1.2
        if hardLanding || sizeMul > 2.5 { quacker.play("bonk", volume: sizeMul > 2.5 ? 0.4 : 0.25) }   // giants stomp
        enter(.land, dur: hardLanding ? 0.5 : 0.16)
        didLand(on: p, impact: impact, wasRocket: wasRocket)
    }

    // MARK: Being picked up

    func mouseDown() {
        pressed = true
        pressPoint = NSEvent.mouseLocation
        dragHistory = [(time, pressPoint)]
    }

    func mouseDragged() {
        let m = NSEvent.mouseLocation
        if state != .held && hypot(m.x - pressPoint.x, m.y - pressPoint.y) > 4 {
            endSurf()
            abortPrank()
            grabOffset = CGVector(dx: pos.x - pressPoint.x, dy: pos.y - pressPoint.y)
            jumpTargetY = nil
            onCeiling = false
            groundID = nil
            flip = nil
            quacker.play("quack", volume: 0.3)
            enter(.held)
        }
        dragHistory.append((time, m))
        if dragHistory.count > 12 { dragHistory.removeFirst() }
    }

    func mouseUp() {
        pressed = false
        if state == .held {
            let recent = dragHistory.filter { time - $0.t < 0.1 }
            var v = CGVector.zero
            if let a = recent.first, let b = recent.last, b.t - a.t > 0.005 {
                v = CGVector(dx: (b.p.x - a.p.x) / (b.t - a.t), dy: (b.p.y - a.p.y) / (b.t - a.t))
            }
            let s = hypot(v.dx, v.dy)
            if s > 2600 { v.dx *= 2600 / s; v.dy *= 2600 / s }
            vel = v
            spin = max(-14, min(14, -v.dx / 220))
            airT = 0
            if s > 900 { quacker.play("wee", volume: 0.3) }
            enter(.air)
        } else {
            if state == .hide { return foundWhileHiding() }
            if squatting { return squatFlee() }
            // A simple click: quack, or a startled wake-up hop.
            if state == .sit { wake() }
            quackNow()
            if [.idle, .quack, .land].contains(state) && !onCeiling {
                flip = nil
                rocket = false
                ceilingTarget = nil
                pendingLaunch = CGVector(dx: 0, dy: 430)
                enter(.crouch, dur: 0.08)
            }
        }
    }

    func updateHeld(_ dt: Double) {
        let m = NSEvent.mouseLocation
        let target = CGPoint(x: m.x + grabOffset.dx, y: m.y + grabOffset.dy)
        let dx = target.x - pos.x
        pos = target
        roll += (max(-0.6, min(0.6, -dx * 0.05)) - roll) * CGFloat(min(1, dt * 10))
        if dragHistory.last.map({ time - $0.t > 0.05 }) ?? true {
            dragHistory.append((time, m))
            if dragHistory.count > 12 { dragHistory.removeFirst() }
        }
        if !pressed && NSEvent.pressedMouseButtons & 1 == 0 { mouseUp() }
    }

    // MARK: Icon surfing

    func startSurf(on g: Platform) {
        guard let name = g.iconName, let icon = world.icons.first(where: { $0.name == name }),
              let screen = NSScreen.screens.first?.visibleFrame else { return enter(.idle, dur: 1) }
        let others = world.icons.filter { $0.name != name }.map(\.center)
        var dest: CGPoint?
        for _ in 0..<24 {
            let a = CGFloat.random(in: 0...(2 * .pi)), d = CGFloat.random(in: 140...320)
            let c = CGPoint(x: icon.center.x + cos(a) * d, y: icon.center.y + sin(a) * d * 0.6)
            guard c.x > screen.minX + 60, c.x < screen.maxX - 60, c.y > screen.minY + 70, c.y < screen.maxY - 60,
                  !others.contains(where: { hypot($0.x - c.x, $0.y - c.y) < 100 }),
                  world.headroom(x: c.x, y: c.y + world.iconSize * 0.4) >= world.duckHeight,
                  !world.windowRects.contains(where: { $0.insetBy(dx: -40, dy: -40).contains(c) }) else { continue }
            dest = c
            break
        }
        guard let to = dest else { return enter(.idle, dur: 1) }
        lastSurf = time
        recordHome(name)
        world.lockedIcon = name
        mover.begin(iconName: name)
        let dist = hypot(to.x - icon.center.x, to.y - icon.center.y)
        surf = Surf(name: name, from: icon.center, to: to, dur: Double(min(2.4, max(1.1, dist / 170))),
                    offsetX: pos.x - icon.center.x)
        facing = to.x >= icon.center.x ? 1 : -1
        quacker.play("wee", volume: 0.3)
        enter(.surf)
    }

    func updateSurf(_ dt: Double) {
        guard let s = surf else { return enter(.idle, dur: 0.5) }
        let windup = 0.35
        let t = max(0, (stateT - windup) / s.dur)
        let e = CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
        let c = CGPoint(x: s.from.x + (s.to.x - s.from.x) * e, y: s.from.y + (s.to.y - s.from.y) * e)
        world.setIconCenter(s.name, c)
        if stateT > windup { mover.move(to: world.finderPoint(for: c)) }
        pos = CGPoint(x: c.x + s.offsetX, y: c.y + world.iconSize * 0.4 + hc)
        roll += (-facing * 0.12 * CGFloat(sin(.pi * t)) - roll) * CGFloat(min(1, dt * 8))
        if mover.failed || t >= 1 {
            mover.move(to: world.finderPoint(for: s.to))
            endSurf()
            groundID = "i:" + s.name
            groundX0 = nil
            enter(.land, dur: 0.3)
            billT = 0
            quacker.play("quack", volume: 0.3)
        }
    }

    func endSurf() {
        guard let s = surf else { return }
        surf = nil
        mover.end()
        // Give Finder a moment to report the new position before we trust it again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.world.lockedIcon == s.name { self?.world.lockedIcon = nil }
        }
    }

    // MARK: Animation

    func animate(_ dt: Double) {
        var p = DuckPose()
        let t = time

        // Eyes: blink, and focus the aperture when watching the cursor.
        blinkTimer -= dt
        if blinkTimer <= 0 { blinkT = 0; blinkTimer = .random(in: 2.5...6) }
        if blinkT >= 0 { blinkT += dt; if blinkT > 0.16 { blinkT = -1 } }

        switch state {
        case .idle, .hang, .quack, .hide:
            p.neckLean = 0.25 + 0.03 * CGFloat(sin(t * 2.1))
            p.left.thigh += 0.02 * CGFloat(sin(t * 2.1))
            p.right.thigh += 0.02 * CGFloat(sin(t * 2.1))
        case .walk:
            walkPose(&p, walkPhase)
        case .crouch:
            p.left = .init(thigh: 0.85, knee: 1.6)
            p.right = p.left
            p.neckLean = 0.45
            p.headPitch = 0.2
        case .land:
            let k = hardLanding ? 1.0 : 0.7
            p.left = .init(thigh: 0.35 + 0.5 * k, knee: 0.75 + 0.85 * k)
            p.right = p.left
            p.neckLean = 0.5
            if hardLanding { p.headRoll = 0.25 * CGFloat(sin(t * 9)); p.headPitch = -0.2 }
        case .air, .surf:
            if state == .surf {
                p.left = .init(thigh: 0.65, knee: 1.15, foot: 0)
                p.right = .init(thigh: 0.2, knee: 0.75)
                p.pelvisRoll = 0.12
                p.neckLean = 0.5
                p.billOpen = 0.3 + 0.08 * CGFloat(sin(t * 12))
            } else if vel.dy > 0 {
                p.left = .init(thigh: 0.75, knee: 1.35)
                p.right = .init(thigh: 0.55, knee: 1.2)
                p.neckLean = 0.15
                p.headPitch = 0.25
            } else {
                p.left = .init(thigh: 0.2, knee: 0.45, foot: -0.2)
                p.right = .init(thigh: 0.35, knee: 0.55, foot: -0.2)
                p.neckLean = 0.1
                p.headPitch = 0.1
                p.billOpen = spin != 0 ? 0.35 : 0
            }
        case .sit:
            p.left = .init(thigh: 1.45, knee: 2.5)
            p.right = p.left
            let doze = asleep ? 1.0 : 0.0
            p.neckLean = 0.55 + 0.1 * CGFloat(doze)
            p.neckBend = -0.15 - 0.2 * CGFloat(doze)
            p.headPitch = -0.45 * CGFloat(doze) + 0.03 * CGFloat(sin(t * 1.3))
            p.iris = asleep ? 0.12 : 1
            if squatting { p.iris = 0.62; p.headPitch = 0.22; p.neckLean = 0.35; p.neckBend = -0.1 }
        case .prank:
            p.left = .init(thigh: 0.8, knee: 1.5)
            p.right = p.left
            p.neckLean = 0.75
            p.headPitch = -0.45
            p.billOpen = 0.5
        case .dance:
            let k = CGFloat(t * 13)
            p.left = .init(thigh: 0.4 + 0.45 * max(0, sin(k)), knee: 0.8 + 0.8 * max(0, sin(k)))
            p.right = .init(thigh: 0.4 + 0.45 * max(0, sin(k + .pi)), knee: 0.8 + 0.8 * max(0, sin(k + .pi)))
            p.pelvisRoll = 0.12 * sin(k)
            p.headRoll = 0.25 * sin(k / 2)
            p.headPitch = 0.35
            p.billOpen = 0.35 + 0.2 * sin(k * 1.5)
        case .innocent:
            p.neckLean = 0.2
            p.headPitch = 0.12
            p.iris = stateT > 0.6 ? 1.15 : 1
        case .held:
            let k = CGFloat(t * 11)
            p.left = .init(thigh: 0.15 + 0.45 * sin(k), knee: 0.35 + 0.4 * max(0, sin(k + 1)))
            p.right = .init(thigh: 0.15 + 0.45 * sin(k + .pi), knee: 0.35 + 0.4 * max(0, sin(k + .pi + 1)))
            p.neckLean = 0.1
            p.billOpen = 0.25 + 0.2 * max(0, sin(CGFloat(t * 16)))
            p.headPitch = 0.3
        }

        // Head tracking: the cursor when it's nearby and active, otherwise idle glances.
        if state != .sit || !asleep {
            let headPos = CGPoint(x: pos.x + facing * 10 * sizeMul, y: pos.y + (onCeiling ? -30 : 30) * sizeMul)
            glanceTimer -= dt
            if glanceTimer <= 0 {
                glance = CGPoint(x: pos.x + .random(in: -300...300), y: pos.y + .random(in: -120...200))
                if Double.random(in: 0...1) < 0.3 { glance = CGPoint(x: headPos.x, y: headPos.y + 10) }  // look at you
                glanceTimer = .random(in: 1.5...4)
            }
            let watching = settings.curiosity > 0.02 && hypot(mouse.x - pos.x, mouse.y - pos.y) < 220 + 600 * settings.curiosity && mouseIdle < 4
            let look = watching ? mouse : glance
            let s: CGFloat = cos(roll) >= 0 ? 1 : -1
            let dx = look.x - headPos.x, dy = look.y - headPos.y
            let worldYaw = s * 1.25 * tanh(dx / 160)
            p.headYaw = max(-1.2, min(1.2, worldYaw - yawVis))
            p.headPitch += s * 0.6 * tanh(dy / 200)
            if watching && mouseIdle > 0.6 { p.iris = 0.82 + 0.05 * CGFloat(sin(t * 3)) }
        }
        // Caught red-handed: freeze, slowly look right at you, then shifty glances while whistling.
        if state == .innocent {
            let u = stateT
            let atYou = -yawVis
            p.headYaw = u < 0.6 ? pose.headYaw : (u < 1.4 ? atYou * CGFloat(min(1, (u - 0.6) / 0.8)) : atYou + 0.5 * (sin(t * 3.2) > 0 ? 1 : -1))
            p.headPitch = u < 1.4 ? 0.1 : 0.25
        }
        if carried != nil || cursorHeld { p.billOpen = max(p.billOpen, 0.32) }
        if blinkT >= 0 && !asleep && state != .innocent { p.iris = 0.1 }
        if billT >= 0 {
            billT += dt
            p.billOpen = max(p.billOpen, 0.5 * CGFloat(sin(min(1, billT / 0.18) * .pi)) +
                             (billT > 0.2 ? 0.4 * CGFloat(sin(min(1, (billT - 0.2) / 0.15) * .pi)) : 0))
            if billT > 0.4 { billT = -1 }
        }

        // Smoothly blend toward the target pose.
        let k = CGFloat(min(1, dt * (state == .walk ? (gait == .scurry ? 40 : 22) : 13)))
        pose = DuckPose.mix(pose, p, k)
        if state == .walk && gait == .scurry { pose.left = p.left; pose.right = p.right }   // wheel legs wrap around

        // Body yaw: 3/4 view toward the travel direction, more frontal when standing around.
        let frontal = [.idle, .sit, .quack, .hang, .hide].contains(state)
        let s: CGFloat = cos(roll) >= 0 ? 1 : -1
        let side: CGFloat = state == .walk && gait == .scurry ? 1.2 : 0.85
        let yawTarget = state == .innocent ? 0 : s * facing * (frontal ? 0.4 : side)
        if state == .dance && stateT < 1.1 { return }   // spinning: yaw is driven directly
        if state == .dance { yawVis = yawVis.remainder(dividingBy: 2 * .pi) }
        yawVis += (yawTarget - yawVis) * CGFloat(min(1, dt * (state == .innocent ? 3 : 7)))
    }

    /// Leg and body motion for each walk style.
    func walkPose(_ p: inout DuckPose, _ ph: CGFloat) {
        switch gait {
        case .tiptoe:
            p.left = .init(thigh: 0.38 + 0.36 * sin(ph), knee: 0.72 + 0.6 * max(0, cos(ph)))
            p.right = .init(thigh: 0.38 + 0.36 * sin(ph + .pi), knee: 0.72 + 0.6 * max(0, cos(ph + .pi)))
            p.pelvisRoll = 0.07 * sin(ph)
            p.pelvisPitch = 0.06
            p.neckLean = 0.36 + 0.05 * sin(2 * ph)
            p.headRoll = -0.05 * sin(ph)
        case .waddle:
            p.left = .init(thigh: 0.36 + 0.2 * sin(ph), knee: 0.72 + 0.35 * max(0, cos(ph)))
            p.right = .init(thigh: 0.36 + 0.2 * sin(ph + .pi), knee: 0.72 + 0.35 * max(0, cos(ph + .pi)))
            p.pelvisRoll = 0.22 * sin(ph)
            p.headRoll = -0.18 * sin(ph)
            p.neckLean = 0.3
        case .strut:
            // Huge cartoon strides, chest out, head bobbing like a pigeon.
            p.left = .init(thigh: 0.3 + 0.95 * sin(ph), knee: 0.45 + 1.15 * max(0, cos(ph)), foot: -0.2 * max(0, cos(ph)))
            p.right = .init(thigh: 0.3 + 0.95 * sin(ph + .pi), knee: 0.45 + 1.15 * max(0, cos(ph + .pi)), foot: -0.2 * max(0, cos(ph + .pi)))
            p.pelvisPitch = -0.12
            p.pelvisRoll = 0.05 * sin(ph)
            p.neckLean = 0.05 + 0.2 * sin(2 * ph)
            p.headPitch = 0.25
            p.lift = 0.15 * abs(cos(ph))
        case .scurry:
            // Legs spin around like wheels.
            let w = ph.remainder(dividingBy: 2 * .pi)
            p.left = .init(thigh: w, knee: 0.7 + 0.5 * max(0, sin(ph)))
            p.right = .init(thigh: (w + .pi).remainder(dividingBy: 2 * .pi), knee: 0.7 + 0.5 * max(0, sin(ph + .pi)))
            p.pelvisPitch = 0.3
            p.neckLean = 0.75
            p.neckBend = 0.05
            p.headPitch = 0.3
            p.billOpen = 0.2
            p.lift = 0.25 + 0.1 * sin(2 * ph)
        case .sneak:
            // Crouched, exaggerated high-knee tiptoe.
            p.left = .init(thigh: 0.85 + 0.45 * sin(ph), knee: 1.5 + 0.7 * max(0, cos(ph)), foot: -0.3)
            p.right = .init(thigh: 0.85 + 0.45 * sin(ph + .pi), knee: 1.5 + 0.7 * max(0, cos(ph + .pi)), foot: -0.3)
            p.pelvisPitch = 0.18
            p.neckLean = 0.65
            p.headPitch = -0.05
            p.headRoll = 0.08 * sin(ph)
        case .skip:
            p.left = .init(thigh: 0.55 + 0.5 * sin(ph), knee: 0.8 + 0.9 * max(0, sin(ph + 0.6)))
            p.right = .init(thigh: 0.55 + 0.5 * sin(ph + .pi), knee: 0.8 + 0.9 * max(0, sin(ph + .pi + 0.6)))
            p.lift = 1.1 * abs(sin(ph))
            p.neckLean = 0.2
            p.headPitch = 0.2
            p.headRoll = 0.12 * sin(ph)
            p.billOpen = 0.15
        case .moonwalk:
            // One leg slides back flat while the other rests on its toes.
            p.left = .init(thigh: 0.15 - 0.3 * sin(ph), knee: 0.35 + 0.9 * max(0, sin(ph)), foot: -0.6 * max(0, sin(ph)))
            p.right = .init(thigh: 0.15 - 0.3 * sin(ph + .pi), knee: 0.35 + 0.9 * max(0, sin(ph + .pi)), foot: -0.6 * max(0, sin(ph + .pi)))
            p.neckLean = 0.2
            p.headPitch = 0.15
            p.headRoll = 0.1 * sin(2 * ph)
        }
    }

    func render() {
        let rig = scene.rig
        let grounded = ![.air, .held].contains(state)
        rig.apply(pose: pose, grounded: grounded)
        rig.facing.eulerAngles.y = yawVis
        rig.root.eulerAngles.z = roll
        rig.setFlames(rocket && state == .air && vel.dy > 0, flicker: CGFloat.random(in: 0...1))

        // Blob shadow on whatever is below.
        let feetY = pos.y - hc
        let below = onCeiling ? nil : world.allStandable
            .filter { pos.x >= $0.x0 && pos.x <= $0.x1 && $0.y <= feetY + 1 }
            .max(by: { $0.y < $1.y })
        if let b = below, feetY - b.y < 160 {
            let h = feetY - b.y
            let k = max(0.2, 1 - h / 180)
            rig.shadow.isHidden = false
            rig.shadow.position = SCNVector3(0, b.y - pos.y, 0)
            rig.shadow.scale = SCNVector3(unit * k, unit * k, unit * k)
            rig.shadow.opacity = k
        } else {
            rig.shadow.isHidden = true
        }

        let origin = NSPoint(x: (pos.x - panelSize / 2).rounded(), y: (pos.y - panelSize / 2).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }

        // Full frame rate only while something is actually moving.
        let fps = (state == .sit && asleep) ? 20 : ([.idle, .hang, .sit].contains(state) && !hovering ? 30 : 60)
        if link?.preferredFrameRateRange.preferred != Float(fps) {
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: Float(fps), preferred: Float(fps))
        }
    }

    // MARK: Hover / click-through

    func updateHover() {
        if state == .held || pressed {
            panel.ignoresMouseEvents = false
            return
        }
        // Hit test against a rough body shape in the duck's own (possibly upside-down) frame.
        let dx = mouse.x - pos.x, dy = mouse.y - pos.y
        let c = cos(-roll), sn = sin(-roll)
        let lx = dx * c - dy * sn, ly = dx * sn + dy * c
        let s = sizeMul
        let headSide = cos(roll) >= 0 ? facing : -facing
        let body = abs(lx) < 15 * s && ly > -hc && ly < 20 * s
        let head = abs(lx - headSide * 6 * s) < 22 * s && ly > 14 * s && ly < 44 * s
        let over = body || head
        if over != hovering {
            if over { caughtRedHanded() }
            hovering = over
            panel.ignoresMouseEvents = !over
            if over { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: Sleepy Z's

    func spawnZ() {
        let text = SCNText(string: "z", extrusionDepth: 1)
        text.font = NSFont.systemFont(ofSize: 14 * sizeMul, weight: .heavy)
        text.flatness = 0.2
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 1, alpha: 1)
        text.materials = [m]
        let z = SCNNode(geometry: text)
        z.categoryBitMask = 2
        let dir: CGFloat = cos(yawVis) > 0 ? 1 : -1
        z.position = SCNVector3(facing * 12 * sizeMul * dir, 34 * sizeMul, 40)
        let outline = SCNNode(geometry: text.copy() as? SCNGeometry)
        let om = SCNMaterial(); om.lightingModel = .constant; om.diffuse.contents = NSColor(white: 0.1, alpha: 0.8)
        outline.geometry?.materials = [om]
        outline.position = SCNVector3(0.8, -0.8, -1.5)
        outline.categoryBitMask = 2
        z.addChildNode(outline)
        scene.scene.rootNode.addChildNode(z)
        let rise = SCNAction.moveBy(x: facing * 14 * sizeMul, y: 30 * sizeMul, z: 0, duration: 2.2)
        let grow = SCNAction.scale(to: 1.5, duration: 2.2)
        let fade = SCNAction.sequence([.wait(duration: 1.2), .fadeOut(duration: 1.0)])
        z.runAction(.sequence([.group([rise, grow, fade]), .removeFromParentNode()]))
    }
}

extension DuckPose {
    static func mix(_ a: DuckPose, _ b: DuckPose, _ k: CGFloat) -> DuckPose {
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * k }
        func leg(_ x: Leg, _ y: Leg) -> Leg { Leg(thigh: m(x.thigh, y.thigh), knee: m(x.knee, y.knee), foot: m(x.foot, y.foot)) }
        var o = DuckPose()
        o.left = leg(a.left, b.left)
        o.right = leg(a.right, b.right)
        o.pelvisRoll = m(a.pelvisRoll, b.pelvisRoll)
        o.pelvisPitch = m(a.pelvisPitch, b.pelvisPitch)
        o.neckLean = m(a.neckLean, b.neckLean)
        o.neckBend = m(a.neckBend, b.neckBend)
        o.headYaw = m(a.headYaw, b.headYaw)
        o.headPitch = m(a.headPitch, b.headPitch)
        o.headRoll = m(a.headRoll, b.headRoll)
        o.billOpen = b.billOpen > a.billOpen ? m(a.billOpen, b.billOpen) * 0.5 + b.billOpen * 0.5 : m(a.billOpen, b.billOpen)
        o.iris = b.iris < 0.3 ? b.iris : m(a.iris, b.iris)
        o.sitting = m(a.sitting, b.sitting)
        o.lift = m(a.lift, b.lift)
        return o
    }
}
