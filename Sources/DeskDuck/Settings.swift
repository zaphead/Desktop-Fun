import AppKit
import ApplicationServices
import Combine

/// Everything the user can tweak, persisted to UserDefaults. Personality sliders are 0...1 with 0.5 as "normal".
final class DuckSettings: ObservableObject {
    private let d = UserDefaults.standard

    // Look & sound
    @Published var theme: Int { didSet { d.set(theme, forKey: "theme") } }
    @Published var size: Double { didSet { d.set(size, forKey: "size") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var muted: Bool { didSet { d.set(muted, forKey: "muted") } }

    // Where the duck can go
    @Published var useIcons: Bool { didSet { d.set(useIcons, forKey: "useIcons") } }
    @Published var useWindowTops: Bool { didSet { d.set(useWindowTops, forKey: "useWindowTops") } }
    @Published var useAppContent: Bool { didSet { d.set(useAppContent, forKey: "useAppContent") } }
    @Published var wakeWebContent: Bool { didSet { d.set(wakeWebContent, forKey: "wakeWebContent") } }
    @Published var moveIcons: Bool { didSet { d.set(moveIcons, forKey: "moveIcons") } }

    // Personality
    @Published var energy: Double { didSet { d.set(energy, forKey: "energy") } }
    @Published var wanderlust: Double { didSet { d.set(wanderlust, forKey: "wanderlust") } }
    @Published var walkSpeed: Double { didSet { d.set(walkSpeed, forKey: "walkSpeed") } }
    @Published var jumpiness: Double { didSet { d.set(jumpiness, forKey: "jumpiness") } }
    @Published var rockets: Double { didSet { d.set(rockets, forKey: "rockets") } }
    @Published var hanging: Double { didSet { d.set(hanging, forKey: "hanging") } }
    @Published var naps: Double { didSet { d.set(naps, forKey: "naps") } }
    @Published var curiosity: Double { didSet { d.set(curiosity, forKey: "curiosity") } }
    @Published var surfing: Double { didSet { d.set(surfing, forKey: "surfing") } }

    // Mischief
    @Published var mischief: Double { didSet { d.set(mischief, forKey: "mischief") } }
    @Published var iconHeist: Bool { didSet { d.set(iconHeist, forKey: "iconHeist") } }
    @Published var buttonSquat: Bool { didSet { d.set(buttonSquat, forKey: "buttonSquat") } }
    @Published var cursorHeist: Bool { didSet { d.set(cursorHeist, forKey: "cursorHeist") } }
    @Published var hideAndSeek: Bool { didSet { d.set(hideAndSeek, forKey: "hideAndSeek") } }
    @Published var footprints: Bool { didSet { d.set(footprints, forKey: "footprints") } }
    @Published var caughtRedHanded: Bool { didSet { d.set(caughtRedHanded, forKey: "caughtRedHanded") } }
    @Published var windowBounce: Bool { didSet { d.set(windowBounce, forKey: "windowBounce") } }
    /// How many desktop icons the duck has moved away from home (not persisted here; the duck keeps the list).
    @Published var strayIcons = 0

    // Size runs from 0.4x to a comical 6x on a log scale, so the everyday range gets most of the slider.
    static let minSize = 0.4, maxSize = 6.0
    static func size(fromSlider t: Double) -> Double { minSize * pow(maxSize / minSize, min(max(t, 0), 1)) }
    static func slider(fromSize s: Double) -> Double { log(s / minSize) / log(maxSize / minSize) }

    /// 0...1 slider position for `size`.
    var sizeSlider: Double {
        get { DuckSettings.slider(fromSize: size) }
        set { size = (DuckSettings.size(fromSlider: newValue) * 100).rounded() / 100 }
    }

    var sizeLabel: String { size >= 2.95 ? String(format: "%.1f× 🦖", size) : String(format: "%.1f×", size) }

    static let personalityDefaults: [String: Any] = [
        "energy": 0.5, "wanderlust": 0.5, "walkSpeed": 1.0, "jumpiness": 0.5, "rockets": 0.5,
        "hanging": 0.5, "naps": 0.5, "curiosity": 0.5, "surfing": 0.5,
    ]

    init() {
        d.register(defaults: DuckSettings.personalityDefaults.merging([
            "theme": 0, "size": 1.0, "volume": 0.7, "muted": false,
            "useIcons": true, "useWindowTops": true, "useAppContent": true, "wakeWebContent": false, "moveIcons": true,
            "mischief": 0.5, "iconHeist": true, "buttonSquat": true, "cursorHeist": true, "hideAndSeek": true,
            "footprints": true, "caughtRedHanded": true, "windowBounce": false,
        ]) { a, _ in a })
        theme = min(max(d.integer(forKey: "theme"), 0), DuckTheme.all.count - 1)
        size = min(max(d.double(forKey: "size"), DuckSettings.minSize), DuckSettings.maxSize)
        volume = d.double(forKey: "volume")
        muted = d.bool(forKey: "muted")
        useIcons = d.bool(forKey: "useIcons")
        useWindowTops = d.bool(forKey: "useWindowTops")
        useAppContent = d.bool(forKey: "useAppContent")
        wakeWebContent = d.bool(forKey: "wakeWebContent")
        moveIcons = d.bool(forKey: "moveIcons")
        energy = d.double(forKey: "energy")
        wanderlust = d.double(forKey: "wanderlust")
        walkSpeed = d.double(forKey: "walkSpeed")
        jumpiness = d.double(forKey: "jumpiness")
        rockets = d.double(forKey: "rockets")
        hanging = d.double(forKey: "hanging")
        naps = d.double(forKey: "naps")
        curiosity = d.double(forKey: "curiosity")
        surfing = d.double(forKey: "surfing")
        mischief = d.double(forKey: "mischief")
        iconHeist = d.bool(forKey: "iconHeist")
        buttonSquat = d.bool(forKey: "buttonSquat")
        cursorHeist = d.bool(forKey: "cursorHeist")
        hideAndSeek = d.bool(forKey: "hideAndSeek")
        footprints = d.bool(forKey: "footprints")
        caughtRedHanded = d.bool(forKey: "caughtRedHanded")
        windowBounce = d.bool(forKey: "windowBounce")
    }

    /// Everything back to how it shipped (permissions live in System Settings and aren't touched).
    func resetAll() {
        resetPersonality()
        theme = 0; size = 1.0; volume = 0.7; muted = false
        useIcons = true; useWindowTops = true; useAppContent = true; wakeWebContent = false; moveIcons = true
        mischief = 0.5; iconHeist = true; buttonSquat = true; cursorHeist = true; hideAndSeek = true
        footprints = true; caughtRedHanded = true; windowBounce = false
    }

    func resetPersonality() {
        energy = 0.5; wanderlust = 0.5; walkSpeed = 1.0; jumpiness = 0.5; rockets = 0.5
        hanging = 0.5; naps = 0.5; curiosity = 0.5; surfing = 0.5
    }
}

/// Status of the two macOS permissions the duck can use.
enum PermissionStatus {
    case granted, denied, notAsked, unavailable

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notAsked: "Not set up"
        case .unavailable: "Unavailable"
        }
    }
}

enum Permissions {
    // Accessibility: lets the duck see where things are inside other apps' windows.
    static var accessibility: PermissionStatus { AXIsProcessTrusted() ? .granted : .notAsked }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    // Automation of Finder: lets the duck see (and optionally move) desktop icons.
    static func finder(ask: Bool, completion: @escaping (PermissionStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
            let result: PermissionStatus
            switch status {
            case noErr: result = .granted
            case OSStatus(errAEEventNotPermitted): result = .denied
            case OSStatus(errAEEventWouldRequireUserConsent): result = .notAsked
            default: result = .unavailable
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
