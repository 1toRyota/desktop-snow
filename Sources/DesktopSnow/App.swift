import AppKit
import ServiceManagement
import ApplicationServices

enum SnowPass { case all, ground, foreground }

final class SnowView: NSView {
    let engine: SnowEngine
    let screenRect: CGRect
    let pass: SnowPass
    init(engine: SnowEngine, screen: CGRect, pass: SnowPass) {
        self.engine = engine; self.screenRect = screen; self.pass = pass
        super.init(frame: CGRect(origin: .zero, size: screen.size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        drawSnow(context, engine: engine, origin: screenRect.origin, clip: bounds, pass: pass)
    }
}
func subtractShape(_ shape: SnowWindow, from context: CGContext) {
    let path = CGMutablePath()
    path.addRect(CGRect(x: -100000, y: -100000, width: 200000, height: 200000))
    path.addRoundedRect(in: shape.rect, cornerWidth: shape.cornerRadius, cornerHeight: shape.cornerRadius)
    context.addPath(path)
    context.clip(using: .evenOdd)
}
private enum SnowPalette {
    static let frost = CGColor(red: 0.97, green: 0.99, blue: 1, alpha: 1)
    static let body = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.89, green: 0.96, blue: 1, alpha: 0.98),
        CGColor(red: 0.79, green: 0.91, blue: 0.98, alpha: 0.97),
        CGColor(red: 0.76, green: 0.85, blue: 0.98, alpha: 0.96),
        CGColor(red: 0.70, green: 0.78, blue: 0.92, alpha: 0.96)
    ] as CFArray, locations: [0, 0.32, 0.67, 1])!
    static let flakes = [
        frost,
        CGColor(red: 0.88, green: 0.96, blue: 1, alpha: 1),
        CGColor(red: 0.77, green: 0.89, blue: 1, alpha: 1),
        CGColor(red: 0.87, green: 0.87, blue: 1, alpha: 1)
    ]
}

