import Foundation

struct ScreenLayout {
    var frame: CGRect
    var topInset: Double
    var workArea: CGRect? = nil

    var menuBarRegion: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(frame.height, max(0, topInset)))
    }

    func spansWidth(_ window: CGRect) -> Bool {
        abs(window.minX - frame.minX) <= 2 && abs(window.maxX - frame.maxX) <= 2
    }

    func fillsWorkArea(_ window: CGRect) -> Bool {
        guard let area = workArea, !area.isEmpty else { return false }
        return abs(window.minX - area.minX) <= 2
            && abs(window.maxX - area.maxX) <= 2
            && abs(window.minY - area.minY) <= 2
            && abs(window.maxY - area.maxY) <= 2
    }

    func isSlidingFullscreen(_ window: CGRect) -> Bool {
        let offset = frame.minX - window.minX
        guard abs(offset) > 2, abs(offset) <= frame.width + 100 else { return false }
        return isEdgeToEdge(window.offsetBy(dx: offset, dy: 0))
    }

    func isEdgeToEdge(_ window: CGRect) -> Bool {
        let tolerance = 2.0
        // A notched Mac's fullscreen content starts below its menu/camera strip.
        // Compare the side and bottom edges, allowing that known top inset only.
        return abs(window.minX - frame.minX) <= tolerance
            && abs(window.maxX - frame.maxX) <= tolerance
            && abs(window.maxY - frame.maxY) <= tolerance
            && window.minY >= frame.minY - tolerance
            && window.minY <= frame.minY + topInset + tolerance
    }
}
