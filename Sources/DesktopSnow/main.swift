import AppKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func runTests() {
    let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
    let engine = SnowEngine()
    engine.setScreens([CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: -800, y: -100, width: 800, height: 600)])
    require(engine.groundIDs.count == 2, "one ground for each display")
    let back = SnowWindow(id: 1, rect: CGRect(x: 100, y: 250, width: 400, height: 250))
    let front = SnowWindow(id: 2, rect: CGRect(x: 200, y: 100, width: 200, height: 400))
    engine.sync([front, back])
    require(!engine.visible(x: 300, y: 249, on: 1), "covered window edge must not collect")
    require(engine.visible(x: 150, y: 249, on: 1), "uncovered edge must collect")
    engine.intensity = 0
    engine.flakes = [Flake(x: 150, y: 247, vx: 0, vy: 60, radius: 2, phase: 0, opacity: 1)]
    engine.step(0.05)
    require(engine.flakes.isEmpty, "flake collides with edge")
    require(engine.drifts[1]!.heights.max()! > 0, "collision creates snow")
    engine.drifts[1]!.heights = engine.drifts[1]!.heights.map { _ in 20 }
    engine.sync([front, SnowWindow(id: 1, rect: back.rect.offsetBy(dx: 80, dy: 0))])
    require(!engine.flakes.isEmpty, "moving a window sheds particles")
    require(engine.drifts[1]!.heights.max()! < 20, "shedding removes snow mass")
    engine.sync([front]); require(engine.drifts[1] == nil, "closed window removes drift")
    engine.clear()
    require(engine.flakes.isEmpty && engine.drifts.values.allSatisfy { $0.heights.allSatisfy { $0 == 0 } }, "clear resets all snow")
    engine.drifts[2]!.heights = engine.drifts[2]!.heights.map { _ in 1 }
    engine.meltRate = 1.2
    for _ in 0..<60 { engine.step(1.0 / 30) }
    require(engine.drifts[2]!.heights.allSatisfy { $0 == 0 }, "snow melts completely including edge bins")
    engine.intensity = 2.5
    for _ in 0..<3000 { engine.step(1.0 / 30) }
    require(engine.flakes.count <= 3500, "bounded particle count")
    require(engine.drifts.values.allSatisfy { $0.heights.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 28 } }, "finite bounded piles")
    let container = CGRect(x: 100, y: 480, width: 400, height: 60)
    let dock = SnowWindow.dock(id: 10, container: container)
    require(dock.rect.minY == 486, "Dock collision excludes transparent top margin")
    require(dock.surfaceY(at: 100) > dock.surfaceY(at: 150), "Dock follows rounded corners")
    require(dock.rect.maxY == container.maxY, "Dock correction keeps lower edge fixed")
    let dockEngine = SnowEngine()
    dockEngine.setScreens([CGRect(x: 0, y: 0, width: 800, height: 700)])
    dockEngine.intensity = 0; dockEngine.wind = 0; dockEngine.meltRate = 0
    dockEngine.sync([dock])
    dockEngine.flakes = [Flake(x: 300, y: 480, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1)]
    dockEngine.step(0.05)
    require(dockEngine.flakes.isEmpty, "flake lands on corrected Dock surface")
    require(dockEngine.drifts[10]!.heights.max()! > 0, "Dock collects deposited snow")
    dockEngine.drifts[10]!.heights = dockEngine.drifts[10]!.heights.map { _ in 28 }
    dockEngine.step(0.05)
    require(!dockEngine.flakes.isEmpty, "overfilled Dock sheds snow even without movement")
    require(dockEngine.flakes.allSatisfy { $0.ignoredSurface == 10 && $0.gravity > 0 }, "spill ignores its source and accelerates")
    require(dockEngine.drifts[10]!.heights[20] < 28, "spill removes mass from mound")
    for _ in 0..<40 { dockEngine.step(1.0 / 30) }
    require(dockEngine.flakes.contains { $0.y > dock.rect.maxY }, "spilled snow falls past Dock without sticking back")
    dockEngine.clear()
    require(dockEngine.drifts[10]!.spillCredit == 0, "clear resets pending spill")
    let rounded = SnowWindow(id: 20, rect: CGRect(x: 50, y: 60, width: 100, height: 100), cornerRadius: 20)
    require(!rounded.contains(CGPoint(x: 51, y: 61)), "transparent window corner does not occlude")
    require(rounded.contains(CGPoint(x: 70, y: 61)), "window top inside rounded contour occludes")
    require(rounded.surfaceY(at: 51) > 70, "rounded window top drops at the side")
    func alpha(_ engine: SnowEngine, at point: CGPoint, pass: SnowPass = .all) -> UInt8 {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: -point.x, y: -point.y)
        drawSnow(context, engine: engine, origin: .zero, clip: CGRect(x: 0, y: 0, width: 800, height: 700), pass: pass)
        return context.data!.assumingMemoryBound(to: UInt8.self)[3]
    }
    let renderEngine = SnowEngine()
    renderEngine.setScreens([CGRect(x: 0, y: 0, width: 240, height: 240)])
    let ground = renderEngine.drifts[renderEngine.groundIDs.first!]!
    ground.heights = ground.heights.map { _ in 28 }
    renderEngine.dockProtection = [SnowWindow(id: 30, rect: CGRect(x: 80, y: 180, width: 100, height: 60))]
    require(alpha(renderEngine, at: CGPoint(x: 100, y: 225)) == 0, "ground snow cannot cover Dock even without an exact collider")
    require(alpha(renderEngine, at: CGPoint(x: 40, y: 225)) > 0, "ground snow remains beside Dock")
    renderEngine.dockProtection = []
    require(alpha(renderEngine, at: CGPoint(x: 100, y: 225), pass: .foreground) == 0, "foreground layer never paints ground over Dock")
    require(alpha(renderEngine, at: CGPoint(x: 100, y: 225), pass: .ground) > 0, "ground snow remains in its lower compositor layer")
    renderEngine.flakes = [Flake(x: 100, y: 100, vx: 0, vy: 40, radius: 2, phase: 0, opacity: 1)]
    require(alpha(renderEngine, at: CGPoint(x: 100, y: 100), pass: .ground) == 0, "falling snow is not duplicated in ground layer")
    renderEngine.clear()
    renderEngine.dockProtection = []
    renderEngine.sync([rounded])
    renderEngine.drifts[20]!.heights = renderEngine.drifts[20]!.heights.map { _ in 8 }
    require(alpha(renderEngine, at: CGPoint(x: 50, y: 70)) == 0, "steep corner does not support snow")
    require(alpha(renderEngine, at: CGPoint(x: 80, y: 55)) > 0, "snow stays on upper window edge")
    require(alpha(renderEngine, at: CGPoint(x: 55, y: 70)) == 0, "curved snow bins never paint inside their own window")
    require(alpha(renderEngine, at: CGPoint(x: 64, y: 57)) > 0, "shallow curve still supports snow")


    renderEngine.clear()
    renderEngine.intensity = 0
    renderEngine.wind = 0
    renderEngine.flakes = [Flake(x: 51, y: 70, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1)]
    renderEngine.step(0.05)
    require(renderEngine.flakes.count == 1 && renderEngine.drifts[20]!.heights.allSatisfy { $0 == 0 },
        "flake passes a steep slope without depositing snow")

    for radius in [10.0, 20.0, 26.0, 36.0] {
        for depth in [2.0, 8.0, 28.0] {
            let window = SnowWindow(id: 91, rect: CGRect(x: 50, y: 60, width: 200, height: 120), cornerRadius: radius)
            let drift = Drift(window); drift.heights = drift.heights.map { _ in depth }
            let contour = SnowContour(drift)
            require(contour.outer.allSatisfy { $0.x >= window.rect.minX && $0.x <= window.rect.maxX },
                "snow cannot overhang the side walls")
            require(contour.outer.first == contour.base.first && contour.outer.last == contour.base.last, "snow closes exactly on both vertical tangents")
            require(contour.capInner.first == contour.base.first && contour.capInner.last == contour.base.last, "white cap joins body without dangling end")
            require(abs(contour.outer.first!.x - window.rect.minX) < 0.001 && abs(contour.outer.last!.x - window.rect.maxX) < 0.001, "ends follow real side coordinates")
            require(zip(contour.outer, contour.outer.dropFirst()).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 4 }, "no abrupt rectangular cutoff in outer contour")
            require((50...250).allSatisfy { contour.top(at: Double($0))?.isFinite == true }, "collision lookup covers rendered surface")
        }
    }

    require(WindowRules.isCleanMyMac(bundleID: "com.macpaw.CleanMyMac4", owner: "Cleaner"), "CleanMyMac X excluded by bundle identity")
    require(WindowRules.isCleanMyMac(bundleID: "com.macpaw.CleanMyMac4.Menu", owner: "Helper"), "CleanMyMac menu helper excluded")
    require(WindowRules.isCleanMyMac(bundleID: "com.macpaw.CleanMyMac", owner: "Cleaner"), "new CleanMyMac identity excluded")
    require(WindowRules.isCleanMyMac(bundleID: nil, owner: "CleanMyMac X"), "name fallback handles absent bundle metadata")
    require(!WindowRules.isCleanMyMac(bundleID: "com.apple.finder", owner: "Finder"), "exclusion does not affect unrelated apps")
    let widgetBounds = CGRect(x: 8, y: 41, width: 180, height: 180)
    require(WindowRules.isDesktopWidget(bundleID: "com.apple.notificationcenterui", owner: "Notification Center", layer: -2147483601, rect: widgetBounds, screens: [screen]), "desktop-layer widget is recognized")
    require(!WindowRules.isDesktopWidget(bundleID: "com.apple.notificationcenterui", owner: "Notification Center", layer: 23, rect: screen, screens: [screen]), "notification canvas is not a widget")
    require(!WindowRules.isDesktopWidget(bundleID: "com.apple.finder", owner: "Finder", layer: -2147483603, rect: widgetBounds, screens: [screen]), "desktop icon surfaces are not widgets")
    let widget = WindowRules.widgetSurface(id: 95, container: widgetBounds)
    require(widget.rect == CGRect(x: 16, y: 49, width: 164, height: 164), "widget snow follows card rather than transparent container margin")
    let widgets = SnowEngine(); widgets.setScreens([screen]); widgets.intensity = 0; widgets.wind = 0; widgets.meltRate = 0
    widgets.sync([widget])
    widgets.flakes = [Flake(x: 100, y: 45, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1)]
    widgets.step(0.05)
    require(widgets.flakes.isEmpty && widgets.drifts[95]!.heights.max()! > 0, "flake deposits on desktop widget")
    widgets.drifts[95]!.heights = widgets.drifts[95]!.heights.map { _ in 12 }
    let excluded = SnowWindow(id: 96, rect: CGRect(x: 70, y: 20, width: 250, height: 250), collectsSnow: false)
    widgets.sync([excluded, widget])
    require(!widgets.visible(x: 100, y: 48, on: 95), "excluded app still occludes widget snow behind it")
    require(alpha(widgets, at: CGPoint(x: 100, y: 40)) == 0, "CleanMyMac cannot be covered by widget pile behind")
    let before = widgets.flakes.count
    widgets.sync([SnowWindow(id: 95, rect: widget.rect, collectsSnow: false)])
    require(widgets.drifts[95] == nil && widgets.flakes.count == before, "newly excluded surface clears old snow without shedding")
    print("PASS: desktop widget classification, card inset, accumulation, occlusion, CleanMyMac versions/helpers, exclusion clears old snow")

    print("PASS: closed snow contours at 4 radii and 3 depths; shared render/collision boundary")

    let saved = SnowEngine()
    saved.setScreens([screen]); saved.intensity = 0; saved.meltRate = 0
    saved.sync([back])
    saved.drifts[1]!.heights = saved.drifts[1]!.heights.map { _ in 12 }
    saved.flakes = [Flake(x: 50, y: 100, vx: 0, vy: 40, radius: 2, phase: 0, opacity: 1)]
    let snapshot = saved.drifts[1]!.heights
    saved.setScreens([screen])
    require(saved.flakes.count == 1 && saved.drifts[1]!.heights == snapshot, "unchanged screen notification preserves snow")
    saved.sync([], existingIDs: [1])
    require(saved.drifts[1] != nil && !saved.isActive(1), "offscreen window is archived rather than deleted")
    saved.meltRate = 1
    for _ in 0..<30 { saved.step(1.0 / 30) }
    require(saved.drifts[1]!.heights == snapshot, "hidden window snow remains frozen")
    let airborneCount = saved.flakes.count
    saved.sync([SnowWindow(id: 1, rect: back.rect.offsetBy(dx: 200, dy: 0))], existingIDs: [1])
    require(saved.isActive(1) && saved.drifts[1]!.heights == snapshot, "returning window restores its pile without shedding")
    require(saved.flakes.count == airborneCount, "Space restoration does not create a false avalanche")
    saved.sync([], existingIDs: [])
    require(saved.drifts[1] == nil, "genuinely closed windows are removed")
    for direction in [-65.0, 65.0] {
        let windy = SnowEngine()
        windy.setScreens([screen]); windy.wind = direction; windy.intensity = 1; windy.accumulation = false
        for _ in 0..<30 { windy.step(1.0 / 30) }
        require(windy.sideSpawnCount > 15, "gust has compensating side inflow in both directions")
        let side = windy.flakes.filter { $0.y > 100 }
        require(!side.isEmpty, "side inlet immediately fills lower empty area")
        require(side.allSatisfy { direction > 0 ? $0.x < 100 : $0.x > 700 }, "inlet is on windward edge")
    }
    let calm = SnowEngine(); calm.setScreens([screen]); calm.wind = 0
    for _ in 0..<30 { calm.step(1.0 / 30) }
    require(calm.sideSpawnCount == 0, "calm weather has no extra side emitter")

    let notchedScreen = ScreenLayout(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 33)
    require(notchedScreen.isEdgeToEdge(CGRect(x: 0, y: 33, width: 1512, height: 949)), "fullscreen excludes notch strip")
    require(notchedScreen.isEdgeToEdge(notchedScreen.frame), "borderless fullscreen is detected")
    require(!notchedScreen.isEdgeToEdge(CGRect(x: 0, y: 33, width: 1512, height: 886)), "maximized window above visible Dock is not fullscreen")
    let layered = SnowEngine(); layered.setScreens([screen])
    let rear = SnowWindow(id: 41, rect: CGRect(x: 100, y: 200, width: 400, height: 300))
    let preview = SnowWindow(id: 42, rect: CGRect(x: 150, y: 50, width: 200, height: 400), cornerRadius: 20,
        collectsSnow: false, blocksFlakes: true)
    layered.sync([preview, rear])
    layered.drifts[41]!.heights = layered.drifts[41]!.heights.map { _ in 20 }
    require(layered.drifts[42] == nil, "Quick Look is an occluder, not an accumulating shelf")
    require(alpha(layered, at: CGPoint(x: 250, y: 190)) == 0, "Quick Look clips snow from window behind")
    require(alpha(layered, at: CGPoint(x: 120, y: 190)) > 0, "rear window snow remains outside preview")
    require(!layered.shouldDraw(Flake(x: 250, y: 190, vx: 0, vy: 40, radius: 2, phase: 0, opacity: 1, entersFullscreen: true)), "preview blocks even ambient flakes")
    let full = SnowWindow(id: 43, rect: CGRect(x: 0, y: 20, width: 800, height: 580), isFullscreen: true)
    layered.sync([dock]); layered.drifts[10]!.heights = layered.drifts[10]!.heights.map { _ in 20 }
    layered.fullscreenRegions = [full.rect]
    layered.sync([full], existingIDs: [10, 43])
    require(!layered.isActive(10) && layered.drifts[10] != nil, "Dock pile is archived while fullscreen")
    require(alpha(layered, at: CGPoint(x: 300, y: 475)) == 0, "archived Dock pile never draws over fullscreen")
    let dockFragment = Flake(x: 300, y: 475, vx: 0, vy: 40, radius: 2, phase: 0, opacity: 1, ignoredSurface: 10, entersFullscreen: true)
    require(!layered.shouldDraw(dockFragment), "hidden Dock fragments cannot leak into fullscreen")
    layered.drifts[43]!.heights = layered.drifts[43]!.heights.map { _ in 8 }
    require(alpha(layered, at: CGPoint(x: 1, y: 15)) > 0 && alpha(layered, at: CGPoint(x: 400, y: 15)) > 0, "fullscreen snow reaches both straight screen edges")
    layered.clear()
    layered.intensity = 0; layered.wind = 0
    layered.flakes = [
        Flake(x: 100, y: 16, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1),
        Flake(x: 300, y: 16, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1, entersFullscreen: true)]
    layered.step(0.05)
    require(layered.flakes.count == 1 && layered.flakes[0].entersFullscreen, "ambient flakes pass through while ordinary snow is filtered")
    layered.clear()
    for _ in 0..<400 { layered.spawn(x: 400, y: 100) }
    require(layered.flakes.filter { layered.shouldDraw($0) }.count == 20, "only five percent of top-origin snow is visible inside fullscreen")
    layered.clear()
    for _ in 0..<400 { layered.spawn(x: 1, y: 300) }
    require(layered.flakes.filter { layered.shouldDraw($0) }.count == 20, "same five-percent filter applies to windward inflow")
    layered.drifts[43]!.heights = layered.drifts[43]!.heights.map { _ in 8 }
    require(alpha(layered, at: CGPoint(x: 400, y: 15)) > 0, "fullscreen pile is visible before transition")
    let filledRect = CGRect(x: 0, y: 33, width: 800, height: 504)
    let fillLayout = ScreenLayout(frame: screen, topInset: 33, workArea: filledRect)
    require(fillLayout.fillsWorkArea(filledRect) && !fillLayout.isEdgeToEdge(filledRect), "Fill uses work area, independent of fullscreen")
    require(!fillLayout.fillsWorkArea(filledRect.insetBy(dx: 10, dy: 0)), "partial window does not count as Fill")
    layered.fillRegions = [filledRect]
    layered.fullscreenRegions = []
    let filled = SnowWindow(id: 43, rect: filledRect, collectsSnow: false, isFill: true)
    layered.sync([filled])
    require(layered.drifts[43]?.heights[10] == 8 && !layered.isActive(43), "Fill archives preexisting pile without displaying it")
    layered.clear()
    layered.flakes = [
        Flake(x: 400, y: 30, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1, entersFullscreen: true),
        Flake(x: 1, y: 300, vx: 0, vy: 40, radius: 2, phase: 0, opacity: 1)]
    layered.step(0.05)
    require(layered.flakes.count == 1 && layered.shouldDraw(layered.flakes[0]), "Fill admits sparse top snow and filters side snow")
    let frozenPositions = layered.flakes.map { CGPoint(x: $0.x, y: $0.y) }
    layered.fillRegions = []
    layered.sync([], existingIDs: [43])
    require(layered.flakes.map { CGPoint(x: $0.x, y: $0.y) } == frozenPositions
        && layered.flakes.allSatisfy { layered.shouldDraw($0) }, "Space refresh keeps paused flakes and applies destination visibility")

    let desktop = SnowEngine()
    desktop.setScreens([screen])
    desktop.intensity = 0
    let oldWidget = WindowRules.widgetSurface(id: 501, container: CGRect(x: 30, y: 120, width: 180, height: 180))
    desktop.sync([rear, oldWidget])
    desktop.drifts[rear.id]?.heights[10] = 12
    desktop.drifts[oldWidget.id]?.heights[10] = 16
    let fullscreenRear = SnowWindow(id: rear.id, rect: screen, collectsSnow: false, isFullscreen: true)
    desktop.sync([fullscreenRear], existingIDs: [rear.id], shedOnChange: false, preserveMissing: true)
    desktop.step(0.05)
    require(!desktop.isActive(rear.id) && !desktop.isActive(oldWidget.id), "hidden piles stay dormant during fullscreen")
    let recreatedWidget = SnowWindow(id: 502, rect: oldWidget.rect, cornerRadius: oldWidget.cornerRadius, isWidget: true)
    desktop.sync([rear, recreatedWidget], existingIDs: [rear.id, recreatedWidget.id], shedOnChange: false, preserveMissing: true)
    require(desktop.drifts[rear.id]?.heights[10] == 12 && desktop.drifts[502]?.heights[10] == 16
        && desktop.flakes.isEmpty, "returning from fullscreen restores the original window and recreated widget piles")

    let changingID = SnowEngine()
    let oldWindow = SnowWindow(id: 601, rect: rear.rect, ownerPID: 42)
    changingID.sync([oldWindow])
    changingID.drifts[601]?.heights[10] = 17
    let temporaryPanel = SnowWindow(id: 601, rect: screen, collectsSnow: false, ownerPID: 42)
    changingID.sync([temporaryPanel], shedOnChange: false, preserveMissing: true)
    require(changingID.drifts[601]?.heights[10] == 17 && !changingID.isActive(601), "temporary panel classification retains the desktop pile")
    let replacement = SnowWindow(id: 602, rect: rear.rect, ownerPID: 42)
    changingID.sync([replacement], existingIDs: [601, 602], shedOnChange: false, preserveMissing: true)
    require(changingID.drifts[602]?.heights[10] == 17 && changingID.drifts[601] == nil,
        "replacement window ID restores the same process and desktop frame's pile")

    let slide = SnowEngine()
    slide.setScreens([notchedScreen.frame])
    slide.intensity = 0
    let desktopWindow = SnowWindow(id: 610, rect: CGRect(x: 0, y: 80, width: 1512, height: 839))
    slide.sync([desktopWindow])
    slide.drifts[610]?.heights[10] = 18
    for (offset, incomingX) in [(30.0, 1546.0), (252, 1324), (612, 964), (1498, 78)] {
        let incomingFull = CGRect(x: incomingX, y: 33, width: 1512, height: 949)
        let shifting = notchedScreen.isSlidingFullscreen(incomingFull)
        require(shifting, "translated Chrome frame identifies Space animation before notification")
        let moving = SnowWindow(id: 610, rect: desktopWindow.rect.offsetBy(dx: -offset, dy: 0))
        slide.sync([moving], shedOnChange: !shifting, preserveMissing: shifting)
        slide.step(0.05, updateDrifts: !shifting)
    }
    slide.sync([], existingIDs: [], shedOnChange: false, preserveMissing: true)
    slide.sync([desktopWindow], shedOnChange: false, preserveMissing: true)
    require(slide.drifts[610]?.heights[10] == 18 && slide.flakes.isEmpty,
        "recorded Space slide preserves the desktop pile without shedding")
    require(!notchedScreen.isSlidingFullscreen(CGRect(x: -30, y: 33, width: 1512, height: 886)),
        "moving a Fill window alone does not count as a Space slide")

    let wide = SnowEngine()
    wide.setScreens([notchedScreen.frame])
    wide.intensity = 0
    wide.wind = 0
    let wideWindow = SnowWindow(id: 620, rect: CGRect(x: 0, y: 100, width: 1512, height: 600))
    require(notchedScreen.spansWidth(wideWindow.rect) && !notchedScreen.isEdgeToEdge(wideWindow.rect),
        "a short window can span the display width")
    wide.sync([wideWindow])
    wide.sideFilteredRegions = [wideWindow.rect]
    wide.flakes = [
        Flake(x: -1, y: 200, vx: 60, vy: 30, radius: 2, phase: 0, opacity: 1),
        Flake(x: 1513, y: 200, vx: -60, vy: 30, radius: 2, phase: 0, opacity: 1),
        Flake(x: -1, y: 250, vx: 60, vy: 30, radius: 2, phase: 0, opacity: 1, entersFullscreen: true),
        Flake(x: 300, y: 96, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1),
        Flake(x: -1, y: 80, vx: 60, vy: 30, radius: 2, phase: 0, opacity: 1)
    ]
    wide.step(0.05)
    require(wide.flakes.count == 2 && wide.flakes.contains(where: \.entersFullscreen),
        "both sides reject ordinary flakes and admit sparse snow, with clear air above the window")
    require((wide.drifts[620]?.heights.max() ?? 0) > 0, "wide windows still collect snowfall from above")

    let relief = SnowEngine()
    relief.menuBarRegions = [CGRect(x: 0, y: 0, width: 1512, height: 33)]
    let upperWidget = WindowRules.widgetSurface(id: 631, container: CGRect(x: 8, y: 41, width: 180, height: 180))
    relief.sync([upperWidget, wideWindow])
    let widgetPile = relief.drifts[631]!
    let widePile = relief.drifts[620]!
    for pile in [widgetPile, widePile] {
        for x in stride(from: pile.window.rect.minX, through: pile.window.rect.maxX, by: 5) {
            pile.deposit(at: x, amount: 100)
        }
    }
    let widgetShape = SnowContour(widgetPile)
    require(widgetShape.outer.allSatisfy { $0.y > 33 }, "upper widget contour stays clear of the menu even when saturated")
    let wideShape = SnowContour(widePile)
    let crest = wideShape.outer.filter { $0.x > 100 && $0.x < 1400 }.map(\.y)
    require(crest.max()! - crest.min()! >= 8, "saturated window snow retains visible height variation")
    require(SnowContour(widePile).outer == wideShape.outer, "snow relief stays stable between frames")

    let entry = SnowEngine()
    entry.setScreens([screen])
    entry.menuBarRegions = [CGRect(x: 0, y: 0, width: 800, height: 33)]
    let entryRect = CGRect(x: 0, y: 33, width: 800, height: 567)
    entry.updateSparseRegions(fullscreen: [entryRect], fill: [])
    entry.wind = 0
    entry.intensity = 1
    for _ in 0..<30 { entry.step(1.0 / 30) }
    require(!entry.flakes.isEmpty && entry.flakes.allSatisfy { $0.y >= 35 && entry.shouldDraw($0) },
        "top-only snow starts below the protected menu and is visible inside fullscreen")
    entry.intensity = 0
    entry.flakes = [
        Flake(x: 200, y: 595, vx: 0, vy: 80, radius: 2, phase: 0, opacity: 1, entersFullscreen: true),
        Flake(x: 300, y: 300, vx: 0, vy: 40, radius: 2, phase: 0, opacity: 1)
    ]
    entry.step(0.05)
    require(entry.flakes.count == 1 && entry.drifts.values.allSatisfy { $0.heights.allSatisfy { $0 == 0 } },
        "fullscreen cannot build invisible ground snow")
    entry.updateSparseRegions(fullscreen: [], fill: [])
    require(entry.flakes.count == 1, "leaving fullscreen does not reveal rejected particles")

    let protected = SnowEngine()
    protected.setScreens([screen]); protected.intensity = 0
    let menuLayout = ScreenLayout(frame: screen, topInset: 33)
    protected.menuBarRegions = [menuLayout.menuBarRegion]
    let menuFull = SnowWindow(id: 80, rect: CGRect(x: 0, y: 33, width: 800, height: 567), isFullscreen: true)
    protected.sync([menuFull])
    protected.drifts[80]!.heights = protected.drifts[80]!.heights.map { _ in 28 }
    require(alpha(protected, at: CGPoint(x: 10, y: 15)) == 0, "fullscreen pile cannot cover menu labels")
    require(alpha(protected, at: CGPoint(x: 790, y: 15)) == 0, "fullscreen pile cannot cover right status icons")
    require(protected.drifts[80]!.heights[10] == 28, "menu clipping preserves accumulated snow state")
    protected.clear()
    protected.flakes = [Flake(x: 100, y: 33, vx: 0, vy: 40, radius: 3, phase: 0, opacity: 1, entersFullscreen: true)]
    require(alpha(protected, at: CGPoint(x: 100, y: 32)) == 0, "large flake crossing menu boundary is clipped")
    require(alpha(protected, at: CGPoint(x: 100, y: 34)) > 0, "flake remains visible below protected menu strip")
    require(!protected.shouldDraw(Flake(x: 100, y: 10, vx: 0, vy: 40, radius: 2, phase: 0, opacity: 1, entersFullscreen: true)), "ambient flakes also avoid menu")
    let offsetMenu = ScreenLayout(frame: CGRect(x: -800, y: -200, width: 800, height: 600), topInset: 24)
    protected.menuBarRegions.append(offsetMenu.menuBarRegion)
    require(offsetMenu.menuBarRegion == CGRect(x: -800, y: -200, width: 800, height: 24), "menu regions use each display's own global coordinates")
    print("PASS: menu labels/status icons, crossing flake pixels, ambient flakes, retained piles, per-display menu regions")

    print("PASS: Quick Look occlusion, notch-aware fullscreen, hidden Dock, straight edges, matching top/side ambient filters")

    print("PASS: Space state restoration, identical-screen preservation, side inflow for both gust directions")

    print("PASS: rounded window contour, pixel rendering, Dock protection with missing geometry")
    print("PASS: Dock inset, rounded corners, collision, overflow, gravity, no reattachment")
    print("PASS: multi-display grounds, occlusion, collisions, accumulation, shedding, closure, clearing, long simulation")
}
if CommandLine.arguments.contains("--self-test") { runTests(); exit(0) }

