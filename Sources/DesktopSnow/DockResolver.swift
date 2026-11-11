import AppKit
import ApplicationServices

struct DockResolution {
    var shelf: CGRect
    var source: String
    var estimated: Bool
}

final class DockResolver {
    var lastAXNote = "not checked"
    var axReportsHidden = false
    var cached: DockResolution?
    var lastCheck = -Double.infinity

    func resolve(cgContainer: CGRect?, allWindows: [[String: Any]]) -> DockResolution? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCheck < 0.2 { return cached }
        lastCheck = now
        if let rect = accessibleShelf() {
            cached = DockResolution(shelf: rect, source: "AX", estimated: false)
        } else if let rect = cgContainer {
            cached = DockResolution(shelf: rect, source: "CG", estimated: false)
        } else if axReportsHidden {
            cached = nil
        } else {
            cached = estimateShelf(allWindows: allWindows)
        }
        return cached
    }
    func accessibleShelf() -> CGRect? {
        axReportsHidden = false
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { lastAXNote = "Dock process missing"; return nil }
        var notes: [String] = ["trusted=\(AXIsProcessTrusted())"]
        defer { lastAXNote = notes.joined(separator: "; ") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            guard error == .success else { notes.append("\(attribute): \(error.rawValue)"); return nil }
            return result
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
        guard let children = value(root, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        var queue = children.map { ($0, 0) }
        var visited = 0
        while !queue.isEmpty && visited < 64 {
            let (child, depth) = queue.removeFirst(); visited += 1
            let role = value(child, kAXRoleAttribute) as? String ?? "?"
            if depth < 2, let nested = value(child, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: nested.map { ($0, depth + 1) })
            }
            guard role == kAXListRole else { continue }
            guard let rect = frame(child) else { notes.append("list frame unavailable"); continue }
            notes.append("list \(NSStringFromRect(rect))")
            guard rect.width > 30, rect.height > 20 else { continue }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            guard NSScreen.screens.contains(where: { screen in
                CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height).intersects(rect)
            }) else { axReportsHidden = true; continue }
            return rect
        }
        return nil
    }
    func estimateShelf(allWindows: [[String: Any]]) -> DockResolution? {
        guard let prefs = UserDefaults(suiteName: "com.apple.dock") else { return nil }
        let orientation = prefs.string(forKey: "orientation") ?? "bottom"
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let tile = max(16, prefs.double(forKey: "tilesize") == 0 ? 48 : prefs.double(forKey: "tilesize"))
        let persistent = prefs.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let others = prefs.array(forKey: "persistent-others")?.count ?? 0
        let persistentIDs = Set(persistent.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String })
        let transient = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !persistentIDs.contains($0.bundleIdentifier ?? "")
        }.count
        // Public preferences do not expose minimized Dock tiles. This is explicitly a fallback.
        let count = max(3, persistent.count + others + transient + 1)
        for screen in NSScreen.screens {
            let frame = screen.frame, visible = screen.visibleFrame
            let reserved: Double
            if orientation == "left" { reserved = visible.minX - frame.minX }
            else if orientation == "right" { reserved = frame.maxX - visible.maxX }
            else { reserved = visible.minY - frame.minY }
            // An auto-hidden Dock without public geometry must not become an invisible shelf.
            guard reserved > 8 else { continue }
            let length = min((orientation == "bottom" ? frame.width : frame.height) - 16, Double(count) * tile + 20)
            let thickness = max(20, reserved - 6)
            let rect: CGRect
            if orientation == "left" {
                rect = CGRect(x: frame.minX + 3, y: primaryTop - frame.midY - length / 2, width: thickness, height: length)
            } else if orientation == "right" {
                rect = CGRect(x: frame.maxX - thickness - 3, y: primaryTop - frame.midY - length / 2, width: thickness, height: length)
            } else {
                rect = CGRect(x: frame.midX - length / 2, y: primaryTop - frame.minY - reserved + 3, width: length, height: thickness)
            }
            return DockResolution(shelf: rect, source: "estimated", estimated: true)
        }
        return nil
    }
}
