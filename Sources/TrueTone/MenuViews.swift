import AppKit

let kMenuWidth: CGFloat = 268

/// Top of the menu: app name + an on/off switch.
@MainActor
final class HeaderView: NSView {
    private let title = NSTextField(labelWithString: "TrueTone")
    private let subtitle = NSTextField(labelWithString: "внешний монитор")
    private let toggle = NSSwitch()
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: 52))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 16, y: 27, width: 150, height: 18)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 16, y: 10, width: 170, height: 14)
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: kMenuWidth - 16 - toggle.frame.width, y: 15)
        addSubview(title); addSubview(subtitle); addSubview(toggle)
    }
    required init?(coder: NSCoder) { nil }

    func set(on: Bool) { toggle.state = on ? .on : .off }
    func set(subtitle text: String) { subtitle.stringValue = text }
    @objc private func changed() { onToggle?(toggle.state == .on) }
}

/// Warm↔cool scale showing where the room light is and where we've put the
/// screen. Replaces a swatch that was invisible whenever the tint was subtle.
@MainActor
final class ScaleView: NSView {
    private let caption = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var ambient: Double?
    private var screen: Double?

    private let barRect = NSRect(x: 16, y: 34, width: kMenuWidth - 32, height: 8)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: 82))
        caption.font = .systemFont(ofSize: 12)
        caption.frame = NSRect(x: 16, y: 60, width: kMenuWidth - 32, height: 16)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 16, y: 4, width: kMenuWidth - 32, height: 14)
        addSubview(caption); addSubview(detail)
    }
    required init?(coder: NSCoder) { nil }

    func update(ambientK: Double?, screenK: Double?, detail text: String, caption capt: String) {
        ambient = ambientK
        screen = screenK
        caption.stringValue = capt
        detail.stringValue = text
        needsDisplay = true
    }

    /// Position along the bar, laid out in mired so the spacing matches how the
    /// eye reads colour temperature (warm on the left).
    private func x(for cct: Double) -> CGFloat {
        let lo = 1_000_000.0 / 9000, hi = 1_000_000.0 / 2700    // mired bounds
        let m = min(max(1_000_000.0 / cct, lo), hi)
        let t = (hi - m) / (hi - lo)
        return barRect.minX + barRect.width * CGFloat(t)
    }

    override func draw(_ dirtyRect: NSRect) {
        let warm = NSColor(srgbRed: 1.00, green: 0.70, blue: 0.42, alpha: 1)
        let mid  = NSColor(srgbRed: 1.00, green: 0.98, blue: 0.95, alpha: 1)
        let cool = NSColor(srgbRed: 0.76, green: 0.85, blue: 1.00, alpha: 1)
        let path = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)
        NSGradient(colors: [warm, mid, cool],
                   atLocations: [0, 0.62, 1],
                   colorSpace: .sRGB)?.draw(in: path, angle: 0)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // room light: a small notch under the bar
        if let a = ambient {
            let cx = x(for: a)
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: cx, y: barRect.minY - 1))
            tri.line(to: NSPoint(x: cx - 4, y: barRect.minY - 7))
            tri.line(to: NSPoint(x: cx + 4, y: barRect.minY - 7))
            tri.close()
            NSColor.secondaryLabelColor.setFill()
            tri.fill()
        }
        // screen: a solid pill sitting on the bar
        if let s = screen {
            let cx = x(for: s)
            let knob = NSRect(x: cx - 3, y: barRect.minY - 3, width: 6, height: barRect.height + 6)
            let p = NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3)
            NSColor.labelColor.setFill()
            p.fill()
            NSColor.windowBackgroundColor.setStroke()
            p.lineWidth = 1.5
            p.stroke()
        }
    }
}

/// One labelled slider row. The three controls used to be three near-identical
/// classes; this is the single component they collapsed into.
@MainActor
final class SliderRow: NSView {
    private let caption: NSTextField
    private let value = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let hint: NSTextField?
    private let format: (Int) -> String
    var onChange: ((Int) -> Void)?
    /// Snap the value to this increment (the trim slider moves in 50 K steps).
    var step = 1

    init(title: String, min: Double, max: Double, hint: String? = nil,
         format: @escaping (Int) -> String) {
        self.caption = NSTextField(labelWithString: title)
        self.slider = NSSlider(value: min, minValue: min, maxValue: max, target: nil, action: nil)
        self.hint = hint.map { NSTextField(labelWithString: $0) }
        self.format = format
        let h: CGFloat = hint == nil ? 50 : 62
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: h))

        let top = h - 20
        caption.font = .systemFont(ofSize: 12)
        caption.frame = NSRect(x: 16, y: top, width: 150, height: 16)
        value.font = .systemFont(ofSize: 12)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: kMenuWidth - 16 - 96, y: top, width: 96, height: 16)
        slider.frame = NSRect(x: 14, y: top - 26, width: kMenuWidth - 28, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(caption); addSubview(value); addSubview(slider)

        if let hintLabel = self.hint {
            hintLabel.font = .systemFont(ofSize: 10)
            hintLabel.textColor = .tertiaryLabelColor
            hintLabel.frame = NSRect(x: 16, y: 2, width: kMenuWidth - 32, height: 13)
            addSubview(hintLabel)
        }
    }
    required init?(coder: NSCoder) { nil }

    func set(_ v: Int) {
        slider.doubleValue = Double(v)
        value.stringValue = format(v)
    }
    func setEnabled(_ on: Bool) {
        slider.isEnabled = on
        caption.textColor = on ? .labelColor : .tertiaryLabelColor
    }
    @objc private func changed() {
        var v = Int(slider.doubleValue.rounded())
        if step > 1 { v = (v / step) * step }
        value.stringValue = format(v)
        onChange?(v)
    }
}