if CommandLine.arguments.contains("--probe-widgets") {
    let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    var count = 0, exclusions = 0
    for row in rows {
        guard let pid = row[kCGWindowOwnerPID as String] as? Int32, let layer = row[kCGWindowLayer as String] as? Int,
            let bounds = row[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        let owner = row[kCGWindowOwnerName as String] as? String ?? ""
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if WindowRules.isDesktopWidget(bundleID: bundle, owner: owner, layer: layer, rect: rect, screens: screens) {
            let surface = WindowRules.widgetSurface(id: 0, container: rect)
            print("Widget card", NSStringFromRect(surface.rect), "radius", surface.cornerRadius)
            count += 1
        }
        if WindowRules.isCleanMyMac(bundleID: bundle, owner: owner) { exclusions += 1 }
    }
    print("Widget cards: \(count); excluded CleanMyMac windows/helpers: \(exclusions)")
    exit(0)
}

if CommandLine.arguments.contains("--probe-dock") {
    let resolver = DockResolver()
    let resolution = resolver.resolve(cgContainer: nil, allWindows: [])
    print("Dock", resolution?.source ?? "none", resolution.map { NSStringFromRect($0.shelf) } ?? "none", "AX:", resolver.lastAXNote)
    exit(0)
}
if CommandLine.arguments.contains("--diagnostics") {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for item in windows {
        print("\(item[kCGWindowOwnerName as String] ?? "?") layer=\(item[kCGWindowLayer as String] ?? "?") bounds=\(item[kCGWindowBounds as String] ?? "?")")
    }
    exit(0)
}


if let index = CommandLine.arguments.firstIndex(of: "--render-corners"), CommandLine.arguments.count > index + 1 {
    let width = 1200, height = 320, scale = 2
    let engine = SnowEngine()
    engine.setScreens([CGRect(x: 0, y: 0, width: width, height: height)])
    let windows = [10.0, 20.0, 26.0, 36.0].enumerated().map { index, radius in
        SnowWindow(id: UInt32(index + 1), rect: CGRect(x: 20 + index * 300, y: 110, width: 260, height: 260), cornerRadius: radius)
    }
    engine.sync(windows)
    for drift in engine.drifts.values where !engine.groundIDs.contains(drift.window.id) {
        drift.heights = drift.heights.indices.map { 12 + 10 * pow(sin(Double($0) * 0.17), 2) }
    }
    let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
        bytesPerRow: width * scale * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: Double(height * scale)); context.scaleBy(x: Double(scale), y: -Double(scale))
    context.setFillColor(CGColor(red: 0.24, green: 0.33, blue: 0.39, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for window in windows {
        let path = CGPath(roundedRect: window.rect, cornerWidth: window.cornerRadius, cornerHeight: window.cornerRadius, transform: nil)
        context.setFillColor(CGColor(gray: 0.12, alpha: 1)); context.addPath(path); context.fillPath()
        context.setStrokeColor(CGColor(gray: 0.6, alpha: 1)); context.setLineWidth(1); context.addPath(path); context.strokePath()
    }
    drawSnow(context, engine: engine, origin: .zero, clip: CGRect(x: 0, y: 0, width: width, height: height))
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    print("Corner comparison rendered: 10 / 20 / 26 / 36 pt")
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-demo"), CommandLine.arguments.count > index + 1 {
    let width = 1100, height = 700
    let engine = SnowEngine()
    engine.setScreens([CGRect(x: 0, y: 0, width: width, height: height)])
    let front = SnowWindow(id: 1, rect: CGRect(x: 400, y: 260, width: 560, height: 320), cornerRadius: 26)
    let back = SnowWindow(id: 2, rect: CGRect(x: 120, y: 150, width: 580, height: 340), cornerRadius: 26)
    let dock = SnowWindow.dock(id: 3, container: CGRect(x: 310, y: 625, width: 480, height: 70))
    engine.sync([front, back, dock])
    engine.dockProtection = [dock]
    engine.intensity = 1.8
    for _ in 0..<3000 { engine.step(1.0 / 30) }
    // Reproduce the reported case with a fully built ground drift behind the Dock.
    for id in engine.groundIDs { engine.drifts[id]!.heights = engine.drifts[id]!.heights.map { _ in 28 } }
    engine.drifts[3]!.heights = engine.drifts[3]!.heights.map { _ in 10 }
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.22, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (window, shade) in [(back, 0.21), (front, 0.28), (dock, 0.35)] {
        context.saveGState()
        context.addPath(CGPath(roundedRect: window.rect, cornerWidth: window.cornerRadius, cornerHeight: window.cornerRadius, transform: nil))
        context.clip()
        context.setFillColor(CGColor(gray: shade, alpha: 1)); context.fill(window.rect)
        context.setFillColor(CGColor(gray: shade + 0.08, alpha: 1))
        context.fill(CGRect(x: window.rect.minX, y: window.rect.minY, width: window.rect.width, height: 30))
        context.restoreGState()
    }
    for i in 0..<5 {
        context.setFillColor(CGColor(red: 0.44, green: 0.55, blue: 0.7, alpha: 0.5))
        context.fill(CGRect(x: 430, y: 320 + i * 38, width: 260 - i * 22, height: 8))
    }
    for i in 0..<8 {
        context.setFillColor(CGColor(red: 0.3 + Double(i % 3) * 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 325 + i * 58, y: 650, width: 35, height: 35))
    }
    drawSnow(context, engine: engine, origin: .zero, clip: CGRect(x: 0, y: 0, width: width, height: height))
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    print("Demo rendered")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
