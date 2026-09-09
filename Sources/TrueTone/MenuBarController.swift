import AppKit

@MainActor
final class MenuBarController: NSObject {

    /// What's wrong right now, if anything. Surfaced in the menu-bar glyph and as
    /// a row at the top of the menu — previously you could only find out by
    /// opening the menu and noticing the readout had gone quiet.
    private enum Health: Equatable {
        case ok, noDisplay, noSensor, noDDC

        var message: String? {
            switch self {
            case .ok:        return nil
            case .noDisplay: return "внешний монитор не подключён"
            case .noSensor:  return "датчик света недоступен"
            case .noDDC:     return "нет m1ddc — яркостью не управляем"
            }
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sensor = AmbientSensor()
    private var model = WhitePointModel()
    private let display = DisplayController()
    private var settings = Settings()

    private var timer: Timer?
    private var lastTick = Date()
    private var hotKey: HotKey?
    private var health: Health = .ok

    private let debug = ProcessInfo.processInfo.environment["TRUETONE_DEBUG"] == "1"
    private let forceOn = ProcessInfo.processInfo.environment["TRUETONE_FORCE_ON"] == "1"
    private var signalSources: [DispatchSourceSignal] = []

    private var isEnabled: Bool { settings.enabled || forceOn }

    // views
    private let header = HeaderView()
    private let scale = ScaleView()
    private let strength = SliderRow(title: "Сила", min: 0, max: 100) { "\($0) %" }
    private let trim = SliderRow(title: "Подстройка", min: -1000, max: 1000,
                                 hint: "← теплее   ·   холоднее →", bipolar: true) { k in
        k == 0 ? "0" : (k < 0 ? "теплее \(-k) K" : "холоднее \(k) K")
    }
    private let brightness = SliderRow(title: "Яркость Mi", min: 0, max: 100) { "\($0) %" }

    // menu items
    private let problemItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let brightnessToggle = NSMenuItem(title: "Как на MacBook", action: nil, keyEquivalent: "")
    private let calibrateItem = NSMenuItem(title: "Совместить сейчас", action: nil, keyEquivalent: "")
    private let calibrationInfo = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let calibrationReset = NSMenuItem(title: "Сбросить калибровку", action: nil, keyEquivalent: "")

    /// How MacBook brightness maps onto the Mi's backlight.
    private var brightnessMap = BrightnessMap()
    /// Last luminance we asked the panel for — the value calibration records.
    private var currentMiLum: Int?
    private var brightnessTimer: Timer?
    private let loginToggle = NSMenuItem(title: "Автозапуск при входе", action: nil, keyEquivalent: "")
    private let menuBarToggle = NSMenuItem(title: "Скрыть иконку", action: nil, keyEquivalent: "")

    /// The Mi's own luminance before we touched it — restored on quit.
    private var originalLuminance: Int?

    private var lastSyncedEnabled = false
    private var lastSyncedMenuBar = true
    private var lastSyncedPercent = -1
    private var lastSyncedTrim = 0
    private var lastSyncedBright = false
    private var lastSyncedManual = 100

    // The startup luminance read can fail transiently — a read right after a
    // write returns an error on this panel, and the previous instance writes on
    // its way out. Retry a few times, spaced out, instead of giving up.
    private var lumProbeAt: Date = .distantPast
    private var lumProbes = 0

    override init() {
        super.init()
        model.intensity = Double(settings.intensityPercent) / 100.0
        model.trimK = Double(settings.trimK)
        brightnessMap = settings.brightnessMap
        display.onDisplaysChanged = { [weak self] in self?.resolvePanel() }
        resolvePanel()

        statusItem.autosaveName = "com.dmitriy.truetone.status"
        buildMenu()
        refreshUI()
        installSignalHandlers()

        hotKey = HotKey { [weak self] in self?.revealMenu() }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleRevealNotification),
            name: .init("com.dmitriy.truetone.reveal"), object: nil)

