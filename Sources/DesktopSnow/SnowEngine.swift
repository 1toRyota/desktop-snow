import Foundation

struct SnowWindow {
    let id: UInt32
    var rect: CGRect
    var isDock = false
    var cornerRadius = 0.0
    var collectsSnow = true
    var blocksFlakes = false
    var isFullscreen = false
    var isWidget = false
    var isFill = false
    var ownerPID: Int32? = nil
    var accumulationExcluded = false

    // Quartz rectangles include the transparent margin around the Dock shelf.
    static func dock(id: UInt32, container: CGRect, inset: Double = 6) -> SnowWindow {
        let padding = min(max(0, inset), container.height / 4)
        let shelf = CGRect(x: container.minX, y: container.minY + padding,
                           width: container.width, height: max(1, container.height - padding))
        return SnowWindow(id: id, rect: shelf, isDock: true,
                          cornerRadius: min(18, min(shelf.width, shelf.height) * 0.26))
    }
    func contains(_ point: CGPoint) -> Bool {
        guard rect.contains(point) else { return false }
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        guard r > 0 else { return true }
        let cx = min(max(point.x, rect.minX + r), rect.maxX - r)
        let cy = min(max(point.y, rect.minY + r), rect.maxY - r)
        return pow(point.x - cx, 2) + pow(point.y - cy, 2) <= r * r
    }
    func snowSupport(at x: Double) -> Double {
        guard x >= rect.minX && x <= rect.maxX else { return 0 }
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        guard r > 0 else { return 1 }
        let edgeDistance = min(x - rect.minX, rect.maxX - x)
        let horizontalNormal = max(0, 1 - edgeDistance / r)
        let upwardNormal = sqrt(max(0, 1 - horizontalNormal * horizontalNormal))
        let t = max(0, min(1, (upwardNormal - sqrt(0.5)) / (0.95 - sqrt(0.5))))
        return t * t * (3 - 2 * t)
    }
    func surfaceY(at x: Double) -> Double {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        guard r > 0 else { return rect.minY }
        let edgeDistance = min(max(0, x - rect.minX), max(0, rect.maxX - x))
        guard edgeDistance < r else { return rect.minY }
        return rect.minY + r - sqrt(max(0, r * r - pow(r - edgeDistance, 2)))
    }
}
struct Flake {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var radius: Double
    var phase: Double
    var opacity: Double
    var ignoredSurface: UInt32? = nil
    var gravity = 0.0
    var entersFullscreen = false
}
enum Movement: Int { case shed, follow, clear }
final class Drift {
    var window: SnowWindow
    var heights: [Double]
    let spacing = 5.0
    var spillCredit = 0.0
    var widgetHeadroom: Double?
    private let profilePhase: Double
    init(_ window: SnowWindow) {
        self.window = window
        profilePhase = Double(window.id % 997) * 0.61803398875
        heights = Array(repeating: 0, count: max(2, Int(ceil(window.rect.width / spacing)) + 1))
    }
    func height(at x: Double) -> Double {
        let t = max(0, min(Double(heights.count - 1), (x - window.rect.minX) / spacing))
        let i = Int(t), j = min(i + 1, heights.count - 1)
        return (heights[i] * (1 - (t - Double(i))) + heights[j] * (t - Double(i)))
    }
    func capacity(at x: Double) -> Double {
        if window.isDock { return 40 }
        if window.rect.height <= 2 { return 28 }
        let localX = x - window.rect.minX
        let relief = 0.5 + 0.32 * sin(localX / 19 + profilePhase)
            + 0.18 * sin(localX / 8.5 + profilePhase * 1.7)
        if let headroom = widgetHeadroom {
            return min(14 + 14 * relief, headroom * (0.55 + 0.37 * relief))
        }
        return 14 + 14 * relief
    }
    func deposit(at x: Double, amount: Double) {
        let center = max(0, min(heights.count - 1, Int((x - window.rect.minX) / spacing)))
        for i in max(0, center - 3)...min(heights.count - 1, max(0, center + 3)) {
            guard window.snowSupport(at: min(window.rect.maxX, window.rect.minX + Double(i) * spacing)) > 0 else { continue }
            let distance = Double(i - center)
            heights[i] = min(capacity(at: window.rect.minX + Double(i) * spacing), heights[i] + amount * exp(-distance * distance / 3.5))
        }
    }
}
final class SnowEngine {
    var flakes: [Flake] = []
    var drifts: [UInt32: Drift] = [:]
    var windows: [SnowWindow] = [] // Front to back, Quartz coordinates (y points down).
    var screens: [CGRect] = []
    // Protect the Dock even when its AX/CG geometry is unavailable.
    var dockProtection: [SnowWindow] = []
    var fullscreenRegions: [CGRect] = []
    var menuBarRegions: [CGRect] = []
    var fillRegions: [CGRect] = []
    var sideFilteredRegions: [CGRect] = []
    var spawnSerial = 0
    var topAdmissionSerial = 0
    var intensity = 0.65
    var wind = 12.0
    var movement: Movement = .shed
    var accumulation = true
    var meltRate = 0.22
    var time = 0.0
    var topCredits: [Int: Double] = [:]
    var sideCredits: [Int: Double] = [:]
    var sideSpawnCount = 0
    var activeIDs: Set<UInt32> = []
    let groundBase: UInt32 = 0xF0000000
    var groundIDs: Set<UInt32> = []

