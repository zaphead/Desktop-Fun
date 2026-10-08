import AppKit
import CoreGraphics

/// The pranks the duck can pull. Footprints and "caught red-handed" are passive and live alongside these.
enum Prank: String, CaseIterable {
    case iconHeist, buttonSquat, cursorHeist, hideAndSeek, windowBounce

    var title: String {
        switch self {
        case .iconHeist: "Icon Heist"
        case .buttonSquat: "Button Squat"
        case .cursorHeist: "Cursor Heist"
        case .hideAndSeek: "Hide and Seek"
        case .windowBounce: "Window Bounce"
        }
    }
}

enum HeistAction { case none, grab }
enum CursorPhase { case approach, carry, guarding }
enum HidePhase { case sneakIn, hidden, peeking, comingOut }

/// Mischief rules: rare, always undoable, never touches what's inside your apps, and backs off when you
/// go to use something. Every prank has a deadline and cleans up after itself if interrupted.
extension DuckController {

    // MARK: Scheduling

    func isEnabled(_ p: Prank) -> Bool {
        switch p {
        case .iconHeist: settings.iconHeist
        case .buttonSquat: settings.buttonSquat
        case .cursorHeist: settings.cursorHeist
        case .hideAndSeek: settings.hideAndSeek
        case .windowBounce: settings.windowBounce
        }
    }

    func canStart(_ p: Prank, forced: Bool) -> Bool {
        switch p {
        case .iconHeist: return world.iconsAvailable && !world.iconPlatforms.isEmpty
        case .buttonSquat: return AXScanner.isTrusted && settings.useAppContent && !world.contentButtons.isEmpty
        case .cursorHeist: return forced || mouseIdle > 40
        case .hideAndSeek: return !hideSpots().isEmpty
        case .windowBounce: return AXScanner.isTrusted && !world.windowTops.isEmpty
        }
    }

    /// Called from decide(): every so often, try something mischievous.
    func maybeStartMischief(_ g: Platform) -> Bool {
        guard prank == nil, settings.mischief > 0.01, !onCeiling else { return false }
        let cooldown = 240 - 210 * settings.mischief      // Angel: ~4 min apart, Gremlin: ~30 s
        guard time - lastMischief > cooldown, Double.random(in: 0...1) < 0.2 + 0.5 * settings.mischief else { return false }
        for p in Prank.allCases.shuffled() where isEnabled(p) && canStart(p, forced: false) {
            if startPrank(p, forced: false) { return true }
        }
        lastMischief = time - cooldown * 0.6   // nothing possible right now; look again a bit sooner
        return false
    }

    /// "Try it" from the menu or Settings: do this prank next, even if it's switched off.
    func tryPrank(_ p: Prank) {
        abortPrank()
        pendingTry = p
        if [.idle, .walk, .sit, .hang, .quack, .land].contains(state) {
            asleep = false
            enter(.idle, dur: 0.05)
        }
    }

    func tryFootprints() {
        muddySteps = 18
        guard let g = currentGround(), !onCeiling, [.idle, .walk, .sit, .land].contains(state) else { return }
        if let far = jumpTargets(from: g, rocket: true).randomElement() {
            jump(to: far, rocket: true)
        } else {
            walk(to: min(max(pos.x + .random(in: -300...300), g.x0 + 12), g.x1 - 12))
        }
    }

    @discardableResult
    func startPrank(_ p: Prank, forced: Bool) -> Bool {
        guard canStart(p, forced: forced) else { return false }
        let ok: Bool
        switch p {
        case .iconHeist: ok = startHeist()
        case .buttonSquat: ok = startSquat()
        case .cursorHeist: cursorPhase = .approach; ok = true
        case .hideAndSeek: ok = startHide()
        case .windowBounce: ok = startBounce()
        }
        guard ok else { return false }
        prank = p
        prankDeadline = time + (p == .iconHeist ? 150 : 90)
        goal = nil
        if Double.random(in: 0...1) < 0.6 { quacker.play("snicker", volume: 0.3) }
        return true
    }

