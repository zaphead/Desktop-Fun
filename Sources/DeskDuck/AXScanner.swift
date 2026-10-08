import AppKit
import ApplicationServices

/// Reads the layout of the focused window in the frontmost app through the Accessibility API —
/// the "DOM" of native apps (and of web pages in browsers). Only roles, positions and sizes are read;
/// never text, values or titles.
final class AXScanner {
    struct Result {
        let pid: pid_t
        let elapsed: Double          // seconds the scan took
        let windowFrame: CGRect      // global, top-left origin (Quartz coords)
        let rects: [CGRect]          // element frames, same coords
    }

    var wakeWebContent = false
    private let queue = DispatchQueue(label: "duck.ax-scan", qos: .utility)
    private var busy = false
    private var wokenPIDs = Set<pid_t>()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Element roles worth standing on.
    private static let solidRoles: Set<String> = [
        "AXButton", "AXImage", "AXStaticText", "AXHeading", "AXTextField", "AXTextArea", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXCheckBox", "AXRadioButton", "AXLink", "AXRow", "AXCell",
        "AXSegmentedControl", "AXSlider", "AXProgressIndicator", "AXTabButton", "AXDisclosureTriangle",
        "AXColorWell", "AXLevelIndicator", "AXIncrementor", "AXSearchField",
    ]
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func forget(pid: pid_t) { wokenPIDs.remove(pid) }

    /// Scans asynchronously and calls back on the main queue. Skips if a scan is already running.
    func scan(completion: @escaping (Result?) -> Void) {
        guard !busy, AXScanner.isTrusted, let app = targetApp() else {
            if !busy { completion(nil) }
            return
        }
        busy = true
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? ""
        let wake = wakeWebContent && !wokenPIDs.contains(pid)
        if wake { wokenPIDs.insert(pid) }

        queue.async {
            let result = AXScanner.scanApp(pid: pid, bundle: bundle, wake: wake)
            DispatchQueue.main.async {
                self.busy = false
                completion(result)
            }
        }
    }

    /// The app you're working in. If that's Desk Duck itself (its Settings window), use the app whose
    /// window is on top underneath instead.
    private func targetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID { return front }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID {
                return NSRunningApplication(processIdentifier: pid)
            }
        }
        return nil
    }

    // MARK: Off-main work

    private static func scanApp(pid: pid_t, bundle: String, wake: Bool) -> Result? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if wake {
            // Electron apps and Chromium browsers hide their web content from Accessibility until asked.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if chromiumBrowsers.contains(bundle) {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() else { return nil }
        let window = winRef as! AXUIElement
        guard let wf = frame(of: window), wf.width > 100, wf.height > 80 else { return nil }

        var rects: [CGRect] = []
        var queueEls: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        let start = CACurrentMediaTime()
        let deadline = start + 0.12
        let attrs = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray

        while head < queueEls.count, head < 2000, CACurrentMediaTime() < deadline {
            let (el, depth) = queueEls[head]
            head += 1
            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
                  let values = valuesRef as? [AnyObject], values.count == 4 else { continue }
            let role = values[0] as? String ?? ""
            let rect = rectFrom(position: values[1], size: values[2])

            if let r = rect, depth > 0 {
                // Prune subtrees that are entirely outside the window (e.g. scrolled-off web content).
                if r.width > 0 && r.height > 0 && !r.intersects(wf) { continue }
                if solidRoles.contains(role), r.width >= 30, r.height >= 12, r.height <= 420,
                   r.width <= wf.width * 0.97, wf.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.minY + 1)) {
                    rects.append(r)
                }
            }
            if depth < 60, let kids = values[3] as? [AXUIElement] {
                for k in kids.prefix(400) { queueEls.append((k, depth + 1)) }
            }
        }
        return Result(pid: pid, elapsed: CACurrentMediaTime() - start, windowFrame: wf, rects: rects)
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s)
        return rectFrom(position: p, size: s)
    }

    private static func rectFrom(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &pt),
              AXValueGetValue(size as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}
