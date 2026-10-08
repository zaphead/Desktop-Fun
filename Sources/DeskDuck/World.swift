import AppKit

/// A one-way horizontal surface the duck can stand on (or hang from, for ceilings).
/// All coordinates are AppKit global points: origin at the bottom-left of the primary screen, y up.
struct Platform: Equatable {
    enum Kind { case floor, icon, window, ceiling }
    let id: String
    let kind: Kind
    var x0: CGFloat
    var x1: CGFloat
    var y: CGFloat
    var iconName: String? = nil

    var width: CGFloat { x1 - x0 }
    var midX: CGFloat { (x0 + x1) / 2 }
}

struct DesktopIcon {
    let name: String
    var center: CGPoint      // AppKit coords
    var finderPosition: CGPoint  // Finder's own coords (top-left origin), used when moving it
}

/// Keeps track of everything the duck can stand on: screen bottoms, desktop icons, window tops, menu bars.
final class World {
    private(set) var screens: [NSRect] = []
    private(set) var floors: [Platform] = []
    private var screenCeilings: [Platform] = []
    private var windowCeilings: [Platform] = []
    /// Underside of each screen's menu bar, for headroom checks.
    private var menuBarBottoms: [(screen: NSRect, y: CGFloat)] = []
    private(set) var windowTops: [Platform] = []
    /// How tall the duck is (feet to head) in points; surfaces without this much room above aren't standable.
    var duckHeight: CGFloat = 60

    /// Menu bars, the notch, and the tops of windows pressed up against them (hang from those like a bat).
    var ceilings: [Platform] { screenCeilings + windowCeilings }
    private(set) var windowRects: [NSRect] = []      // AppKit coords, front to back
    private(set) var icons: [DesktopIcon] = []
    private(set) var iconSize: CGFloat = 64
    private(set) var primaryHeight: CGFloat = 0
    private(set) var iconsAvailable = false
    var iconLookupFailed = false
    /// Icon temporarily owned by the surf animation; ignore Finder reports about it.
    var lockedIcon: String?

    private var iconQueryRunning = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() { refreshScreens() }

    var allStandable: [Platform] { floors + windowTops + iconPlatforms }

