import AppKit

@MainActor
final class MenuBarController: NSObject {

    /// What's wrong right now, if anything. Surfaced in the menu-bar glyph and as
    /// a row at the top of the menu — previously you could only find out by
    /// opening the menu and noticing the readout had gone quiet.
    private enum Health: Equatable {
        case ok, noDisplay, noSensor, noDDC, ddcSilent, noBuiltin

        var message: String? {
            switch self {
            case .ok:        return nil
            case .noDisplay: return "no external display"
            case .noSensor:  return "light sensor unavailable"
            case .noDDC:     return "m1ddc not installed — brightness not controlled"
            case .ddcSilent: return "monitor isn\u{2019}t answering DDC — brightness not controlled"
            case .noBuiltin: return "lid closed — no brightness to follow"
            }
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// Not `let`: the HID service can be replaced across sleep/wake, which leaves
    /// our cached pointer stale and the sensor silently dead. Re-created after a
    /// run of failed reads.
    private var sensor = AmbientSensor()
    private var sensorFailures = 0
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
    private let strength = SliderRow(title: "Strength", min: 0, max: 100) { "\($0) %" }
    private let trim = SliderRow(title: "Trim", min: -1000, max: 1000,
                                 ends: ("Warmer", "Cooler"), bipolar: true) { k in
        k == 0 ? "0" : (k < 0 ? "warmer \(-k) K" : "cooler \(k) K")
    }
    private let brightness = SliderRow(title: "Mi brightness", min: 0, max: 100) { "\($0) %" }

    // menu items
    private let problem = ProblemView()
    private let problemItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let brightnessToggle = NSMenuItem(title: "Match MacBook", action: nil, keyEquivalent: "")
    private let calibrationReset = NSMenuItem(title: "Reset brightness match", action: nil, keyEquivalent: "")

    /// How MacBook brightness maps onto the Mi's backlight.
    private var brightnessMap = BrightnessMap()
    /// Last luminance we asked the panel for — the value calibration records.
    private var currentMiLum: Int?
    private var brightnessTimer: Timer?
    private let loginToggle = NSMenuItem(title: "Start at login", action: nil, keyEquivalent: "")
    private let menuBarToggle = NSMenuItem(title: "Hide icon", action: nil, keyEquivalent: "")

    /// The Mi's own luminance at launch — seeds the manual slider so the first
    /// hand-over doesn't jump. Deliberately *not* restored on quit.
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

        lastSyncedEnabled = settings.enabled
        lastSyncedMenuBar = settings.showInMenuBar
        lastSyncedPercent = settings.intensityPercent
        lastSyncedTrim = settings.trimK
        lastSyncedBright = settings.syncBrightness
        lastSyncedManual = settings.manualBrightnessPercent

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

        problemItem.view = problem
        problemItem.isEnabled = false
        problemItem.isHidden = true
        menu.addItem(problemItem)

        menu.addItem(.separator())
        menu.addItem(hosting(scale))

        menu.addItem(.sectionHeader(title: "Color"))
        menu.addItem(hosting(strength))
        menu.addItem(hosting(trim))

        menu.addItem(.sectionHeader(title: "Brightness"))
        brightnessToggle.target = self
        brightnessToggle.action = #selector(toggleBrightnessSync)
        brightnessToggle.toolTip = "The Mi's backlight follows the MacBook's brightness keys, over DDC"
        menu.addItem(brightnessToggle)
        menu.addItem(hosting(brightness))

        calibrationReset.target = self
        calibrationReset.action = #selector(resetCalibration)
        menu.addItem(calibrationReset)

        menu.addItem(.sectionHeader(title: "App"))
        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        if !LoginItem.isBundled {
            loginToggle.isEnabled = false
            loginToggle.toolTip = "available once installed via scripts/install.sh"
        }
        menu.addItem(loginToggle)

        menuBarToggle.target = self
        menuBarToggle.action = #selector(hideIcon)
        menuBarToggle.toolTip = "To bring it back: open TrueTone from Finder / Launchpad, or press ⌃⌥⌘T"
        menu.addItem(menuBarToggle)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
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
        calibrationReset.isHidden = !brightnessMap.isCalibrated
        calibrationReset.toolTip = brightnessMap.summary
        if !settings.syncBrightness { brightness.set(settings.manualBrightnessPercent) }
        loginToggle.state = LoginItem.isEnabled ? .on : .off

        if let msg = health.message {
            problem.set(msg)
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
        DDCBrightness.prepare()          // resolves the display index off-main
        guard originalLuminance == nil else { return }
        DDCBrightness.readAsync { [weak self] level in
            guard let self, let level, self.originalLuminance == nil else { return }
            self.originalLuminance = level
            if self.settings.manualBrightnessPercent == 100 {
                self.settings.manualBrightnessPercent = level
            }
            self.refreshUI()
            self.log(String(format: "[resolve] panel native=%.0fK ddc=%@ origLum=%d",
                            self.model.nativeCCT,
                            DDCBrightness.isAvailable ? "ok" : "none", level))
        }
    }

    private func setTrim(_ k: Int) {
        settings.trimK = k
        model.trimK = Double(k)
        tick()
    }

    @objc private func toggleBrightnessSync() {
        settings.syncBrightness.toggle()
        if settings.syncBrightness {
            // Switching sync back on after setting the Mi by hand *is* the
            // calibration: "at this MacBook level I wanted this much backlight".
            // No separate Match-now button, no instructions to follow first.
            if let bb = BuiltinBrightness.read() {
                brightnessMap.record(builtin: bb, luminance: settings.manualBrightnessPercent)
                settings.brightnessMap = brightnessMap
                log("[calib] \(brightnessMap.summary)")
            }
        } else if let now = currentMiLum ?? originalLuminance {
            // Hand manual control over at the level the panel is actually at, so
            // switching modes doesn't jump the brightness.
            settings.manualBrightnessPercent = now
        }
        refreshUI()
        tick()
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
        // Gamma is our overlay, so it must come off. The backlight is not: it's a
        // real setting the user sees and can change on the monitor itself, so
        // snapping it back to whatever it was at launch would mean quitting at
        // night flashes the screen back to a daytime level. Leave it as it is.
        display.restore()
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
            currentMiLum = DDCBrightness.isAvailable ? target : nil
        } else {
            let target = settings.manualBrightnessPercent
            DDCBrightness.set(target)
            currentMiLum = DDCBrightness.isAvailable ? target : nil
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

        var reading = sensor?.read()
        if reading == nil {
            sensorFailures += 1
            if sensorFailures >= 10 {          // ~5 s of nothing — the service may
                sensorFailures = 0             // have been replaced across a wake
                sensor = AmbientSensor()
                reading = sensor?.read()
                log("[sensor] re-created: \(sensor == nil ? "still nil" : "ok")")
            }
        } else {
            sensorFailures = 0
        }
        let hasDisplay = externalDisplayPresent()

        let newHealth: Health =
            !hasDisplay ? .noDisplay
            : sensor == nil || reading == nil ? .noSensor
            : (settings.syncBrightness && !DDCBrightness.isInstalled) ? .noDDC
            : (settings.syncBrightness && !DDCBrightness.isAvailable) ? .ddcSilent
            // Clamshell: nothing to follow, so sync looks on but does nothing.
            : (settings.syncBrightness && BuiltinBrightness.read() == nil) ? .noBuiltin
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
                         detail: health.message ?? "adaptation off",
                         caption: isEnabled ? "waiting for data" : "off")
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
            if let lum = miLuminance { detail += String(format: "   ·   brightness %d %%", lum) }
            // In the dark the sensor's colour reading is nonsense (a few hundred
            // Kelvin) — say so rather than printing it as if it meant something.
            let usable = model.isReadingUsable(lux: rd.lux, ambientCCT: rd.cct)
            scale.update(ambientK: usable ? rd.cct : nil,
                         screenK: model.displayCCT,
                         detail: detail,
                         caption: usable
                            ? String(format: "light %.0f K  →  screen %.0f K", rd.cct, model.displayCCT)
                            : String(format: "too dark  ·  screen %.0f K", model.displayCCT))
        }

        log(String(format: "tt=on  mi-lum=%@  gains %.3f/%.3f/%.3f",
                   miLuminance.map(String.init) ?? "-", g.r, g.g, g.b))
    }
}
