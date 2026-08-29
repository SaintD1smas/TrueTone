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

    private let debug = ProcessInfo.processInfo.environment["TRUETONE_DEBUG"] == "1"
    private let forceOn = ProcessInfo.processInfo.environment["TRUETONE_FORCE_ON"] == "1"
    private var signalSources: [DispatchSourceSignal] = []

    private var isEnabled: Bool { settings.enabled || forceOn }

    private let header = HeaderView()
    private let readout = ReadoutView()
    private let strength = StrengthView()
    private let loginToggle = NSMenuItem(title: "Автозапуск при входе", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        model.intensity = Double(settings.intensityPercent) / 100.0
        // Stable identity so macOS tracks this item's visibility by name instead
        // of an anonymous "Item-N" slot that Sequoia readily hides.
        statusItem.autosaveName = "com.dmitriy.truetone.status"
        statusItem.behavior = []
        buildMenu()
        refreshUI()
        installSignalHandlers()

        if sensor == nil { readout.message("⚠️ датчик света недоступен") }

        log(String(format: "[init] button=%@ isVisible=%@ policy=%ld screens=%d",
                   statusItem.button != nil ? "ok" : "NIL", "\(statusItem.isVisible)",
                   NSApp.activationPolicy().rawValue, NSScreen.screens.count))

        lastTick = Date()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
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

        menu.addItem(hosting(header))
        menu.addItem(.separator())
        menu.addItem(hosting(readout))
        menu.addItem(hosting(strength))
        menu.addItem(.separator())

        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        if !LoginItem.isBundled {
            loginToggle.isEnabled = false
            loginToggle.toolTip = "доступно после установки через scripts/install.sh"
        }
        menu.addItem(loginToggle)

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
        loginToggle.state = LoginItem.isEnabled ? .on : .off

        statusItem.isVisible = true
        if let b = statusItem.button {
            b.image = Self.icon(enabled: isEnabled)
            b.imagePosition = .imageOnly
            b.toolTip = "TrueTone"
        }
    }

    /// Drawn menu-bar icon — a half-filled circle. No SF Symbols dependency, so
    /// it can never silently fail to load.
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

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        loginToggle.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func quit() {
        display.restore()
        NSApp.terminate(nil)
    }

    func shutdown() { display.restore() }

    /// A killed / Ctrl-C'd process must never leave the monitor tinted. SIGHUP is
    /// only ignored (so a terminal-launched instance survives the terminal closing).
    private func installSignalHandlers() {
        signal(SIGHUP, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.display.restore()
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

    private func tick() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTick), 0.01)
        lastTick = now

        if statusItem.isVisible == false { statusItem.isVisible = true }   // re-assert vs Sequoia

        let reading = sensor?.read()

        guard isEnabled else {
            if display.isTinted { display.restore() }
            if let rd = reading {
                readout.message(String(format: "выкл · свет %.0f K · %.0f lx", rd.cct, rd.lux))
            } else {
                readout.message("выкл")
            }
            return
        }

        guard let rd = reading else {
            readout.message("⚠️ нет данных с датчика")
            return
        }

        model.update(lux: rd.lux, ambientCCT: rd.cct, dt: dt)
        let g = model.rgbGains()
        display.apply(r: g.r, g: g.g, b: g.b)
        readout.update(ambientK: rd.cct, screenK: model.displayCCT, lux: rd.lux,
                       tint: NSColor(srgbRed: g.r, green: g.g, blue: g.b, alpha: 1))

        log(String(format: "on  %4.0flx ambient %5.0fK -> screen %5.0fK  gains %.3f/%.3f/%.3f",
                   rd.lux, rd.cct, model.displayCCT, g.r, g.g, g.b))
    }
}