    func setScreens(_ rects: [CGRect]) {
        guard screens != rects else { return }
        let oldGround = groundIDs.sorted().compactMap { drifts[$0] }
        screens = rects
        flakes = flakes.filter { flake in rects.contains { $0.insetBy(dx: -100, dy: -100).contains(CGPoint(x: flake.x, y: flake.y)) } }
        topCredits.removeAll(); sideCredits.removeAll()
        for id in groundIDs { drifts.removeValue(forKey: id) }
        groundIDs.removeAll()
        for (index, rect) in rects.enumerated() {
            let id = groundBase + UInt32(index)
            groundIDs.insert(id)
            let drift = Drift(SnowWindow(id: id, rect: CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)))
            if index < oldGround.count {
                let old = oldGround[index].heights
                drift.heights = drift.heights.indices.map { old[min($0, old.count - 1)] }
            }
            drifts[id] = drift
        }
        activeIDs.formUnion(groundIDs)
    }
    func sync(_ incoming: [SnowWindow], existingIDs: Set<UInt32>? = nil, shedOnChange: Bool = true, preserveMissing: Bool = false) {
        let previouslyVisible = activeIDs
        let incomingIDs = Set(incoming.map(\.id))
        let ids = (existingIDs ?? incomingIDs).union(incomingIDs).union(groundIDs)
        activeIDs = Set(incoming.filter(\.collectsSnow).map(\.id)).union(groundIDs)
        // Widget windows can be recreated by Notification Center when the desktop returns.
        for widget in incoming where widget.isWidget && drifts[widget.id] == nil {
            if let previous = drifts.first(where: { id, drift in
                !ids.contains(id) && drift.window.isWidget && drift.window.rect == widget.rect
            }) {
                drifts.removeValue(forKey: previous.key)
                previous.value.window = widget
                drifts[widget.id] = previous.value
            }
        }
        // A window can return from a Space with a new compositor ID.
        // Match only an unambiguous window of the same process and desktop geometry.
        for window in incoming where preserveMissing && window.collectsSnow && !window.isWidget && drifts[window.id] == nil {
            guard let owner = window.ownerPID else { continue }
            let matchingWindows = incoming.filter { $0.collectsSnow && $0.ownerPID == owner && $0.rect == window.rect }
            guard matchingWindows.count == 1 else { continue }
            let candidates = drifts.filter { id, drift in
                !incomingIDs.contains(id) && drift.window.ownerPID == owner && drift.window.rect == window.rect
            }
            guard candidates.count == 1, let previous = candidates.first else { continue }
            drifts.removeValue(forKey: previous.key)
            previous.value.window = window
            drifts[window.id] = previous.value
        }
        for id in Array(drifts.keys) where !preserveMissing && !ids.contains(id) {
            if shedOnChange, previouslyVisible.contains(id), let drift = drifts[id] { release(drift, fraction: 1) }
            drifts.removeValue(forKey: id)
        }
        for window in incoming {
            guard window.collectsSnow else {
                if window.accumulationExcluded || (!preserveMissing && !window.isFullscreen && !window.isFill) {
                    drifts.removeValue(forKey: window.id)
                }
                continue
            }
            guard let drift = drifts[window.id] else { drifts[window.id] = Drift(window); continue }
            let dx = window.rect.minX - drift.window.rect.minX
            let dy = window.rect.minY - drift.window.rect.minY
            let resized = abs(window.rect.width - drift.window.rect.width) > 1
            if abs(dx) + abs(dy) > 0.5 || resized {
                if !shedOnChange || !previouslyVisible.contains(window.id) { /* Preserve snow while refreshing a frozen scene. */ }
                else if movement == .clear { drift.heights = drift.heights.map { _ in 0 } }
                else if movement == .shed {
                    release(drift, fraction: min(1, (hypot(dx, dy) + (resized ? 20 : 0)) / 110))
                }
                let old = drift.heights
                let count = max(2, Int(ceil(window.rect.width / drift.spacing)) + 1)
                drift.heights = (0..<count).map { old[min($0, old.count - 1)] }
            }
            drift.window = window
        }
        for widget in incoming where widget.isWidget {
            let menu = menuBarRegions.first { region in
                region.minX <= widget.rect.midX && widget.rect.midX < region.maxX
                    && widget.rect.minY >= region.minY && widget.rect.minY - region.maxY < 30
            }
            drifts[widget.id]?.widgetHeadroom = menu.map { max(0, widget.rect.minY - $0.maxY - 2) }
        }
        windows = incoming
    }
    func isActive(_ id: UInt32) -> Bool { activeIDs.contains(id) }
    func visible(x: Double, y: Double, on id: UInt32) -> Bool {
        for window in windows {
            if window.id == id { return true }
            if window.contains(CGPoint(x: x, y: y)) { return false }
        }
        return true
    }
    func updateSparseRegions(fullscreen: [CGRect], fill: [CGRect]) {
        guard fullscreen != fullscreenRegions || fill != fillRegions else { return }
        let affected = fullscreenRegions + fillRegions + fullscreen + fill
        flakes.removeAll { flake in
            !flake.entersFullscreen && affected.contains { $0.contains(CGPoint(x: flake.x, y: flake.y)) }
        }
        fullscreenRegions = fullscreen
        fillRegions = fill
    }
    func shouldDraw(_ flake: Flake) -> Bool {
        let point = CGPoint(x: flake.x, y: flake.y)
        if menuBarRegions.contains(where: { $0.contains(point) }) { return false }
        if let source = flake.ignoredSurface, drifts[source]?.window.isDock == true, !isActive(source) { return false }
        if windows.contains(where: { $0.blocksFlakes && $0.contains(point) }) { return false }
        return flake.entersFullscreen || (
            !fullscreenRegions.contains(where: { $0.contains(point) })
                && !fillRegions.contains(where: { $0.contains(point) })
        )
    }
    func release(_ drift: Drift, fraction: Double) {
        guard fraction > 0 else { return }
        let contour = SnowContour(drift)
        for i in drift.heights.indices {
            let height = drift.heights[i]
            let x = drift.window.rect.minX + Double(i) * drift.spacing
            let count = min(5, Int(height * fraction / 2))
            if count > 0 {
                for _ in 0..<count where flakes.count < 3500 {
                    flakes.append(Flake(x: x + Double.random(in: -3...3), y: (contour.top(at: x) ?? drift.window.surfaceY(at: x)) - Double.random(in: 2...8), vx: Double.random(in: -65...65), vy: Double.random(in: 15...65), radius: Double.random(in: 1...2.4), phase: Double.random(in: 0...6.28), opacity: 0.9, ignoredSurface: drift.window.id, gravity: 100))
                }
            }
            drift.heights[i] *= 1 - fraction
        }
    }
    func spillDockSnow(_ dt: Double) {
        guard accumulation, dt > 0 else { return }
        for drift in drifts.values where drift.window.isDock && isActive(drift.window.id) {
            let contour = SnowContour(drift)
            for i in 0..<(drift.heights.count - 1) {
                let x = drift.window.rect.minX + (Double(i) + 0.5) * drift.spacing
                guard visible(x: x, y: drift.window.surfaceY(at: x) - 0.5, on: drift.window.id) else { continue }
                let edgeDistance = min(x - drift.window.rect.minX, drift.window.rect.maxX - x)
                // Rounded ends hold less snow; overfilled mounds continually crumble.
                let capacity = 12.0 + min(1, max(0, edgeDistance) / 24) * 6
                let excess = max(0, drift.heights[i] - capacity)
                let removed = min(excess, dt * (3 + excess * 2))
                guard removed > 0 else { continue }
                drift.heights[i] -= removed
                drift.spillCredit += removed
                while drift.spillCredit >= 1.5 {
                    drift.spillCredit -= 1.5
                    guard flakes.count < 3500 else { continue }
                    let left = drift.heights[max(0, i - 1)]
                    let right = drift.heights[min(drift.heights.count - 1, i + 1)]
                    let direction = left == right ? (x < drift.window.rect.midX ? -1.0 : 1.0) : (left > right ? 1.0 : -1.0)
                    flakes.append(Flake(x: x, y: contour.top(at: x) ?? drift.window.surfaceY(at: x),
                        vx: direction * Double.random(in: 12...30), vy: Double.random(in: 12...25),
                        radius: Double.random(in: 1...2), phase: Double.random(in: 0...6.28), opacity: 0.95,
                        ignoredSurface: drift.window.id, gravity: 120))
                }
            }
        }
    }
    func spawn(x: Double, y: Double, admitted: Bool? = nil) {
        if admitted == nil { spawnSerial += 1 }
        flakes.append(Flake(x: x, y: y, vx: Double.random(in: -5...5), vy: Double.random(in: 22...65),
            radius: Double.random(in: 1.1...3.1), phase: Double.random(in: 0...6.28), opacity: Double.random(in: 0.45...0.95), entersFullscreen: admitted ?? (spawnSerial % 20 == 0)))
    }
    func clear() { flakes.removeAll(); for drift in drifts.values { drift.heights = drift.heights.map { _ in 0 }; drift.spillCredit = 0 } }
    func step(_ delta: Double, updateDrifts: Bool = true) {
        let dt = min(max(0, delta), 0.05)
        time += dt
        let sparseRegions = fullscreenRegions + fillRegions
        for (index, rect) in screens.enumerated() {
            topCredits[index, default: 0] += dt * intensity * rect.width / 17
            while topCredits[index, default: 0] >= 1 && flakes.count < 3500 {
                topCredits[index, default: 0] -= 1
                let x = Double.random(in: rect.minX...rect.maxX)
                if let region = sparseRegions.first(where: { $0.intersects(rect) && x >= $0.minX && x < $0.maxX }) {
                    topAdmissionSerial += 1
                    guard topAdmissionSerial % 20 == 0 else { continue }
                    let menuBottom = menuBarRegions.first(where: { $0.intersects(rect) })?.maxY ?? rect.minY
                    let y = max(region.minY, menuBottom) + 2
                    if y < region.maxY { spawn(x: x, y: y, admitted: true) }
                } else {
                    spawn(x: x, y: rect.minY - 6)
                }
            }
            // Match horizontal inflow to wind speed and airborne particle density.
            let sideHeight = rect.height * 0.88
            let flux = max(0, abs(wind) - 8) * intensity * sideHeight / (17 * 43)
            sideCredits[index, default: 0] += dt * flux
            while sideCredits[index, default: 0] >= 1 && flakes.count < 3500 {
                sideCredits[index, default: 0] -= 1
                let x = wind > 0 ? rect.minX - 4 : rect.maxX + 4
                let y = Double.random(in: rect.minY...(rect.minY + sideHeight))
                // Adjacent displays already supply particles across their shared boundary.
                if !screens.enumerated().contains(where: { $0.offset != index && $0.element.contains(CGPoint(x: x, y: y)) }) {
                    spawn(x: x, y: y); sideSpawnCount += 1
                }
            }
            topCredits[index] = min(2, topCredits[index, default: 0])
            sideCredits[index] = min(2, sideCredits[index, default: 0])
        }
        let surfaces = windows + groundIDs.sorted().compactMap { drifts[$0]?.window }
        // The collision surface is sampled from the exact same closed contour as rendering.
        let contours = Dictionary(uniqueKeysWithValues: surfaces.compactMap { surface -> (UInt32, SnowContour)? in
            guard updateDrifts, accumulation, surface.collectsSnow, let drift = drifts[surface.id] else { return nil }
            return (surface.id, SnowContour(drift))
        })
        var survivors: [Flake] = []
        survivors.reserveCapacity(flakes.count)
        for var flake in flakes {
            let oldX = flake.x
            let oldY = flake.y
            flake.x += (flake.vx + wind + sin(time * 1.3 + flake.phase) * 13) * dt
            flake.vy = min(240, flake.vy + flake.gravity * dt)
            flake.y += flake.vy * dt
            let position = CGPoint(x: flake.x, y: flake.y)
            if !flake.entersFullscreen && sparseRegions.contains(where: { $0.contains(position) }) { continue }
            if !flake.entersFullscreen && oldX != flake.x && sideFilteredRegions.contains(where: { region in
                let edge: Double
                if oldX < region.minX && flake.x >= region.minX { edge = region.minX }
                else if oldX >= region.maxX && flake.x < region.maxX { edge = region.maxX }
                else { return false }
                let progress = (edge - oldX) / (flake.x - oldX)
                let crossingY = oldY + (flake.y - oldY) * progress
                return crossingY >= region.minY && crossingY < region.maxY
            }) { continue }
            var hit: (Drift, Double)?
            if accumulation && updateDrifts {
                for surface in surfaces where surface.collectsSnow && !(surface.isFullscreen && flake.entersFullscreen) && surface.id != flake.ignoredSurface {
                    guard surface.snowSupport(at: flake.x) > 0, let drift = drifts[surface.id], let top = contours[surface.id]?.top(at: flake.x) else { continue }
                    let landing = CGPoint(x: flake.x, y: surface.surfaceY(at: flake.x))
                    if sparseRegions.contains(where: { $0.contains(landing) }) { continue }
                    if oldY + flake.radius <= top && flake.y + flake.radius >= top && visible(x: flake.x, y: surface.surfaceY(at: flake.x) - 0.5, on: surface.id) {
                        if hit == nil || top < hit!.1 { hit = (drift, top) }
                    }
                }
            }
            if let (drift, _) = hit { drift.deposit(at: flake.x, amount: flake.radius * 0.6); continue }
            if screens.contains(where: { $0.insetBy(dx: -100, dy: -100).contains(CGPoint(x: flake.x, y: flake.y)) }) { survivors.append(flake) }
        }
        flakes = survivors
        guard updateDrifts else { return }
        spillDockSnow(dt)
        // Melting applies to every bin, including the edges.
        for drift in drifts.values where isActive(drift.window.id) {
            for i in drift.heights.indices { drift.heights[i] = max(0, drift.heights[i] - meltRate * dt) }
        }
        // Slow settling keeps piles soft and prevents permanent, giant walls of snow.
        for drift in drifts.values where isActive(drift.window.id) {
            let old = drift.heights
            if old.count > 2 {
                for i in 1..<(old.count - 1) {
                    let settled = max(0, old[i] + (old[i-1] + old[i+1] - 2 * old[i]) * dt * 0.6)
                    drift.heights[i] = settled > old[i]
                        ? min(settled, drift.capacity(at: drift.window.rect.minX + Double(i) * drift.spacing))
                        : settled
                }
            }
        }
    }
}
