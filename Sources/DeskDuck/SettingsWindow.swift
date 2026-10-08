import AppKit
import SwiftUI

/// Hosts the SwiftUI settings in a normal window. The app is menu-bar only, so it has to activate itself to show it.
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: DuckSettings
    private let actions: SettingsView.Actions

    init(settings: DuckSettings, actions: SettingsView.Actions) {
        self.settings = settings
        self.actions = actions
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, actions: actions))
            let w = NSWindow(contentViewController: host)
            w.title = "Desk Duck"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 720))
            w.minSize = NSSize(width: 480, height: 420)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    struct Actions {
        var summon: () -> Void
        var quack: () -> Void
        var tryPrank: (Prank) -> Void
        var tryFootprints: () -> Void
        var putBack: () -> Void
    }

    @ObservedObject var settings: DuckSettings
    let actions: Actions

    @State private var finder: PermissionStatus = .unavailable
    @State private var accessibility: PermissionStatus = Permissions.accessibility
    @State private var confirmReset = false
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            permissionsSection
            placesSection
            personalitySection
            mischiefSection
            lookSection
            HStack {
                Button("Summon to Cursor", action: actions.summon)
                Button("Quack!", action: actions.quack)
                Spacer()
                Button("Reset All to Defaults…") { confirmReset = true }
            }
        }
        .confirmationDialog("Reset all Desk Duck settings?", isPresented: $confirmReset) {
            Button("Reset All", role: .destructive) { settings.resetAll() }
        } message: {
            Text("Personality, where the duck can go, color, size and sound go back to their defaults. Permissions aren't changed.")
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        accessibility = Permissions.accessibility
        Permissions.finder(ask: false) { finder = $0 }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            PermissionRow(
                icon: "macwindow.on.rectangle",
                title: "See inside apps",
                status: accessibility,
                detail: "Lets the duck see the layout of the window you're using (where buttons, images, text "
                    + "blocks and list rows are) so it can hop around on them. It reads positions and sizes only, "
                    + "never the text, and never clicks or types anything. The only exception is Window bounce in "
                    + "Mischief, which nudges windows and is off unless you turn it on. macOS calls this Accessibility access, "
                    + "and it technically allows much more than that, which is why macOS asks you first.",
                buttonTitle: accessibility == .granted ? "Open Settings" : "Allow…",
                action: {
                    if accessibility == .granted { Permissions.openPrivacyPane("Privacy_Accessibility") }
                    else { Permissions.requestAccessibility() }
                })
            PermissionRow(
                icon: "folder",
                title: "Desktop icons",
                status: finder,
                detail: "Lets the duck ask Finder where your desktop icons are so it can stand on them and, if you "
                    + "allow it below, slide them to a new spot while it surfs. It can't open, rename or delete "
                    + "anything. macOS calls this Automation access to Finder.",
                buttonTitle: finder == .notAsked ? "Allow…" : "Open Settings",
                action: {
                    if finder == .notAsked { Permissions.finder(ask: true) { finder = $0 } }
                    else { Permissions.openPrivacyPane("Privacy_Automation") }
                })
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window edges, menu bars and screen edges")
                    Text("Always available, no permission needed.").font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Everything stays on your Mac. Change these any time in System Settings › Privacy & Security.")
        }
    }

    // MARK: Where it can go

    private var placesSection: some View {
        Section("Where the duck can go") {
            Toggle(isOn: $settings.useAppContent) {
                SettingText("Buttons, images and text inside apps", "Needs \"See inside apps\".")
            }
            Toggle(isOn: $settings.wakeWebContent) {
                SettingText("Also look inside Chrome and Electron apps",
                            "Apps like Chrome, Arc, Slack, VS Code and Discord hide their page contents until asked. "
                            + "Turning this on asks them to share it, which can make those apps a little slower.")
            }
            .disabled(!settings.useAppContent)
            Toggle(isOn: $settings.useWindowTops) { SettingText("Tops of windows", nil) }
            Toggle(isOn: $settings.useIcons) { SettingText("Desktop icons", "Needs \"Desktop icons\".") }
            Toggle(isOn: $settings.moveIcons) {
                SettingText("Let it surf icons to new spots", "It rides an icon and slides it somewhere nearby.")
            }
            .disabled(!settings.useIcons)
            SliderRow("How often it surfs", value: $settings.surfing, low: "Rarely", high: "Often")
                .disabled(!settings.useIcons || !settings.moveIcons)
        }
    }

    // MARK: Personality

    private var personalitySection: some View {
        Section {
            SliderRow("Energy", value: $settings.energy, low: "Chill", high: "Hyper")
            SliderRow("Wanderlust", value: $settings.wanderlust, low: "Homebody", high: "Explorer")
            SliderRow("Walking speed", value: $settings.walkSpeed, range: 0.5...2, low: "Slow", high: "Fast")
            SliderRow("Jumpiness", value: $settings.jumpiness, low: "Grounded", high: "Bouncy")
            SliderRow("Rocket jumps", value: $settings.rockets, low: "Never", high: "Often")
            SliderRow("Hanging upside down", value: $settings.hanging, low: "Never", high: "Bat mode")
            SliderRow("Naps", value: $settings.naps, low: "Rarely", high: "Sleepyhead")
            SliderRow("Curiosity about your cursor", value: $settings.curiosity, low: "Ignores it", high: "Obsessed")
        } header: {
            HStack {
                Text("Personality")
                Spacer()
                Button("Reset") { settings.resetPersonality() }.buttonStyle(.link).font(.caption)
            }
        }
    }

    // MARK: Mischief

    private var mischiefSection: some View {
        Section {
            SliderRow("How often", value: $settings.mischief, low: "Angel", high: "Gremlin")
            PrankToggle(isOn: $settings.iconHeist, title: "Icon heists",
                        detail: "Grabs desktop icons in its bill and hides one behind the Dock or a window, piles a few up, "
                            + "lines them up, or stacks them into a tower and stands on top.",
                        tryIt: { actions.tryPrank(.iconHeist) })
            PrankToggle(isOn: $settings.buttonSquat, title: "Button squatting",
                        detail: "Sits smugly on a button in the app you're using. It never presses it, and it scrambles "
                            + "off the moment your cursor gets close. Needs \"See inside apps\".",
                        tryIt: { actions.tryPrank(.buttonSquat) })
            PrankToggle(isOn: $settings.cursorHeist, title: "Cursor heists",
                        detail: "Only after you've left the mouse alone for a while: it bites the cursor and carries it "
                            + "somewhere silly, like the notch. Touch the mouse and it lets go instantly.",
                        tryIt: { actions.tryPrank(.cursorHeist) })
            PrankToggle(isOn: $settings.hideAndSeek, title: "Hide and seek",
                        detail: "Tucks itself just off the edge of a screen and peeks out now and then. "
                            + "Click it when you spot it.",
                        tryIt: { actions.tryPrank(.hideAndSeek) })
            PrankToggle(isOn: $settings.footprints, title: "Muddy footprints",
                        detail: "After a big landing it tracks little footprints across your windows. They fade away "
                            + "on their own after about a minute.",
                        tryIt: actions.tryFootprints)
            PrankToggle(isOn: $settings.caughtRedHanded, title: "Caught red-handed",
                        detail: "Hover over it right after it's been up to something: it freezes, slowly turns to look "
                            + "at you, and whistles innocently.",
                        tryIt: nil)
            PrankToggle(isOn: $settings.windowBounce, title: "Window bouncing",
                        detail: "Bounces on top of a window, which bobs a few pixels with each landing and always settles "
                            + "back exactly where it was. This moves other apps' windows, so it's off unless you turn it on. "
                            + "Needs \"See inside apps\".",
                        tryIt: { actions.tryPrank(.windowBounce) })
            HStack {
                Image(systemName: settings.strayIcons > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(settings.strayIcons > 0 ? .orange : .green)
                Text(settings.strayIcons > 0
                     ? "\(settings.strayIcons) icon\(settings.strayIcons == 1 ? " has" : "s have") wandered off"
                     : "All your desktop icons are home")
                Spacer()
                Button("Put Everything Back", action: actions.putBack).disabled(settings.strayIcons == 0)
            }
        } header: {
            Text("Mischief")
        } footer: {
            Text("Mischief is always undoable and never touches what's inside your apps. "
                 + "\"Try\" does it right away, even if it's switched off.")
        }
    }

    // MARK: Look & sound

    private var lookSection: some View {
        Section("Look & sound") {
            Picker("Color", selection: $settings.theme) {
                ForEach(DuckTheme.all.indices, id: \.self) { i in
                    HStack {
                        Circle().fill(Color(nsColor: DuckTheme.all[i].shell)).frame(width: 10, height: 10)
                        Text(DuckTheme.all[i].name)
                    }.tag(i)
                }
            }
            SliderRow("Size", value: $settings.sizeSlider, low: "Tiny", high: "Kaiju", valueText: settings.sizeLabel)
            Toggle("Mute", isOn: $settings.muted)
            SliderRow("Volume", value: $settings.volume, low: "Quiet", high: "Loud").disabled(settings.muted)
        }
    }
}

private struct PrankToggle: View {
    @Binding var isOn: Bool
    let title: String
    let detail: String
    let tryIt: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Toggle(isOn: $isOn) { SettingText(title, detail) }
            if let tryIt {
                Button("Try", action: tryIt).controlSize(.small)
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let status: PermissionStatus
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    StatusBadge(status: status)
                    Spacer()
                    Button(buttonTitle, action: action)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatusBadge: View {
    let status: PermissionStatus
    var body: some View {
        let color: Color = switch status {
        case .granted: .green
        case .denied: .red
        case .notAsked: .orange
        case .unavailable: .gray
        }
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct SettingText: View {
    let title: String
    let detail: String?
    init(_ title: String, _ detail: String?) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let low: String
    let high: String
    var valueText: String? = nil

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, low: String, high: String,
         valueText: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.low = low
        self.high = high
        self.valueText = valueText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                if let valueText { Text(valueText).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Slider(value: $value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