    /// Continue the active prank whenever the duck is deciding what to do next.
    func prankStep(_ g: Platform) -> Bool {
        if let p = pendingTry {
            pendingTry = nil
            if !startPrank(p, forced: true) {
                quacker.play("bonk", volume: 0.2)   // couldn't do it from here
                return false
            }
        }
        guard let p = prank else { return false }
        if time > prankDeadline { abortPrank(); return false }
        switch p {
        case .iconHeist: return heistStep(g)
        case .buttonSquat: return squatStep(g)
        case .cursorHeist: return cursorStep(g)
        case .hideAndSeek: return hideStep(g)
        case .windowBounce: return bounceStep(g)
        }
    }

    /// Per-frame work: carried icons and cursors follow the bill, tosses fly, footprints get stamped.
    func mischiefFrame(_ dt: Double) {
        if prank != nil && time > prankDeadline { abortPrank() }

        if let name = carried {
            carryBlend = min(1, carryBlend + CGFloat(dt) * 4)
            let target = carriedIconCenter()
            let c = CGPoint(x: carryFrom.x + (target.x - carryFrom.x) * carryBlend,
                            y: carryFrom.y + (target.y - carryFrom.y) * carryBlend)
            world.setIconCenter(name, c)
            mover.move(to: world.finderPoint(for: c))
            if mover.failed { abortPrank() }
        }

        if var t = toss {
            t.t += dt
            let k = CGFloat(min(1, t.t / 0.45))
            let c = CGPoint(x: t.from.x + (t.to.x - t.from.x) * k,
                            y: t.from.y + (t.to.y - t.from.y) * k + 70 * sizeMul * 4 * k * (1 - k))
            world.setIconCenter(t.name, c)
            mover.move(to: world.finderPoint(for: c))
            toss = t
            if k >= 1 { finishToss() }
        }

        if cursorHeld {
            let m = NSEvent.mouseLocation
            if let w = cursorWarp, hypot(m.x - w.x, m.y - w.y) > 12 {
                // You touched the mouse: let go immediately.
                cursorHeld = false
                cursorWarp = nil
                quacker.play("quack", volume: 0.3)
                prankDone(guilty: true)
            } else {
                let b = billPoint()
                let target = CGPoint(x: b.x + facing * 6 * sizeMul, y: b.y - 4 * sizeMul)
                CGWarpMouseCursorPosition(CGPoint(x: target.x, y: world.primaryHeight - target.y))
                CGAssociateMouseAndMouseCursorPosition(1)
                cursorWarp = target
            }
        } else if cursorGrabArmed && state == .air {
            let m = NSEvent.mouseLocation, b = billPoint()
            if hypot(m.x - b.x, m.y - b.y) < 60 * sizeMul {
                cursorGrabArmed = false
                cursorHeld = true
                cursorWarp = m
                cursorPhase = .carry
                quacker.play("laugh", volume: 0.3)
            } else if vel.dy < -250 {
                cursorGrabArmed = false   // missed; try again after landing
            }
        }

        // Muddy footprints while walking.
        if muddySteps > 0 && state == .walk && !onCeiling && settings.footprints {
            let idx = Int(walkPhase / .pi)
            if idx != lastStepIndex {
                lastStepIndex = idx
                muddySteps -= 1
                footprints.add(at: CGPoint(x: pos.x + (idx % 2 == 0 ? 3 : -3) * sizeMul, y: pos.y - hc),
                               facing: facing, scale: sizeMul)
            }
        }
    }

    func didLand(on p: Platform, impact: CGFloat, wasRocket: Bool) {
        if settings.footprints && (wasRocket || impact > 1300) && Double.random(in: 0...1) < 0.75 {
            muddySteps = max(muddySteps, 14)
            for dx in [-5.0, 5.0] {
                footprints.add(at: CGPoint(x: pos.x + CGFloat(dx) * sizeMul, y: pos.y - hc), facing: facing, scale: sizeMul)
            }
        }
        if prank == .windowBounce, bounceLeft > 0, let b = bounceWindow, p.id.hasPrefix("w:\(b.num).") {
            AXScanner.bounceWindow(pid: b.pid, frame: b.orig, dy: 10 * sqrt(sizeMul))
            bounceLeft -= 1
            if bounceLeft > 0 {
                flip = nil; rocket = false; ceilingTarget = nil
                pendingLaunch = CGVector(dx: 0, dy: 330 * sqrt(sizeMul))
                jumpTargetY = p.y
                enter(.crouch, dur: 0.1)
            }
            if bounceLeft % 2 == 0 { quacker.play("laugh", volume: 0.22) }
        }
    }

