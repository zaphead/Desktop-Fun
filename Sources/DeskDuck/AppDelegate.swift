import AppKit

/// Menu bar app: owns the duck and its settings. No Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var duck: DuckController!
    private let defaults = UserDefaults.standard
    private let sizes: [(String, CGFloat)] = [("Small", 0.75), ("Medium", 1.0), ("Large", 1.35)]

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: ["theme": 0, "size": 1.0, "moveIcons": true, "muted": false])
        let theme = DuckTheme.all[min(max(defaults.integer(forKey: "theme"), 0), DuckTheme.all.count - 1)]
        duck = DuckController(theme: theme, sizeMul: CGFloat(defaults.double(forKey: "size")))
        duck.allowIconMoves = defaults.bool(forKey: "moveIcons")
        duck.quacker.muted = defaults.bool(forKey: "muted")
        duck.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        duck.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Desk Duck")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Quack!", #selector(quack)))
        m.addItem(item("Summon to Cursor", #selector(summon)))
        m.addItem(item(duck.isHidden ? "Show Duck" : "Hide Duck", #selector(toggleHidden)))
        m.addItem(.separator())

        let colors = NSMenu()
        for (i, t) in DuckTheme.all.enumerated() {
            let it = item(t.name, #selector(pickTheme(_:)))
            it.tag = i
            it.state = defaults.integer(forKey: "theme") == i ? .on : .off
            colors.addItem(it)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        m.addItem(colorItem)

        let sizeMenu = NSMenu()
        for (i, s) in sizes.enumerated() {
            let it = item(s.0, #selector(pickSize(_:)))
            it.tag = i
            it.state = abs(defaults.double(forKey: "size") - Double(s.1)) < 0.01 ? .on : .off
            sizeMenu.addItem(it)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        m.addItem(sizeItem)

        let move = item("Let Duck Move Icons", #selector(toggleIcons))
        move.state = duck.allowIconMoves ? .on : .off
        m.addItem(move)
        let mute = item("Mute", #selector(toggleMute))
        mute.state = duck.quacker.muted ? .on : .off
        m.addItem(mute)
        if duck.world.iconLookupFailed {
            let warn = NSMenuItem(title: "Can't see desktop icons — allow Finder access in Privacy settings", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            m.addItem(warn)
        }
        m.addItem(.separator())
        m.addItem(item("Quit Desk Duck", #selector(quit)))
        return m
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func quack() { duck.quackNow() }
    @objc private func summon() { duck.summon() }
    @objc private func toggleHidden() { duck.setHidden(!duck.isHidden) }
    @objc private func pickTheme(_ s: NSMenuItem) {
        defaults.set(s.tag, forKey: "theme")
        duck.setTheme(DuckTheme.all[s.tag])
    }
    @objc private func pickSize(_ s: NSMenuItem) {
        let v = sizes[s.tag].1
        defaults.set(Double(v), forKey: "size")
        duck.setSize(v)
    }
    @objc private func toggleIcons() {
        duck.allowIconMoves.toggle()
        defaults.set(duck.allowIconMoves, forKey: "moveIcons")
    }
    @objc private func toggleMute() {
        duck.quacker.muted.toggle()
        defaults.set(duck.quacker.muted, forKey: "muted")
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
