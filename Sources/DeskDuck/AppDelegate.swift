import AppKit
import Combine

/// Menu bar app: owns the duck, its settings and the settings window. No Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var duck: DuckController!
    private let settings = DuckSettings()
    private var settingsWindow: SettingsWindowController!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        duck = DuckController(settings: settings)
        duck.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        duck.start()

        settingsWindow = SettingsWindowController(settings: settings, actions: .init(
            summon: { [weak self] in self?.duck.summon() },
            quack: { [weak self] in self?.duck.quackNow() },
            tryPrank: { [weak self] p in self?.duck.tryPrank(p) },
            tryFootprints: { [weak self] in self?.duck.tryFootprints() },
            putBack: { [weak self] in self?.duck.putEverythingBack() }))
        settings.strayIcons = duck.iconHomes.count

        // Apply settings live as they change.
        settings.$theme.dropFirst().sink { [weak self] t in self?.duck.setTheme(DuckTheme.all[t]) }.store(in: &subscriptions)
        settings.$size.dropFirst().sink { [weak self] s in self?.duck.setSize(CGFloat(s)) }.store(in: &subscriptions)
        settings.objectWillChange
            .receive(on: RunLoop.main)   // fires before the change lands; apply on the next turn
            .sink { [weak self] in self?.duck.applySettings() }
            .store(in: &subscriptions)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Desk Duck")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // First launch: show settings so the permissions are explained before macOS asks for them.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            settingsWindow.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
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
        let mute = item("Mute", #selector(toggleMute))
        mute.state = settings.muted ? .on : .off
        m.addItem(mute)
        m.addItem(.separator())
        m.addItem(sizeMenuItem())
        m.addItem(.separator())
        let moods = NSMenu()
        let current = settings.currentPreset?.name
        for (i, p) in PersonalityPreset.all.enumerated() {
            let it = item(p.name, #selector(pickPreset(_:)))
            it.tag = i
            it.state = p.name == current ? .on : .off
            it.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)
            it.toolTip = p.blurb
            moods.addItem(it)
        }
        if current == nil {
            moods.addItem(.separator())
            let custom = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            moods.addItem(custom)
        }
        let moodItem = NSMenuItem(title: "Personality", action: nil, keyEquivalent: "")
        moodItem.submenu = moods
        m.addItem(moodItem)
        let mischief = NSMenu()
        for p in Prank.allCases {
            let it = item(p.title, #selector(tryPrank(_:)))
            it.representedObject = p.rawValue
            mischief.addItem(it)
        }
        mischief.addItem(item("Muddy Footprints", #selector(tryFootprints)))
        let mischiefItem = NSMenuItem(title: "Make Mischief", action: nil, keyEquivalent: "")
        mischiefItem.submenu = mischief
        m.addItem(mischiefItem)
        let back = item(settings.strayIcons > 0 ? "Put Everything Back (\(settings.strayIcons))" : "Put Everything Back",
                        #selector(putBack))
        back.isEnabled = settings.strayIcons > 0
        m.addItem(back)
        m.addItem(.separator())
        let s = item("Settings…", #selector(openSettings))
        s.keyEquivalent = ","
        m.addItem(s)
        m.addItem(.separator())
        m.addItem(item("Quit Desk Duck", #selector(quit)))
        return m
    }

    /// A live size slider right in the menu.
    private func sizeMenuItem() -> NSMenuItem {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let label = NSTextField(labelWithString: "Size  \(settings.sizeLabel)")
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 25, width: 200, height: 16)
        label.tag = 1
        let slider = NSSlider(value: settings.sizeSlider, minValue: 0, maxValue: 1,
                              target: self, action: #selector(sizeSliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 4, width: 206, height: 20)
        box.addSubview(label)
        box.addSubview(slider)
        let it = NSMenuItem()
        it.view = box
        return it
    }

    @objc private func sizeSliderChanged(_ s: NSSlider) {
        settings.sizeSlider = s.doubleValue
        (s.superview?.viewWithTag(1) as? NSTextField)?.stringValue = "Size  \(settings.sizeLabel)"
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func quack() { duck.quackNow() }
    @objc private func summon() { duck.summon() }
    @objc private func toggleHidden() { duck.setHidden(!duck.isHidden) }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func toggleMute() { settings.muted.toggle() }
    @objc private func pickPreset(_ s: NSMenuItem) { settings.apply(PersonalityPreset.all[s.tag]) }
    @objc private func tryPrank(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let p = Prank(rawValue: raw) { duck.tryPrank(p) }
    }
    @objc private func tryFootprints() { duck.tryFootprints() }
    @objc private func putBack() { duck.putEverythingBack() }
    @objc private func quit() { NSApp.terminate(nil) }
}
