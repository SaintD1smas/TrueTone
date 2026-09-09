import AppKit

@MainActor
final class MenuBarController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sensor = AmbientSensor()
    private var model = WhitePointModel()
    private let display = DisplayController()
    private var settings = Settings()

    private var timer: Timer?
    private var lastTick = Date()
    private var hotKey: HotKey?

    private let debug = ProcessInfo.processInfo.environment["TRUETONE_DEBUG"] == "1"
    private let forceOn = ProcessInfo.processInfo.environment["TRUETONE_FORCE_ON"] == "1"
    private var signalSources: [DispatchSourceSignal] = []

    private var isEnabled: Bool { settings.enabled || forceOn }

    private let header = HeaderView()
    private let readout = ReadoutView()
    private let strength = StrengthView()
    private let trim = TrimView()
    private let brightnessSlider = BrightnessView()
    private let loginToggle = NSMenuItem(title: "Автозапуск при входе", action: nil, keyEquivalent: "")
    private let brightnessToggle = NSMenuItem(title: "Яркость как на MacBook", action: nil, keyEquivalent: "")

    /// The Mi's own luminance before we touched it — restored on quit.
    private var originalLuminance: Int?
    private let menuBarToggle = NSMenuItem(title: "Скрыть иконку", action: nil, keyEquivalent: "")

    private var lastSyncedEnabled = false
    private var lastSyncedMenuBar = true
    private var lastSyncedPercent = -1
    private var lastSyncedTrim = 0
    private var lastSyncedBright = false
    private var lastSyncedManual = 100

    override init() {
        super.init()
        model.intensity = Double(settings.intensityPercent) / 100.0
        model.trimK = Double(settings.trimK)
        // Stable identity so macOS tracks this item's visibility by name.
        statusItem.autosaveName = "com.dmitriy.truetone.status"
        buildMenu()
        refreshUI()
        installSignalHandlers()

        hotKey = HotKey { [weak self] in self?.revealMenu() }

        // A second launch of the app posts this; we bring the menu up.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleRevealNotification),
            name: .init("com.dmitriy.truetone.reveal"), object: nil)

        if sensor == nil { readout.message("⚠️ датчик света недоступен") }

        // Remember the panel's own backlight level once, while nothing is writing
        // (reads right after a write come back as errors on this monitor).
        originalLuminance = DDCBrightness.read()
        if settings.manualBrightnessPercent == 100, let o = originalLuminance {
            settings.manualBrightnessPercent = o
        }

        lastTick = Date()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: menu

    private func buildMenu() {
        let menu = NSMenu()

        header.onToggle = { [weak self] on in self?.setEnabled(on) }
        strength.onChange = { [weak self] pct in self?.setIntensity(pct) }
        trim.onChange = { [weak self] k in self?.setTrim(k) }
        brightnessSlider.onChange = { [weak self] pct in self?.setManualBrightness(pct) }

        menu.addItem(hosting(header))
        menu.addItem(.separator())
        menu.addItem(hosting(readout))
        menu.addItem(hosting(strength))
        menu.addItem(hosting(trim))
        menu.addItem(hosting(brightnessSlider))
        menu.addItem(.separator())

        brightnessToggle.target = self
        brightnessToggle.action = #selector(toggleBrightnessSync)
        brightnessToggle.toolTip = "Подсветка Mi едет за клавишами яркости MacBook (по DDC)"
        if !DDCBrightness.isAvailable {
            brightnessToggle.isEnabled = false
            brightnessToggle.toolTip = "нужен m1ddc: brew install m1ddc"
        }
        menu.addItem(brightnessToggle)

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
        brightnessSlider.setEnabled(!settings.syncBrightness)
        if !settings.syncBrightness { brightnessSlider.set(settings.manualBrightnessPercent) }
        loginToggle.state = LoginItem.isEnabled ? .on : .off

        statusItem.isVisible = settings.showInMenuBar
        if let b = statusItem.button {
            b.image = Self.icon(enabled: isEnabled)
            b.imagePosition = .imageOnly
            b.toolTip = "TrueTone"
        }
    }

    /// Drawn menu-bar icon — a half-filled circle. No SF Symbols dependency.
    private static func icon(enabled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let r = rect.insetBy(dx: 2.5, dy: 2.5)
            let ring = NSBezierPath(ovalIn: r)
            ring.lineWidth = 1.4
            NSColor.black.setStroke()
            ring.stroke()
            if enabled {
                let half = NSBezierPath()
                let c = NSPoint(x: r.midX, y: r.midY)
                half.move(to: c)
                half.appendArc(withCenter: c, radius: r.width / 2, startAngle: 90, endAngle: 270)
                half.close()
                NSColor.black.setFill()
                half.fill()
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

    private func setTrim(_ k: Int) {
        settings.trimK = k
        model.trimK = Double(k)
        tick()
    }

    @objc private func toggleBrightnessSync() {
        settings.syncBrightness.toggle()
        if !settings.syncBrightness, let o = originalLuminance {
            settings.manualBrightnessPercent = o        // hand control back at the panel's own level
            DDCBrightness.set(o)
        }
        refreshUI()
        tick()
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

        // Give the status bar a beat to lay the item out, then click it so the
        // menu anchors under the real icon.
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
        display.restore()
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
            if !isEnabled { display.restore() }   // colour only; brightness is DDC now
            refreshUI()
            lastSyncedEnabled = settings.enabled
            lastSyncedMenuBar = settings.showInMenuBar
            lastSyncedPercent = settings.intensityPercent
            lastSyncedTrim = settings.trimK
            lastSyncedBright = settings.syncBrightness
            lastSyncedManual = settings.manualBrightnessPercent
        }
    }

    private func tick() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTick), 0.01)
        lastTick = now

        reconcile()

        let reading = sensor?.read()
        let ttActive = isEnabled && reading != nil

        // --- real backlight over DDC (not a gamma fake) ---
        var miLuminance: Int?
        if settings.syncBrightness, let bb = BuiltinBrightness.read() {
            let target = min(max(Int((bb * 100).rounded()), 5), 100)
            DDCBrightness.set(target)
            miLuminance = target
            brightnessSlider.set(target)          // reflect on the disabled slider
        } else if !settings.syncBrightness {
            let target = settings.manualBrightnessPercent
            DDCBrightness.set(target)
            miLuminance = target
        }

        guard ttActive else {
            if display.isTinted { display.restore() }
            readout.message(isEnabled && reading == nil
                ? "⚠️ нет данных с датчика"
                : (reading.map { String(format: "выкл · свет %.0f K · %.0f lx", $0.cct, $0.lux) } ?? "выкл"))
            return
        }

        var g = (r: 1.0, g: 1.0, b: 1.0)
        if let rd = reading {
            model.update(lux: rd.lux, ambientCCT: rd.cct, dt: dt)
            g = model.rgbGains()
        }
        display.apply(r: g.r, g: g.g, b: g.b)

        if let rd = reading {
            readout.update(ambientK: rd.cct,
                           screenK: model.displayCCT,
                           lux: rd.lux,
                           tint: NSColor(srgbRed: g.r, green: g.g, blue: g.b, alpha: 1),
                           bright: miLuminance.map { Double($0) / 100.0 })
        }

        log(String(format: "tt=on  mi-lum=%@  gains %.3f/%.3f/%.3f",
                   miLuminance.map(String.init) ?? "-", g.r, g.g, g.b))
    }

    private let nativeCCT: Double = 6500
}