        lastTick = Date()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Brightness needs a faster loop than the colour path: at 0.5 s the Mi
        // visibly trailed the brightness keys. This only reads the built-in level
        // (cheap, no DDC) and lets DDCBrightness rate-limit the writes.
        let bt = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBrightness() }
        }
        RunLoop.main.add(bt, forMode: .common)
        brightnessTimer = bt

        tick()
    }

    // MARK: menu

    private func buildMenu() {
        let menu = NSMenu()

        header.onToggle = { [weak self] on in self?.setEnabled(on) }
        strength.onChange = { [weak self] v in self?.setIntensity(v) }
        trim.step = 50
        trim.onChange = { [weak self] v in self?.setTrim(v) }
        brightness.onChange = { [weak self] v in self?.setManualBrightness(v) }

        menu.addItem(hosting(header))

        problemItem.isEnabled = false
        problemItem.isHidden = true
        menu.addItem(problemItem)

        menu.addItem(.separator())
        menu.addItem(hosting(scale))

        menu.addItem(.sectionHeader(title: "Цвет"))
        menu.addItem(hosting(strength))
        menu.addItem(hosting(trim))

        menu.addItem(.sectionHeader(title: "Яркость"))
        brightnessToggle.target = self
        brightnessToggle.action = #selector(toggleBrightnessSync)
        brightnessToggle.toolTip = "Подсветка Mi едет за клавишами яркости MacBook (по DDC)"
        menu.addItem(brightnessToggle)
        menu.addItem(hosting(brightness))

        calibrateItem.target = self
        calibrateItem.action = #selector(calibrateBrightness)
        calibrateItem.toolTip = """
            Выключи «Как на MacBook», подгони ползунком, чтобы экраны совпали, и нажми.
            Повтори на заметно другой яркости MacBook — две точки задают и совпадение, и диапазон.
            """
        menu.addItem(calibrateItem)

        calibrationInfo.isEnabled = false
        calibrationInfo.indentationLevel = 1
        menu.addItem(calibrationInfo)

        calibrationReset.target = self
        calibrationReset.action = #selector(resetCalibration)
        calibrationReset.indentationLevel = 1
        menu.addItem(calibrationReset)

        menu.addItem(.sectionHeader(title: "Приложение"))
        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        if !LoginItem.isBundled {
            loginToggle.isEnabled = false
            loginToggle.toolTip = "доступно после установки через scripts/install.sh"
        }
        menu.addItem(loginToggle)

        menuBarToggle.target = self
        menuBarToggle.action = #selector(hideIcon)
        menuBarToggle.toolTip = "Вернуть: открыть TrueTone в Finder / Launchpad, или ⌃⌥⌘T"
        menu.addItem(menuBarToggle)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func hosting(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func refreshUI() {
        header.set(on: isEnabled)
        strength.set(settings.intensityPercent)
        trim.set(settings.trimK)
        brightnessToggle.state = settings.syncBrightness ? .on : .off
        brightnessToggle.isEnabled = DDCBrightness.isAvailable
        brightness.setEnabled(!settings.syncBrightness && DDCBrightness.isAvailable)
        // Recording an anchor while sync drives the panel would just re-affirm the
        // current line — and could displace a good anchor. Calibrate with sync off.
        calibrateItem.isEnabled = DDCBrightness.isAvailable && !settings.syncBrightness
        calibrateItem.toolTip = settings.syncBrightness
            ? "Сначала выключи «Как на MacBook» и подгони ползунком"
            : "Запомнить, что сейчас экраны совпадают. Повтори на другой яркости MacBook."
        calibrationInfo.title = brightnessMap.summary
        calibrationInfo.isHidden = !brightnessMap.isCalibrated
        calibrationReset.isHidden = !brightnessMap.isCalibrated
        if !settings.syncBrightness { brightness.set(settings.manualBrightnessPercent) }
        loginToggle.state = LoginItem.isEnabled ? .on : .off

        if let msg = health.message {
            problemItem.title = "⚠︎  " + msg
            problemItem.isHidden = false
        } else {
            problemItem.isHidden = true
        }

        statusItem.isVisible = settings.showInMenuBar
        if let b = statusItem.button {
            b.image = Self.icon(enabled: isEnabled, problem: health != .ok)
            b.imagePosition = .imageOnly
            b.toolTip = health.message.map { "TrueTone — " + $0 } ?? "TrueTone"
        }
    }

    /// Menu-bar glyph: a ring that fills on the left when adapting, with a slash
    /// when something needs attention. Drawn rather than an SF Symbol so it can
    /// never silently fail to load.
    private static func icon(enabled: Bool, problem: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let r = rect.insetBy(dx: 2.5, dy: 2.5)
            let c = NSPoint(x: r.midX, y: r.midY)

            if enabled {
                let half = NSBezierPath()
                half.move(to: c)
                half.appendArc(withCenter: c, radius: r.width / 2, startAngle: 90, endAngle: 270)
                half.close()
                NSColor.black.setFill()
                half.fill()
            }
            let ring = NSBezierPath(ovalIn: r)
            ring.lineWidth = enabled ? 1.5 : 1.2
            NSColor.black.setStroke()
            ring.stroke()

            if problem {
                // knock a gap out of the glyph, then draw the slash in it
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: r.minX + 2.6, y: r.minY + 2.6))
                slash.line(to: NSPoint(x: r.maxX - 2.6, y: r.maxY - 2.6))
                NSColor.black.setStroke()
                NSGraphicsContext.current?.compositingOperation = .clear
                slash.lineWidth = 3
                slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                slash.lineWidth = 1.5
                slash.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: actions

    private func setEnabled(_ on: Bool) {
        settings.enabled = on
        model.resetToNative()
        if !isEnabled { display.restore() }
        refreshUI()
        tick()
    }

    private func setIntensity(_ pct: Int) {
        settings.intensityPercent = pct
        model.intensity = Double(pct) / 100.0
        tick()
    }

    /// Read whatever depends on the external panel actually being attached. The
    /// app autostarts at login and the Mi can take ~10 s to appear, so this must
    /// be re-runnable — doing it once at init left the colour math on the sRGB
    /// fallback and brightness sync dead after every reboot.
    private func resolvePanel() {
        if let profile = PanelProfile.forExternalDisplay() {
            model.panel = profile
            model.nativeCCT = profile.nativeCCT
        }
        if originalLuminance == nil, let level = DDCBrightness.read() {
            originalLuminance = level
            if settings.manualBrightnessPercent == 100 {
                settings.manualBrightnessPercent = level
            }
        }
        log(String(format: "[resolve] panel native=%.0fK ddc=%@ origLum=%@",
                   model.nativeCCT,
                   DDCBrightness.isAvailable ? "ok" : "нет",
                   originalLuminance.map(String.init) ?? "—"))
    }

    private func setTrim(_ k: Int) {
        settings.trimK = k
        model.trimK = Double(k)
        tick()
    }

    @objc private func toggleBrightnessSync() {
        settings.syncBrightness.toggle()
        if !settings.syncBrightness, let o = originalLuminance {
            settings.manualBrightnessPercent = o
            DDCBrightness.set(o)
        }
        refreshUI()
        tick()
    }

    /// Record "the screens match right now". Two such points, taken at clearly
    /// different MacBook levels, define both the offset and the slope — which is
    /// why there are no separate min/max controls.
    @objc private func calibrateBrightness() {
        guard let bb = BuiltinBrightness.read(), let lum = currentMiLum else { return }
        brightnessMap.record(builtin: bb, luminance: lum)
        settings.brightnessMap = brightnessMap
        refreshUI()
        log("[calib] \(brightnessMap.summary)")
    }

    @objc private func resetCalibration() {
        brightnessMap.reset()
        settings.brightnessMap = brightnessMap
        refreshUI()
    }

    /// Dragging the manual slider takes over from the MacBook sync.
    private func setManualBrightness(_ pct: Int) {
        settings.manualBrightnessPercent = pct
        if settings.syncBrightness { settings.syncBrightness = false }
        refreshUI()
        tick()
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        loginToggle.state = LoginItem.isEnabled ? .on : .off
    }

    /// Menu item: hide the icon. The hotkey / `truetone show` brings it back.
    @objc private func hideIcon() {
        settings.showInMenuBar = false
        statusItem.isVisible = false
    }

    /// Bring the icon back (if hidden) and open the menu. Used by the ⌃⌥⌘T hotkey
    /// and by re-opening the app from Finder / Launchpad.
    func revealMenu() {
        settings.showInMenuBar = true
        lastSyncedMenuBar = true
        statusItem.isVisible = true
        refreshUI()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let button = self.statusItem.button, button.window != nil {
                button.performClick(nil)
            } else if let menu = self.statusItem.menu,
                      let vf = NSScreen.main?.visibleFrame {
                menu.popUp(positioning: nil, at: NSPoint(x: vf.maxX - 24, y: vf.maxY - 6), in: nil)
            }
        }
    }

    @objc private func handleRevealNotification() { revealMenu() }

    @objc private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    func shutdown() {
        display.restore()
        if let o = originalLuminance { DDCBrightness.setNow(o) }
    }

    private func installSignalHandlers() {
        signal(SIGHUP, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func log(_ s: String) {
        guard debug else { return }
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    // MARK: loop

    /// Pick up changes made outside the menu (the `truetone` CLI writes to
    /// UserDefaults); apply within one tick.
    private func reconcile() {
        if statusItem.isVisible != settings.showInMenuBar {
            statusItem.isVisible = settings.showInMenuBar
        }
        let changed = settings.enabled != lastSyncedEnabled
            || settings.showInMenuBar != lastSyncedMenuBar
            || settings.intensityPercent != lastSyncedPercent
            || settings.trimK != lastSyncedTrim
            || settings.syncBrightness != lastSyncedBright
            || settings.manualBrightnessPercent != lastSyncedManual
        if changed {
            model.intensity = Double(settings.intensityPercent) / 100.0
            model.trimK = Double(settings.trimK)
            if settings.enabled != lastSyncedEnabled { model.resetToNative() }
            if !isEnabled { display.restore() }
            refreshUI()
            lastSyncedEnabled = settings.enabled
            lastSyncedMenuBar = settings.showInMenuBar
            lastSyncedPercent = settings.intensityPercent
            lastSyncedTrim = settings.trimK
            lastSyncedBright = settings.syncBrightness
            lastSyncedManual = settings.manualBrightnessPercent
        }
    }

    private func externalDisplayPresent() -> Bool {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        return ids.contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Drive the Mi's backlight. Runs on its own fast timer so the panel keeps up
    /// with the brightness keys; DDCBrightness coalesces the actual writes.
    private func updateBrightness() {
        if settings.syncBrightness {
            guard let bb = BuiltinBrightness.read() else { return }
            let target = brightnessMap.luminance(forBuiltin: bb)
            DDCBrightness.set(target)
            if currentMiLum != target {
                brightness.set(target)          // mirror on the disabled slider
                log(String(format: "[bright] bb=%.3f -> %d (%@)", bb, target, brightnessMap.summary))
            }
            currentMiLum = target
        } else {
            let target = settings.manualBrightnessPercent
            DDCBrightness.set(target)
            currentMiLum = target
        }
    }

    private func tick() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTick), 0.01)
        lastTick = now

        reconcile()

        if originalLuminance == nil, lumProbes < 8,
           now.timeIntervalSince(lumProbeAt) > 3 {
            lumProbeAt = now
            lumProbes += 1
            resolvePanel()
        }

        let reading = sensor?.read()
        let hasDisplay = externalDisplayPresent()

        let newHealth: Health =
            !hasDisplay ? .noDisplay
            : sensor == nil || reading == nil ? .noSensor
            : (settings.syncBrightness && !DDCBrightness.isAvailable) ? .noDDC
            : .ok
        if newHealth != health {
            health = newHealth
            settings.healthNote = newHealth.message ?? "ok"
            refreshUI()
        }

        let ttActive = isEnabled && reading != nil && hasDisplay

        updateBrightness()
        let miLuminance = currentMiLum

        guard ttActive else {
            if display.isTinted { display.restore() }
            scale.update(ambientK: reading?.cct, screenK: nil,
                         detail: health.message ?? "адаптация выключена",
                         caption: isEnabled ? "ждём данных" : "выключено")
            return
        }

        var g = (r: 1.0, g: 1.0, b: 1.0)
        if let rd = reading {
            model.update(lux: rd.lux, ambientCCT: rd.cct, dt: dt)
            g = model.rgbGains()
        }
        display.apply(r: g.r, g: g.g, b: g.b)

        if let rd = reading {
            var detail = String(format: "%.0f lx", rd.lux)
            if let lum = miLuminance { detail += String(format: "   ·   яркость %d %%", lum) }
            // In the dark the sensor's colour reading is nonsense (a few hundred
            // Kelvin) — say so rather than printing it as if it meant something.
            let usable = model.isReadingUsable(lux: rd.lux, ambientCCT: rd.cct)
            scale.update(ambientK: usable ? rd.cct : nil,
                         screenK: model.displayCCT,
                         detail: detail,
                         caption: usable
                            ? String(format: "свет %.0f K  →  экран %.0f K", rd.cct, model.displayCCT)
                            : String(format: "слишком темно  ·  экран %.0f K", model.displayCCT))
        }

        log(String(format: "tt=on  mi-lum=%@  gains %.3f/%.3f/%.3f",
                   miLuminance.map(String.init) ?? "-", g.r, g.g, g.b))
    }
}