    // MARK: Ending pranks

    /// Interrupted (you grabbed the duck, the deadline passed, something vanished): put things down safely.
    func abortPrank() {
        if let name = carried ?? toss?.name {
            let c = world.icons.first { $0.name == name }?.center ?? carriedIconCenter()
            mover.move(to: world.finderPoint(for: c))
            releaseIcon(name)
        }
        carried = nil
        toss = nil
        if state == .hide, let h = hideSpot {
            pos.x = h.edge - h.dir * 30 * sizeMul
            enter(.idle, dur: 0.3)
        }
        let wasActive = prank != nil
        clearPrankState()
        if wasActive { lastMischief = time }
    }

    func prankDone(guilty: Bool) {
        clearPrankState()
        lastMischief = time
        if guilty { guiltyUntil = time + 30 }
    }

    private func clearPrankState() {
        if let b = bounceWindow { AXScanner.restoreWindow(pid: b.pid, frame: b.orig) }
        bounceWindow = nil
        bounceLeft = 0
        bounceTarget = nil
        cursorHeld = false
        cursorWarp = nil
        cursorGrabArmed = false
        if squatting { squatting = false }
        squatTarget = nil
        hideSpot = nil
        heistJobs = []
        heistFinaleX = nil
        heistAction = .none
        prank = nil
    }

    // MARK: Moving around for pranks

    /// One step toward standing on `p` at `x`. Returns true once the duck is there.
    func travel(to p: Platform, x: CGFloat) -> Bool {
        guard let g = currentGround() else { return false }
        if onCeiling { dropFromCeiling(); return false }
        let tx = min(max(x, p.x0 + 6), p.x1 - 6)
        if g.id == p.id {
            if abs(pos.x - tx) < 8 * sizeMul { return true }
            walk(to: tx, gait: prank == .cursorHeist || carried != nil ? .scurry : .sneak)
            return false
        }
        let far = hypot(tx - pos.x, p.y - g.y) > 280 * sizeMul || p.y - g.y > 160 * sizeMul
        jump(to: (p, tx), rocket: far)
        return false
    }

    /// Highest surface under a point (or the screen floor), ignoring the icon being carried.
    func platform(below pt: CGPoint) -> Platform? {
        world.allStandable.filter { pt.x >= $0.x0 + 4 && pt.x <= $0.x1 - 4 && $0.y <= pt.y }.max { $0.y < $1.y }
    }

    /// Launch straight from wherever the duck is toward a spot (no ground needed, e.g. right after grabbing).
    func launch(toward p: Platform, x: CGFloat) {
        let dx = x - pos.x, dy = p.y - (pos.y - hc)
        let h = max(dy, 0) + 60 + 0.1 * abs(dx)
        let vy = sqrt(2 * gravity * h)
        let t = (vy + sqrt(max(0, vy * vy - 2 * gravity * dy))) / gravity
        facing = dx >= 0 ? 1 : -1
        rocket = h > 260
        flip = nil
        ceilingTarget = nil
        launch(CGVector(dx: dx / t, dy: vy))
        jumpTargetY = p.y
    }

    func billPoint() -> CGPoint {
        let up: CGFloat = cos(roll) >= 0 ? 1 : -1
        return CGPoint(x: pos.x + facing * 20 * sizeMul, y: pos.y + up * 24 * sizeMul)
    }

    private func carriedIconCenter() -> CGPoint {
        let b = billPoint()
        return CGPoint(x: b.x + facing * world.iconSize * 0.3, y: b.y - world.iconSize * 0.3)
    }

    // MARK: Icon heist

    private func startHeist() -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        let full = screen.frame, vis = screen.visibleFrame
        let names = world.iconPlatforms.compactMap(\.iconName).shuffled()
        guard !names.isEmpty else { return false }
        func clear(_ c: CGPoint) -> Bool { world.headroom(x: c.x, y: c.y + world.iconSize * 0.4) >= world.duckHeight }
        var variants = ["hide"]
        if names.count >= 2 { variants += ["pile", "row", "tower"] }
        var jobs: [(String, CGPoint)] = []
        heistFinaleX = nil

