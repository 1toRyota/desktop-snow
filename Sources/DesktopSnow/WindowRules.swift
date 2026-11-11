import Foundation

/// Keep system-hosted desktop widgets separate from normal application windows
/// and from Notification Center's transparent full-display helper canvas.
enum WindowRules {
    static func isCleanMyMac(bundleID: String?, owner: String) -> Bool {
        let bundle = (bundleID ?? "").lowercased()
        if bundle.hasPrefix("com.macpaw.cleanmymac") { return true }
        let name = owner.lowercased().filter { $0.isLetter || $0.isNumber }
        return name.hasPrefix("cleanmymac")
    }
    static func isNotificationCenter(bundleID: String?, owner: String) -> Bool {
        bundleID?.lowercased() == "com.apple.notificationcenterui"
            || owner.lowercased().replacingOccurrences(of: " ", with: "") == "notificationcenter"
    }
    static func isDesktopWidget(bundleID: String?, owner: String, layer: Int, rect: CGRect, screens: [CGRect]) -> Bool {
        guard layer < 0, isNotificationCenter(bundleID: bundleID, owner: owner), rect.width >= 100, rect.height >= 80 else { return false }
        return screens.contains { screen in
            screen.intersects(rect) && rect.width < screen.width * 0.85 && rect.height < screen.height * 0.85
        }
    }
    static func widgetSurface(id: UInt32, container: CGRect) -> SnowWindow {
        // The observed desktop widget containers include an 8-point transparent
        // margin around the visible card (180pt container -> 164pt card).
        let inset = min(8.0, min(container.width, container.height) / 10)
        let card = container.insetBy(dx: inset, dy: inset)
        return SnowWindow(id: id, rect: card, cornerRadius: min(34, min(card.width, card.height) * 0.2), isWidget: true)
    }
}
