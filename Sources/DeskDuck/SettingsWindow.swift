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
                    + "never the text, and never clicks or types anything. macOS calls this Accessibility access, "
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