        switch variants.randomElement()! {
        case "pile":
            var center = CGPoint.zero
            for _ in 0..<20 {
                let c = CGPoint(x: .random(in: (vis.minX + 140)...(vis.maxX - 140)), y: .random(in: (vis.minY + 100)...(vis.midY)))
                if clear(c) && !world.windowRects.contains(where: { $0.contains(c) }) { center = c; break }
            }
            guard center != .zero else { return false }
            jobs = names.prefix(4).map { ($0, CGPoint(x: center.x + .random(in: -14...14), y: center.y + .random(in: -10...10))) }
        case "row":
            let y = vis.minY + 70
            let x0 = vis.minX + 80 + .random(in: 0...160)
            jobs = names.prefix(6).enumerated().map { i, n in (n, CGPoint(x: x0 + CGFloat(i) * 86, y: y)) }
        case "tower":
            let x = CGFloat.random(in: (vis.minX + 160)...(vis.maxX - 160))
            jobs = names.prefix(4).enumerated().map { i, n in (n, CGPoint(x: x, y: vis.minY + 60 + CGFloat(i) * 58)) }
            heistFinaleX = x
        default:   // hide one icon behind the Dock or a window
            var spots: [CGPoint] = []
            if vis.minY - full.minY > 30 {
                spots.append(CGPoint(x: full.midX + .random(in: -120...120), y: full.minY + (vis.minY - full.minY) / 2))
            }
            for r in world.windowRects where r.width < full.width * 0.9 && full.contains(CGPoint(x: r.midX, y: r.midY)) {
                spots.append(CGPoint(x: r.midX + .random(in: -r.width / 4...r.width / 4), y: r.midY))
            }
            if spots.isEmpty { spots.append(CGPoint(x: vis.minX + 45, y: vis.minY + 45)) }
            jobs = [(names[0], spots.randomElement()!)]
        }
        for (n, _) in jobs { recordHome(n) }
        heistJobs = jobs.map { (name: $0.0, dest: $0.1) }
        heistAction = .none
        return true
    }

    private func heistStep(_ g: Platform) -> Bool {
        if toss != nil { enter(.idle, dur: 0.15); return true }
        if carried != nil {
            // Carrying: get near the drop spot, then toss it into place.
            guard let job = heistJobs.first else { return true }
            if abs(pos.x - job.dest.x) < 90 * sizeMul && abs((pos.y - hc) - job.dest.y) < 260 {
                startToss()
                return true
            }
            if let below = platform(below: job.dest) ?? world.floors.first {
                let side: CGFloat = pos.x < job.dest.x ? -1 : 1
                if travel(to: below, x: job.dest.x + side * 40 * sizeMul) { startToss() }
            }
            return true
        }
        guard let job = heistJobs.first else {
            // All done. For a tower, climb up and stand on top of it.
            if let x = heistFinaleX, let top = world.iconPlatforms.filter({ abs($0.midX - x) < 6 }).max(by: { $0.y < $1.y }) {
                if travel(to: top, x: top.midX) {
                    heistFinaleX = nil
                    quacker.play("laugh", volume: 0.35)
                    prankDone(guilty: true)
                    enter(.dance, dur: 1.8)
                }
                return true
            }
            quacker.play("laugh", volume: 0.3)
            prankDone(guilty: true)
            return false
        }
        guard let p = world.iconPlatforms.first(where: { $0.iconName == job.name }) else {
            heistJobs.removeFirst()   // that icon is covered now; skip it
            return heistStep(g)
        }
        if travel(to: p, x: p.midX) {
            heistAction = .grab
            mover.begin(iconName: job.name)
            world.lockedIcon = job.name
            enter(.prank, dur: 0.45)
        }
        return true
    }

    /// The timed `.prank` state finished (currently: bending down to grab an icon).
    func prankActionDone() {
        guard heistAction == .grab, let job = heistJobs.first else { return enter(.idle, dur: 0.1) }
        heistAction = .none
        carried = job.name
        carryFrom = world.icons.first { $0.name == job.name }?.center ?? carriedIconCenter()
        carryBlend = 0
        world.carriedIcon = job.name
        quacker.play("snicker", volume: 0.3)
        if let below = platform(below: job.dest) ?? world.floors.first {
            let side: CGFloat = pos.x < job.dest.x ? -1 : 1
            launch(toward: below, x: job.dest.x + side * 40 * sizeMul)
        } else {
            startFall()
        }
    }

    private func startToss() {
        guard let name = carried, let job = heistJobs.first else { return }
        let from = world.icons.first { $0.name == name }?.center ?? carriedIconCenter()
        carried = nil
        toss = (name, from, job.dest, 0)
        facing = job.dest.x >= pos.x ? 1 : -1
        billT = 0
        enter(.quack, dur: 0.45)
    }

    private func finishToss() {
        guard let t = toss else { return }
        toss = nil
        world.setIconCenter(t.name, t.to)
        mover.move(to: world.finderPoint(for: t.to))
        releaseIcon(t.name)
        if !heistJobs.isEmpty { heistJobs.removeFirst() }
        quacker.play(heistJobs.isEmpty ? "laugh" : "snicker", volume: 0.28)
    }

    private func releaseIcon(_ name: String) {
        mover.end()
        if world.carriedIcon == name { world.carriedIcon = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.world.lockedIcon == name { self?.world.lockedIcon = nil }
        }
    }

    // MARK: Putting icons back

    private static let homesKey = "iconHomes"

    var iconHomes: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: DuckController.homesKey) as? [String: [Double]] ?? [:] }
        set {
            UserDefaults.standard.set(newValue, forKey: DuckController.homesKey)
            settings.strayIcons = newValue.count
        }
    }

    /// Remember where an icon lived before the duck first moved it.
    func recordHome(_ name: String) {
        var homes = iconHomes
        guard homes[name] == nil, let icon = world.icons.first(where: { $0.name == name }) else { return }
        homes[name] = [Double(icon.finderPosition.x), Double(icon.finderPosition.y)]
        iconHomes = homes
    }

    func putEverythingBack() {
        if prank == .iconHeist { abortPrank() }
        endSurf()
        let homes = iconHomes
        guard !homes.isEmpty, let json = try? JSONSerialization.data(withJSONObject: homes),
              let arg = String(data: json, encoding: .utf8) else { return }
        let script = """
        function run(argv) {
          const f = Application("Finder"); const homes = JSON.parse(argv[0]);
          for (const n in homes) { try { f.desktop.items.byName(n).desktopPosition = {x: homes[n][0], y: homes[n][1]}; } catch (e) {} }
        }
        """
        Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script, arg]) { [weak self] ok, _ in
            guard let self, ok else { return }
            self.iconHomes = [:]
            self.world.refreshIcons()
            self.quacker.play("chirp", volume: 0.25)
        }
    }

    // MARK: Button squat

    private func startSquat() -> Bool {
        let buttons = world.contentButtons.filter { world.platform(id: $0.platformID) != nil }
        // Favor buttons toward the bottom-right of the window, where "Send" and "OK" tend to live.
        guard let b = buttons.max(by: { ($0.rect.maxX - $0.rect.minY) * .random(in: 0.6...1) < ($1.rect.maxX - $1.rect.minY) * .random(in: 0.6...1) }) else { return false }
        squatTarget = (b.platformID, b.rect.midX)
        return true
    }

    private func squatStep(_ g: Platform) -> Bool {
        guard let target = squatTarget else { prankDone(guilty: false); return false }
        guard let p = world.platform(id: target.id) else { abortPrank(); return false }
        if travel(to: p, x: target.x) {
            squatting = true
            asleep = false
            quacker.play("snicker", volume: 0.28)
            enter(.sit, dur: .random(in: 20...40))
        }
        return true
    }

    func updateSquat() {
        let near = hypot(mouse.x - pos.x, mouse.y - pos.y) < 150 * sizeMul && mouseIdle < 0.3
        if near { return squatFlee() }
        if Double.random(in: 0...1) < 0.002 { quacker.play("snicker", volume: 0.18) }
        if stateT >= stateDur {
            squatting = false
            prankDone(guilty: true)
            enter(.idle, dur: 0.5)
        }
    }

    /// Panic! Scramble off the button, away from the cursor.
    func squatFlee() {
        squatting = false
        prankDone(guilty: true)
        billT = 0
        quacker.play("quack", volume: 0.32)
        guard let g = currentGround() else { return startFall() }
        let away = jumpTargets(from: g, rocket: false).max { a, b in
            hypot(a.1 - mouse.x, a.0.y - mouse.y) < hypot(b.1 - mouse.x, b.0.y - mouse.y)
        } ?? jumpTargets(from: g, rocket: true).randomElement()
        if let t = away {
            jump(to: t, rocket: hypot(t.1 - pos.x, t.0.y - g.y) > 300)
            enter(.crouch, dur: 0.06)   // no wind-up when panicking
        } else {
            walk(to: mouse.x > pos.x ? g.x0 + 12 : g.x1 - 12, gait: .scurry)
        }
    }

    // MARK: Cursor heist

    private func cursorStep(_ g: Platform) -> Bool {
        switch cursorPhase {
        case .approach:
            let m = NSEvent.mouseLocation
            let bill = billPoint()
            let rise = m.y - bill.y
            if abs(m.x - pos.x) < 300 * sizeMul && rise > 6 && rise < 1100 {
                // Leap so the bill peaks right at the cursor.
                let vy = sqrt(2 * gravity * rise)
                let t = vy / gravity
                facing = m.x >= pos.x ? 1 : -1
                rocket = rise > 240
                flip = nil
                ceilingTarget = nil
                cursorGrabArmed = true
                jumpTargetY = nil
                pendingLaunch = CGVector(dx: (m.x - facing * 26 * sizeMul - pos.x) / t, dy: vy)
                enter(.crouch, dur: 0.2)
                return true
            }
            if hypot(m.x - bill.x, m.y - bill.y) < 70 * sizeMul {
                cursorHeld = true
                cursorWarp = m
                cursorPhase = .carry
                quacker.play("laugh", volume: 0.3)
                return cursorStep(g)
            }
            guard let below = platform(below: CGPoint(x: m.x, y: m.y - 20)) else { abortPrank(); return false }
            if travel(to: below, x: m.x - 20 * sizeMul) && rise <= 6 {
                abortPrank()   // cursor is somewhere we can't reach
                return false
            }
            return true
        case .carry:
            // Somewhere silly: the notch if there is one, otherwise any ceiling, otherwise far away.
            let ceilings = world.ceilings.filter { c in
                let h = c.y - hc - pos.y
                return h > 40 && h < 1400 && abs(min(max(pos.x, c.x0 + 20), c.x1 - 20) - pos.x) < 900
            }
            if let c = ceilings.first(where: { $0.id.hasSuffix("notch") }) ?? ceilings.randomElement() {
                jumpToCeiling(c)
                cursorPhase = .guarding
                return true
            }
            if let far = jumpTargets(from: g, rocket: true).randomElement() {
                jump(to: far, rocket: true)
                cursorPhase = .guarding
                return true
            }
            cursorPhase = .guarding
            return cursorStep(g)
        case .guarding:
            if cursorHeld {
                // Arrived: let go, and keep watch over the loot for a while.
                cursorHeld = false
                cursorWarp = nil
                quacker.play("laugh", volume: 0.32)
                enter(onCeiling ? .hang : .sit, dur: .random(in: 20...40))
                return true
            }
            prankDone(guilty: true)
            return false
        }
    }

    // MARK: Hide and seek

    /// Screen edges with nothing beyond them, where the duck can tuck itself out of sight.
    func hideSpots() -> [(platform: Platform, edge: CGFloat, dir: CGFloat)] {
        var out: [(Platform, CGFloat, CGFloat)] = []
        for f in world.floors {
            if !world.isInsideScreens(CGPoint(x: f.x0 - 8, y: f.y + 30)) { out.append((f, f.x0, -1)) }
            if !world.isInsideScreens(CGPoint(x: f.x1 + 8, y: f.y + 30)) { out.append((f, f.x1, 1)) }
        }
        return out
    }

    private func startHide() -> Bool {
        guard let s = hideSpots().min(by: { abs($0.edge - pos.x) * .random(in: 0.5...1.5) < abs($1.edge - pos.x) * .random(in: 0.5...1.5) }) else { return false }
        hideSpot = (s.platform.id, s.platform.y, s.edge, s.dir)
        hidePhase = .sneakIn
        return true
    }

    private func hideStep(_ g: Platform) -> Bool {
        guard let h = hideSpot, let p = world.platform(id: h.platformID) else { abortPrank(); return false }
        if travel(to: p, x: h.edge - h.dir * 30 * sizeMul) {
            hidePhase = .sneakIn
            hideNext = time + 0.8
            facing = h.dir
            quacker.play("snicker", volume: 0.2)
            enter(.hide, dur: .random(in: 35...65))
        }
        return true
    }

    func updateHide(_ dt: Double) {
        guard let h = hideSpot else { return enter(.idle, dur: 0.3) }
        pos.y = h.y + hc
        roll += (0 - roll) * CGFloat(min(1, dt * 12))
        let hiddenX = h.edge + h.dir * 34 * sizeMul
        let peekX = h.edge + h.dir * 6 * sizeMul
        let outX = h.edge - h.dir * 35 * sizeMul
        var target = hiddenX
        switch hidePhase {
        case .sneakIn:
            facing = h.dir
            if time > hideNext { hidePhase = .hidden; hideNext = time + .random(in: 3...7) }
        case .hidden:
            if time > hideNext {
                hidePhase = .peeking
                hideNext = time + .random(in: 1.5...2.8)
                facing = -h.dir
            }
            if stateT >= stateDur { hidePhase = .comingOut }
        case .peeking:
            target = peekX
            facing = -h.dir
            if time > hideNext { hidePhase = .hidden; hideNext = time + .random(in: 3...7) }
        case .comingOut:
            target = outX
            facing = -h.dir
            if abs(pos.x - outX) < 3 {
                quacker.play("laugh", volume: 0.28)   // you never found me
                prankDone(guilty: false)
                enter(.idle, dur: 0.6)
                return
            }
        }
        let speed: CGFloat = hidePhase == .peeking ? 4 : 2.5
        let dx = (target - pos.x) * CGFloat(min(1, dt * Double(speed)))
        pos.x += dx
        if abs(dx) > 0.3 { walkPhase += CGFloat(dt) * 6 }
    }

    /// You clicked it while it was hiding: it's found, and it's thrilled about it.
    func foundWhileHiding() {
        guard let h = hideSpot else { return }
        pos.x = h.edge - h.dir * 32 * sizeMul
        facing = -h.dir
        hideSpot = nil
        prankDone(guilty: false)
        quacker.play("laugh", volume: 0.35)
        billT = 0
        enter(.dance, dur: 2.0)
    }

    // MARK: Window bounce

    private func startBounce() -> Bool {
        let tops = world.windowTops.filter { $0.width > 60 }
        guard let t = tops.min(by: { hypot($0.midX - pos.x, $0.y - pos.y) < hypot($1.midX - pos.x, $1.y - pos.y) }) else { return false }
        bounceTarget = t.id
        return true
    }

    private func bounceStep(_ g: Platform) -> Bool {
        if bounceWindow != nil {
            // Finished bouncing (or ran out of hops): settle the window back exactly where it was.
            prankDone(guilty: true)
            quacker.play("laugh", volume: 0.3)
            return false
        }
        guard let id = bounceTarget, let p = world.platform(id: id) else { abortPrank(); return false }
        if travel(to: p, x: min(max(pos.x, p.x0 + 30), p.x1 - 30)) {
            guard let num = Int(id.dropFirst(2).split(separator: ".").first ?? ""),
                  let info = world.windowInfo[num] else { abortPrank(); return false }
            bounceWindow = (num, info.pid, info.frame)
            bounceLeft = .random(in: 4...7)
            flip = nil; rocket = false; ceilingTarget = nil
            pendingLaunch = CGVector(dx: 0, dy: 330 * sqrt(sizeMul))
            enter(.crouch, dur: 0.15)
        }
        return true
    }

    // MARK: Caught red-handed

    func caughtRedHanded() {
        guard settings.caughtRedHanded, time < guiltyUntil, prank == nil, !onCeiling,
              [.idle, .walk, .land, .sit, .quack].contains(state) else { return }
        guiltyUntil = -1
        asleep = false
        innocentWhistled = false
        enter(.innocent, dur: 3.4)
    }
}