func drawSnow(_ context: CGContext, engine: SnowEngine, origin: CGPoint, clip: CGRect, pass: SnowPass = .all) {
    context.saveGState()
    context.clip(to: clip)
    context.translateBy(x: -origin.x, y: -origin.y)
    context.setShouldAntialias(false)
    // Clip the entire render, not just particle centres: large flakes and piles
    // must not extend into menu labels, status icons or the camera strip.
    for region in engine.menuBarRegions {
        subtractShape(SnowWindow(id: 0, rect: region), from: context)
    }
    if engine.accumulation {
        var drawOrder: [UInt32] = []
        if pass != .foreground { drawOrder.append(contentsOf: engine.groundIDs.sorted()) }
        // Quartz reports front-to-back order. Paint the farthest piles first.
        if pass != .ground { drawOrder.append(contentsOf: engine.windows.reversed().map(\.id)) }
        for id in drawOrder {
            guard engine.isActive(id), let drift = engine.drifts[id], drift.window.collectsSnow else { continue }
            // Build the occlusion mask once per surface, not once per 5-point snow bin.
            context.saveGState()
            if !drift.window.isFullscreen {
                for region in engine.fullscreenRegions { subtractShape(SnowWindow(id: 0, rect: region), from: context) }
            }
            subtractShape(drift.window, from: context)
            if !drift.window.isDock {
                for protected in engine.dockProtection { subtractShape(protected, from: context) }
            }
            for front in engine.windows {
                if front.id == drift.window.id { break }
                subtractShape(front, from: context)
            }
            let contour = SnowContour(drift)
            let top = contour.bodyPath.boundingBoxOfPath.minY
            context.saveGState()
            context.addPath(contour.bodyPath)
            context.clip()
            context.drawLinearGradient(SnowPalette.body,
                start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: max(top + 1, drift.window.rect.minY)),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
            context.setFillColor(SnowPalette.frost)
            context.addPath(contour.capPath); context.fillPath()
            context.restoreGState()
        }
    }
    if pass != .ground {
    for flake in engine.flakes where engine.shouldDraw(flake) {
        let size = flake.radius > 2.3 ? 4.0 : 2.0
        let x = floor(flake.x / 2) * 2, y = floor(flake.y / 2) * 2
        let shade = SnowPalette.flakes[Int(abs(flake.phase) * 11) % SnowPalette.flakes.count]
        context.setFillColor(shade.copy(alpha: flake.opacity) ?? shade)
        context.fill(CGRect(x: x, y: y, width: size, height: size))
        if flake.radius > 2.8 {
            context.fill(CGRect(x: x - 2, y: y + 2, width: 8, height: 2))
            context.fill(CGRect(x: x + 2, y: y - 2, width: 2, height: 8))
        }
    }
    }
    context.restoreGState()
}
final class Overlay: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = SnowEngine()
    let defaults = UserDefaults.standard
    var panels: [Overlay] = []
    var status: NSStatusItem!
    var timer: Timer?
    var paused = false
    var lastTick = ProcessInfo.processInfo.systemUptime
    var lastScan = 0.0
    var preserveSpaceSnowUntil = 0.0
    var spaceSlideUntil = 0.0
    var nextGust = 0.0
    var gustTarget = 0.0
    var randomWind = true
    var melt = 0.22
    var dockInset = 6.0
    var windowRadius = 26.0
    let dockResolver = DockResolver()
    var dockResolution: DockResolution?
    var lastStatusWrite = 0.0
    let dockID: UInt32 = 0xEFFFFFFF
    var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["intensity": 0.65, "melt": 0.22, "randomWind": true, "accumulation": true, "dockInset": 6.0, "windowRadiusV2": 26.0])
        engine.intensity = defaults.double(forKey: "intensity")
        melt = defaults.double(forKey: "melt")
        dockInset = defaults.double(forKey: "dockInset")
        windowRadius = defaults.double(forKey: "windowRadiusV2")
        randomWind = defaults.bool(forKey: "randomWind")
        engine.accumulation = defaults.bool(forKey: "accumulation")
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Desktop Snow")
        rebuildMenu()
        rebuildScreens()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildScreens), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
        timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        if CommandLine.arguments.contains("--request-accessibility") { allowDock() }
    }
    @objc func rebuildScreens() {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let rects = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: primaryTop - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        if !panels.isEmpty && engine.screens == rects {
            scanWindows()
            panels.forEach { $0.contentView?.needsDisplay = true }
            return
        }
        panels.forEach { $0.close() }
        panels.removeAll()
        engine.setScreens(rects)
        engine.menuBarRegions = screenLayouts().map(\.menuBarRegion)
        for (screen, rect) in zip(NSScreen.screens, rects) {
            for pass in [SnowPass.ground, SnowPass.foreground] {
                let panel = Overlay(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isFloatingPanel = true
                panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
                panel.ignoresMouseEvents = true
                // The system compositor keeps the real Dock (including icons) above ground snow.
                panel.level = pass == .ground ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
                    : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.contentView = SnowView(engine: engine, screen: rect, pass: pass)
                panel.setFrame(screen.frame, display: true)
                panel.orderFrontRegardless()
                panels.append(panel)
            }
        }
        scanWindows()
    }
    @objc func spaceChanged() {
        preserveSpaceSnowUntil = ProcessInfo.processInfo.systemUptime + 2
        dockResolver.lastCheck = -Double.infinity
        scanWindows(shedOnChange: false)
        lastScan = 0
        panels.forEach { $0.contentView?.needsDisplay = true }
    }
    @objc func sleeping() { timer?.fireDate = .distantFuture }
    @objc func waking() { lastTick = ProcessInfo.processInfo.systemUptime; timer?.fireDate = Date() }
    func scanWindows(shedOnChange: Bool = true) {
        engine.menuBarRegions = screenLayouts().map(\.menuBarRegion)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let allInfo = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? info
        let existingIDs = Set(allInfo.compactMap { $0[kCGWindowNumber as String] as? UInt32 }).union([dockID])
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var dockContainer: CGRect?
        var bundleIDs: [Int32: String] = [:]
        let layouts = screenLayouts()
        let windows: [SnowWindow] = info.compactMap { item in
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { return nil }
            let owner = item[kCGWindowOwnerName as String] as? String ?? ""
            let bundleID: String
            if let cached = bundleIDs[pid] { bundleID = cached }
            else { bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""; bundleIDs[pid] = bundleID }
            if WindowRules.isDesktopWidget(bundleID: bundleID, owner: owner, layer: layer, rect: rect, screens: engine.screens) {
                return WindowRules.widgetSurface(id: id, container: rect)
            }
            if layer > 0 && WindowRules.isNotificationCenter(bundleID: bundleID, owner: owner)
                && layouts.contains(where: { $0.isEdgeToEdge(rect) }) { return nil }
            // Dock includes wallpaper, helpers and tiny indicators: accept its visible shelf only.
            let dock = owner == "Dock" && layer > 0 && rect.width > 45 && rect.height > 30 && (rect.height < 250 || rect.width < 250)
            if dock { dockContainer = rect; return nil }
            // Quick Look and floating panels live above layer 0 and still occlude snow.
            guard layer >= 0 && layer < 24 && !["Dock", "Window Server", "MenuBarAgent"].contains(owner)
                && rect.width > 60 && rect.height > 40 else { return nil }
            let fullScreen = layer == 0 && layouts.contains { $0.isEdgeToEdge(rect) }
            let fillsDesktop = layer == 0 && !fullScreen && layouts.contains { $0.fillsWorkArea(rect) }
            let preview = owner.lowercased().contains("quicklook") || owner.lowercased().contains("quick look")
            let excluded = WindowRules.isCleanMyMac(bundleID: bundleID, owner: owner)
            return SnowWindow(id: id, rect: rect, cornerRadius: fullScreen ? 0 : windowRadius,
                collectsSnow: layer == 0 && !fullScreen && !fillsDesktop && !preview && !excluded, blocksFlakes: layer > 0 || preview, isFullscreen: fullScreen, isFill: fillsDesktop, ownerPID: pid, accumulationExcluded: excluded)
        }
        var surfaces = windows
        let fullscreenRegions = windows.filter(\.isFullscreen).map(\.rect)
        let fillRegions = windows.filter(\.isFill).map(\.rect)
        let now = ProcessInfo.processInfo.systemUptime
        // Quartz reports translated window frames during the Space animation,
        // before activeSpaceDidChange and before the fullscreen frame aligns.
        let isSlidingSpace = windows.contains { window in
            !window.isFullscreen && !window.isWidget && !window.blocksFlakes
                && layouts.contains { $0.isSlidingFullscreen(window.rect) }
        }
        if isSlidingSpace {
            spaceSlideUntil = now + 0.15
            preserveSpaceSnowUntil = now + 2
        }
        if fullscreenRegions != engine.fullscreenRegions {
            preserveSpaceSnowUntil = now + 2
        }
        let preserveSpaceSnow = !fullscreenRegions.isEmpty || now < preserveSpaceSnowUntil
        var fullscreenAbove: [CGRect] = []
        surfaces = windows.filter { window in
            if window.isFullscreen { fullscreenAbove.append(window.rect); return true }
            return !fullscreenAbove.contains { $0.contains(window.rect) }
        }
        engine.updateSparseRegions(fullscreen: fullscreenRegions, fill: fillRegions)
        engine.sideFilteredRegions = surfaces.filter { window in
            window.collectsSnow && !window.isWidget
                && layouts.contains { $0.spansWidth(window.rect) }
        }.map(\.rect)
        // Exactly one Dock collider: never keep both CG's wrapper and AX's shelf.
        dockResolution = dockResolver.resolve(cgContainer: dockContainer, allWindows: allInfo)
        if let resolution = dockResolution,
           !engine.fullscreenRegions.contains(where: { $0.intersects(resolution.shelf) }) {
            let container = resolution.shelf
            let dock = SnowWindow.dock(id: dockID, container: container, inset: resolution.estimated ? 0 : dockInset)
            surfaces.insert(dock, at: 0)
            // Protection uses the original footprint, unaffected by the landing adjustment.
            engine.dockProtection = [SnowWindow(id: dockID, rect: container, cornerRadius: dock.cornerRadius)]
        } else {
            // Ground remains below the native Dock even if its geometry is unavailable.
            engine.dockProtection = []
        }
        engine.sync(surfaces, existingIDs: existingIDs, shedOnChange: shedOnChange && !paused && now >= preserveSpaceSnowUntil, preserveMissing: preserveSpaceSnow)
    }
    func screenLayouts() -> [ScreenLayout] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { screen in
            let frame = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            let menuInset = max(NSStatusBar.system.thickness, max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY))
            let visible = screen.visibleFrame
            let workArea = CGRect(x: visible.minX, y: top - visible.maxY,
                                  width: visible.width, height: visible.height)
            return ScreenLayout(frame: frame, topInset: menuInset, workArea: workArea)
        }
    }
    @objc func allowDock() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, now - lastTick); lastTick = now
        if now - lastScan > (paused ? 0.2 : 1.0 / 20) {
            scanWindows()
            lastScan = now
            if paused { panels.forEach { $0.contentView?.needsDisplay = true } }
        }
        guard !paused else { return }
        if randomWind {
            if now >= nextGust { gustTarget = Double.random(in: -65...65); nextGust = now + Double.random(in: 5...14) }
        } else { gustTarget = 0 }
        engine.wind += (gustTarget - engine.wind) * dt * 0.45
        engine.meltRate = melt
        engine.step(dt, updateDrifts: now >= spaceSlideUntil)
        panels.forEach { $0.contentView?.needsDisplay = true }
        if now - lastStatusWrite > 2 { writeRuntimeStatus(); lastStatusWrite = now }
    }
    func writeRuntimeStatus() {
        let dock: [String: Any] = ["source": dockResolution?.source ?? "unavailable",
            "AXnote": dockResolver.lastAXNote,
            "visibleSurface": engine.isActive(dockID),
            "frame": dockResolution.map { NSStringFromRect($0.shelf) } ?? "none",
            "snowMax": engine.drifts[dockID]?.heights.max() ?? 0]
        let status: [String: Any] = ["accessibility": AXIsProcessTrusted(), "dock": dock,
            "particles": engine.flakes.count, "sideSpawns": engine.sideSpawnCount,
            "storedDrifts": engine.drifts.count, "visibleDrifts": engine.activeIDs.count,
            "windowRadius": windowRadius,
            "fullscreenRegions": engine.fullscreenRegions.map { NSStringFromRect($0) },
            "fillRegions": engine.fillRegions.map { NSStringFromRect($0) },
            "menuBarRegions": engine.menuBarRegions.map { NSStringFromRect($0) },
            "panels": engine.windows.filter(\.blocksFlakes).count,
            "desktopWidgets": engine.windows.filter(\.isWidget).map { ["frame": NSStringFromRect($0.rect), "snowMax": engine.drifts[$0.id]?.heights.max() ?? 0] }]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("DesktopSnow/runtime-status.json"), options: .atomic)
        }
    }
    func item(_ title: String, _ action: Selector, checked: Bool? = nil) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        if let checked { result.state = checked ? .on : .off }
        return result
    }
    func slider(_ title: String, value: Double, range: ClosedRange<Double>, action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 52))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 18, y: 29, width: 235, height: 18); label.font = .systemFont(ofSize: 12)
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
        slider.frame = NSRect(x: 18, y: 6, width: 234, height: 20)
        slider.isContinuous = true
        container.addSubview(label); container.addSubview(slider); item.view = container
        return item
    }
    func rebuildMenu() {
        let menu = NSMenu(); menu.delegate = self
        let title = NSMenuItem(title: "DESKTOP SNOW  ·  PIXEL EDITION", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item(paused ? "Продолжить снегопад" : "Пауза", #selector(togglePause)))
        menu.addItem(slider("Интенсивность: тихо → метель", value: engine.intensity, range: 0.1...2.5, action: #selector(setIntensity(_:))))
        menu.addItem(slider("Таяние: медленно → быстро", value: melt, range: 0.02...1.2, action: #selector(setMelt(_:))))
        menu.addItem(item("Случайные порывы ветра", #selector(toggleWind), checked: randomWind))
        menu.addItem(item("Сугробы на окнах, Dock и внизу", #selector(toggleAccumulation), checked: engine.accumulation))
        menu.addItem(slider("Посадка на Dock: выше → ниже", value: dockInset, range: 0...20, action: #selector(setDockInset(_:))))
        menu.addItem(slider("Скругление окон", value: windowRadius, range: 0...48, action: #selector(setWindowRadius(_:))))
        menu.addItem(item("Убрать весь снег", #selector(clearSnow)))
        menu.addItem(.separator())
        let dockStatus = NSMenuItem(title: "Dock: определение…", action: nil, keyEquivalent: "")
        dockStatus.tag = 901
        menu.addItem(dockStatus)
        menu.addItem(item("Запускать при входе", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled))
        if SMAppService.mainApp.status == .requiresApproval {
            menu.addItem(item("Разрешить автозапуск в настройках…", #selector(openLoginSettings)))
        }
        if !AXIsProcessTrusted() {
            menu.addItem(item("Разрешить точное определение Dock…", #selector(allowDock)))
        }
        menu.addItem(item("О приложении…", #selector(about)))
        menu.addItem(item("Завершить Desktop Snow", #selector(quit)))
        status.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        for entry in menu.items {
            if entry.action == #selector(toggleLogin) { entry.state = SMAppService.mainApp.status == .enabled ? .on : .off }
            if entry.tag == 901 {
                entry.title = dockResolution == nil ? "Dock: скрыт / не найден" : (dockResolution!.estimated ? "Dock: приблизительные границы" : "Dock: границы определены")
            }
        }
    }
    @objc func setWindowRadius(_ sender: NSSlider) {
        windowRadius = sender.doubleValue
        defaults.set(windowRadius, forKey: "windowRadiusV2")
        scanWindows()
    }
    @objc func setDockInset(_ sender: NSSlider) {
        dockInset = sender.doubleValue
        defaults.set(dockInset, forKey: "dockInset")
        scanWindows()
    }
    @objc func setIntensity(_ sender: NSSlider) { engine.intensity = sender.doubleValue; defaults.set(engine.intensity, forKey: "intensity") }
    @objc func setMelt(_ sender: NSSlider) { melt = sender.doubleValue; defaults.set(melt, forKey: "melt") }
    @objc func togglePause() { paused.toggle(); rebuildMenu() }
    @objc func toggleWind() { randomWind.toggle(); defaults.set(randomWind, forKey: "randomWind"); rebuildMenu() }
    @objc func toggleAccumulation() { engine.accumulation.toggle(); defaults.set(engine.accumulation, forKey: "accumulation"); clearSnow(); rebuildMenu() }
    @objc func clearSnow() { engine.clear(); panels.forEach { $0.contentView?.needsDisplay = true } }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showAlert("Автозапуск не включён", error.localizedDescription + "\nЗапускайте собранный Desktop Snow.app из постоянной папки.") }
        rebuildMenu()
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
    @objc func about() { showAlert("Desktop Snow ❄︎", "Пиксельная зима на рабочем столе.\n\nСнег осыпается с движущихся окон, ложится на Dock и постепенно тает. Несколько мониторов поддерживаются автоматически. Для точного определения Dock может потребоваться разрешение «Универсальный доступ» из меню приложения.\n\nПриложение читает геометрию окон, не записывает экран и не отправляет данные в сеть. Автозапуск включается отдельно в меню.") }
    @objc func quit() { NSApp.terminate(nil) }
}
