import Foundation
import CoreGraphics

/// A closed coat of snow along the top edge, offset along the edge normals.
/// At the vertical tangents gravity reduces the coat to zero, joining the
/// snow back to the window instead of cutting off a rectangular column.
struct SnowContour {
    let base: [CGPoint]
    let outer: [CGPoint]
    let capInner: [CGPoint]
    let bodyPath: CGPath
    let capPath: CGPath
    private let startX: Double
    private let topSamples: [Double]

    init(_ drift: Drift) {
        let rect = drift.window.rect
        let radius = min(max(0, drift.window.cornerRadius), min(rect.width, rect.height) / 2)
        var contacts: [(CGPoint, CGVector)] = []
        let arcSegments = max(8, Int(ceil((radius + (drift.heights.max() ?? 0)) * .pi)))
        if radius > 0 {
            let segments = arcSegments
            for i in 0...segments {
                let angle = Double.pi + Double(i) / Double(segments) * .pi / 2
                let normal = CGVector(dx: cos(angle), dy: sin(angle))
                contacts.append((CGPoint(x: rect.minX + radius + radius * normal.dx,
                    y: rect.minY + radius + radius * normal.dy), normal))
            }
        }
        let flatStart = rect.minX + radius, flatEnd = rect.maxX - radius
        let flatSegments = max(1, Int(ceil((flatEnd - flatStart) / 2)))
        for i in 0...flatSegments {
            contacts.append((CGPoint(x: flatStart + (flatEnd - flatStart) * Double(i) / Double(flatSegments), y: rect.minY), CGVector(dx: 0, dy: -1)))
        }
        if radius > 0 {
            let segments = arcSegments
            for i in 0...segments {
                let angle = 1.5 * Double.pi + Double(i) / Double(segments) * .pi / 2
                let normal = CGVector(dx: cos(angle), dy: sin(angle))
                contacts.append((CGPoint(x: rect.maxX - radius + radius * normal.dx,
                    y: rect.minY + radius + radius * normal.dy), normal))
            }
        }
        var base: [CGPoint] = [], outer: [CGPoint] = [], inner: [CGPoint] = []
        for (point, _) in contacts {
            let depth = floor(min(drift.height(at: point.x), drift.capacity(at: point.x)) / 2) * 2
            let support = drift.window.snowSupport(at: point.x)
            let thickness = depth * support
            base.append(point)
            outer.append(CGPoint(x: point.x, y: point.y - thickness))
            let innerThickness = max(0, depth - 3) * support
            inner.append(CGPoint(x: point.x, y: point.y - innerThickness))
        }
        // Snap the shared endpoints exactly; trigonometric epsilon must not leave slivers.
        if radius > 0 {
            outer[0] = base[0]; inner[0] = base[0]
            outer[outer.count - 1] = base[base.count - 1]
            inner[inner.count - 1] = base[base.count - 1]
        }
        func polygon(_ upper: [CGPoint], _ lower: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: upper + lower.reversed())
            path.closeSubpath()
            return path
        }
        self.base = base; self.outer = outer; capInner = inner
        bodyPath = polygon(outer, base); capPath = polygon(outer, inner)
        let origin = floor(outer.map(\.x).min() ?? rect.minX)
        let end = ceil(outer.map(\.x).max() ?? rect.maxX)
        var samples = Array(repeating: Double.infinity, count: max(2, Int(end - origin) + 1))
        for (a, b) in zip(outer, outer.dropFirst()) {
            let lower = max(0, Int(ceil(min(a.x, b.x) - origin)))
            let upper = min(samples.count - 1, Int(floor(max(a.x, b.x) - origin)))
            guard lower <= upper else { continue }
            for index in lower...upper {
                let y: Double
                if abs(b.x - a.x) < 0.000001 { y = min(a.y, b.y) }
                else { y = a.y + (b.y - a.y) * (origin + Double(index) - a.x) / (b.x - a.x) }
                samples[index] = min(samples[index], y)
            }
        }
        startX = origin; topSamples = samples
    }
    func top(at x: Double) -> Double? {
        let position = x - startX
        guard position >= 0, position <= Double(topSamples.count - 1) else { return nil }
        let i = Int(position), j = min(i + 1, topSamples.count - 1)
        let a = topSamples[i], b = topSamples[j]
        if !a.isFinite { return b.isFinite ? b : nil }
        if !b.isFinite { return a }
        return a + (b - a) * (position - Double(i))
    }
}