    var iconPlatforms: [Platform] {
        icons.compactMap { icon in
            let top = icon.center.y + iconSize * 0.4
            // Icons hidden behind a window aren't solid.
            if windowRects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: icon.center.x, y: top)) }) { return nil }
            if headroom(x: icon.center.x, y: top) < duckHeight { return nil }
            return Platform(id: "i:" + icon.name, kind: .icon,
                            x0: icon.center.x - iconSize * 0.4, x1: icon.center.x + iconSize * 0.4,
                            y: top, iconName: icon.name)
        }
    }

    func platform(id: String) -> Platform? {
        if id.hasPrefix("i:") { return iconPlatforms.first { $0.id == id } }
        if id.hasPrefix("w:") { return windowTops.first { $0.id == id } }
        if id.hasPrefix("c:") { return ceilings.first { $0.id == id } }
        return floors.first { $0.id == id }
    }

    func isInsideScreens(_ p: CGPoint) -> Bool { screens.contains { $0.contains(p) } }

    /// Space between a surface and the menu bar above it on the same screen.
    func headroom(x: CGFloat, y: CGFloat) -> CGFloat {
        guard let m = menuBarBottoms.first(where: { $0.screen.contains(CGPoint(x: x, y: y + 1)) }) else { return 0 }
        return m.y - y
    }

    static func isWindowPlatform(_ id: String) -> Bool { id.hasPrefix("w:") || id.hasPrefix("c:w") }

    func screen(containing p: CGPoint) -> NSRect? { screens.first { $0.contains(p) } }

    // MARK: Screens, menu bars, notch

    func refreshScreens() {
        let all = NSScreen.screens
        guard let primary = all.first else { return }
        primaryHeight = primary.frame.maxY
        screens = all.map(\.frame)
        let menuBars = menuBarRects()

        floors = []
        screenCeilings = []
        menuBarBottoms = []
        for (i, s) in all.enumerated() {
            let f = s.frame
            // Floor: bottom edge, except where another screen continues below.
            var segs = [(f.minX, f.maxX)]
            for o in screens where o != f && abs(o.maxY - f.minY) < 1 {
                segs = subtract(segs, o.minX, o.maxX)
            }
            for (j, seg) in segs.enumerated() where seg.1 - seg.0 > 40 {
                floors.append(Platform(id: "f:\(i).\(j)", kind: .floor, x0: seg.0, x1: seg.1, y: f.minY))
            }
            // Ceiling: underside of the menu bar. On notched screens, the notch itself is a taller nook.
            let barHeight = menuBars.first { $0.intersects(f) && abs($0.maxY - f.maxY) < 2 }?.height
                ?? (f.maxY - s.visibleFrame.maxY)
            menuBarBottoms.append((f, f.maxY - max(barHeight, 0)))
            guard barHeight > 0 else { continue }
            var ceilSegs = [(f.minX, f.maxX)]
            if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
                let n0 = f.minX + left.maxX - f.minX, n1 = right.minX
                if n1 - n0 > 40 {
                    ceilSegs = subtract(ceilSegs, n0, n1)
                    screenCeilings.append(Platform(id: "c:\(i).notch", kind: .ceiling, x0: n0 + 14, x1: n1 - 14, y: f.maxY))
                }
            }
            for (j, seg) in ceilSegs.enumerated() where seg.1 - seg.0 > 40 {
                screenCeilings.append(Platform(id: "c:\(i).\(j)", kind: .ceiling, x0: seg.0, x1: seg.1, y: f.maxY - barHeight))
            }
        }
    }

    private func menuBarRects() -> [NSRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return toAppKit(CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
    }

    private func subtract(_ segs: [(CGFloat, CGFloat)], _ a: CGFloat, _ b: CGFloat) -> [(CGFloat, CGFloat)] {
        segs.flatMap { s -> [(CGFloat, CGFloat)] in
            if b <= s.0 || a >= s.1 { return [s] }
            var out: [(CGFloat, CGFloat)] = []
            if a > s.0 { out.append((s.0, a)) }
            if b < s.1 { out.append((b, s.1)) }
            return out
        }
    }

    func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Windows

    /// Top edges of ordinary app windows, trimmed wherever a window in front covers them.
    func refreshWindows() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var rects: [(Int, NSRect)] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.1,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = toAppKit(CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
            if r.width < 140 || r.height < 80 { continue }
            rects.append((num, r))
            if rects.count >= 14 { break }
        }
        windowRects = rects.map(\.1)
        var tops: [Platform] = []
        var hangs: [Platform] = []
        for (idx, (num, r)) in rects.enumerated() {
            var segs = [(r.minX + 12, r.maxX - 12)]
            for (_, front) in rects[..<idx] where front.minY < r.maxY - 1 && front.maxY > r.maxY - 1 {
                segs = subtract(segs, front.minX - 6, front.maxX + 6)
            }
            if !screens.contains(where: { $0.insetBy(dx: 0, dy: -2).contains(CGPoint(x: r.midX, y: r.maxY - 1)) }) { continue }
            for (j, seg) in segs.enumerated() where seg.1 - seg.0 > 50 {
                if headroom(x: (seg.0 + seg.1) / 2, y: r.maxY) >= duckHeight {
                    tops.append(Platform(id: "w:\(num).\(j)", kind: .window, x0: seg.0, x1: seg.1, y: r.maxY))
                } else {
                    // Too close to the top of the screen to stand on: hang underneath instead.
                    hangs.append(Platform(id: "c:w\(num).\(j)", kind: .ceiling, x0: seg.0, x1: seg.1, y: r.maxY))
                }
            }
        }
        windowTops = tops
        windowCeilings = hangs
    }

    // MARK: Desktop icons (via Finder scripting)

    func refreshIcons() {
        guard !iconQueryRunning else { return }
        iconQueryRunning = true
        let script = """
        const f = Application("Finder");
        let size = 64;
        try { size = f.desktop.containerWindow.iconViewOptions.iconSize(); } catch (e) {}
        JSON.stringify({size: size, items: f.desktop.items().map(i => [i.name(), i.desktopPosition()])});
        """
        Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script]) { [weak self] ok, out in
            guard let self else { return }
            self.iconQueryRunning = false
            guard ok, let data = out.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[Any]] else {
                self.iconLookupFailed = true
                return
            }
            self.iconLookupFailed = false
            self.iconsAvailable = true
            if let s = json["size"] as? CGFloat { self.iconSize = s }
            var found: [DesktopIcon] = []
            for item in items {
                guard item.count == 2, let name = item[0] as? String, let p = item[1] as? [String: CGFloat],
                      let x = p["x"], let y = p["y"] else { continue }
                if name == self.lockedIcon, let existing = self.icons.first(where: { $0.name == name }) {
                    found.append(existing)
                    continue
                }
                found.append(DesktopIcon(name: name, center: CGPoint(x: x, y: self.primaryHeight - y),
                                         finderPosition: CGPoint(x: x, y: y)))
            }
            self.icons = found
        }
    }

    /// Updates our cached copy of an icon while it's being moved, so the duck sees the new spot immediately.
    func setIconCenter(_ name: String, _ c: CGPoint) {
        guard let i = icons.firstIndex(where: { $0.name == name }) else { return }
        icons[i].center = c
        icons[i].finderPosition = CGPoint(x: c.x, y: primaryHeight - c.y)
    }

    func finderPoint(for appKit: CGPoint) -> CGPoint { CGPoint(x: appKit.x, y: primaryHeight - appKit.y) }
}

/// Tiny async process runner that reports back on the main queue.
enum Shell {
    static func run(_ path: String, _ args: [String], completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(false, "") }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async { completion(p.terminationStatus == 0, s) }
        }
    }
}
