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
    private var sweepStart: Date?

    private let debug = ProcessInfo.processInfo.environment["TRUETONE_DEBUG"] == "1"
    private let forceOn = ProcessInfo.processInfo.environment["TRUETONE_FORCE_ON"] == "1"
    private var signalSources: [DispatchSourceSignal] = []

    /// Effective on/off — the persisted setting, or an env override for smoke tests.
    private var isEnabled: Bool { settings.enabled || forceOn }

    private let readoutItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let strengthSlider = StrengthSliderView()

    override init() {
        super.init()
        model.intensity = Double(settings.intensityPercent) / 100.0
        buildMenu()
        refreshToggleUI()
        installSignalHandlers()

        if sensor == nil { readoutItem.title = "⚠️ датчик света недоступен" }

        log(String(format: "[init] button=%@ isVisible=%@ length=%.1f policy=%ld screens=%d",
                   statusItem.button != nil ? "ok" : "NIL", "\(statusItem.isVisible)",
                   statusItem.length, NSApp.activationPolicy().rawValue, NSScreen.screens.count))

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

        toggleItem.target = self
        toggleItem.action = #selector(toggle)
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        readoutItem.isEnabled = false
        menu.addItem(readoutItem)

        strengthSlider.set(settings.intensityPercent)
        strengthSlider.onChange = { [weak self] pct in self?.setIntensity(pct) }
        let strengthHost = NSMenuItem()
        strengthHost.view = strengthSlider
        menu.addItem(strengthHost)

        menu.addItem(.separator())
        let sweep = NSMenuItem(title: "Тест: развёртка 10 с", action: #selector(startSweep), keyEquivalent: "")
        sweep.target = self
        menu.addItem(sweep)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func refreshToggleUI() {
        toggleItem.title = isEnabled
            ? "True Tone для внешнего монитора: вкл"
            : "True Tone для внешнего монитора: выкл"
        toggleItem.state = isEnabled ? .on : .off

        statusItem.isVisible = true
        if let b = statusItem.button {
            b.image = Self.icon(enabled: isEnabled)
            b.imagePosition = .imageOnly
            b.toolTip = "TrueTone"
        }
    }

    /// Drawn menu-bar icon — a half-filled circle. No SF Symbols dependency, so
    /// it can never silently fail to load and leave the status item invisible.
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

    @objc private func toggle() {
        settings.enabled.toggle()
        model.resetToNative()
        if !isEnabled { display.restore() }
        refreshToggleUI()
        tick()
    }

    private func setIntensity(_ pct: Int) {
        settings.intensityPercent = pct
        model.intensity = Double(pct) / 100.0
        tick()
    }

    @objc private func startSweep() { sweepStart = Date() }

    @objc private func quit() {
        display.restore()
        NSApp.terminate(nil)
    }

    /// Called from applicationWillTerminate — make sure gamma is back to normal
    /// whatever the termination path.
    func shutdown() {
        display.restore()
    }

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

        if let s = sweepStart {
            let e = now.timeIntervalSince(s)
            if e >= 10 {
                sweepStart = nil
                if !isEnabled { display.restore() }
            } else {
                let phase = e / 10.0
                let k = phase < 0.5
                    ? lerp(6500, 4000, phase * 2)
                    : lerp(4000, 6500, (phase - 0.5) * 2)
                let g = WhitePointModel.gains(fromCCT: k, nativeCCT: 6500)
                display.apply(r: g.r, g: g.g, b: g.b)
                readoutItem.title = String(format: "тест: экран → %.0f K", k)
                return
            }
        }

        let reading = sensor?.read()

        guard isEnabled else {
            if display.isTinted { display.restore() }
            readoutItem.title = reading.map {
                String(format: "выкл · свет %.0f K · %.0f lx", $0.cct, $0.lux)
            } ?? "выкл"
            log("off  reading=\(reading.map { "\(Int($0.lux))lx \(Int($0.cct))K" } ?? "nil")")
            return
        }

        guard let rd = reading else {
            readoutItem.title = "⚠️ нет данных с датчика"
            log("on   reading=nil")
            return
        }

        model.update(lux: rd.lux, ambientCCT: rd.cct, dt: dt)
        let g = model.rgbGains()
        display.apply(r: g.r, g: g.g, b: g.b)
        readoutItem.title = String(format: "свет %.0f K → экран %.0f K · %.0f lx",
                                   rd.cct, model.displayCCT, rd.lux)

        if debug {
            let rb = display.readbackTopGains()
            log(String(format: "on   %4.0flx  ambient %5.0fK  ch=%@  ->  screen %5.0fK  gains r=%.3f g=%.3f b=%.3f  readback %@",
                       rd.lux, rd.cct,
                       rd.channels.map { String(Int($0)) }.joined(separator: "/"),
                       model.displayCCT, g.r, g.g, g.b,
                       rb.map { String(format: "r=%.3f g=%.3f b=%.3f", $0.r, $0.g, $0.b) } ?? "nil"))
        }
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

// MARK: - strength slider (custom menu view)

@MainActor
final class StrengthSliderView: NSView {
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "Сила: 100 %")
    var onChange: ((Int) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        label.font = .menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 25, width: 212, height: 16)
        slider.frame = NSRect(x: 14, y: 6, width: 212, height: 18)
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        addSubview(label)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { nil }

    func set(_ pct: Int) {
        slider.doubleValue = Double(pct)
        label.stringValue = "Сила: \(pct) %"
    }

    @objc private func changed() {
        let v = Int(slider.doubleValue.rounded())
        label.stringValue = "Сила: \(v) %"
        onChange?(v)
    }
}
