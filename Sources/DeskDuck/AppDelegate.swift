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
            quack: { [weak self] in self?.duck.quackNow() }))

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
        m.addItem(.separator())
        m.addItem(sizeMenuItem())
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
    @objc private func quit() { NSApp.terminate(nil) }
}
