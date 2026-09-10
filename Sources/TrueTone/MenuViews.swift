import AppKit

let kMenuWidth: CGFloat = 268
/// Native menu items indent their text past the checkmark column; custom views
/// have to match it by hand or they sit visibly further left.
let kMenuTextInset: CGFloat = 21

/// Round `raw` to the nearest `step`, then clamp. Integer division toward zero
/// used to turn −30 K with a 50 K step into 0 instead of −50.
func snapSteppedValue(_ raw: Double, step: Int, min: Int, max: Int) -> Int {
    let v: Int
    if step > 1 {
        v = Int((raw / Double(step)).rounded(.toNearestOrAwayFromZero)) * step
    } else {
        v = Int(raw.rounded())
    }
    return Swift.min(Swift.max(v, min), max)
}

/// Top of the menu: app name + an on/off switch.
@MainActor
final class HeaderView: NSView {
    private let title = NSTextField(labelWithString: "TrueTone")
    private let subtitle = NSTextField(labelWithString: "external display")
    private let toggle = NSSwitch()
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: 52))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: kMenuTextInset, y: 27, width: 150, height: 18)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: kMenuTextInset, y: 10, width: 170, height: 14)
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: kMenuWidth - kMenuTextInset - toggle.frame.width, y: 15)
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

    private let barRect = NSRect(x: kMenuTextInset, y: 34, width: kMenuWidth - 2 * kMenuTextInset, height: 8)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: 82))
        caption.font = .systemFont(ofSize: 12)
        caption.frame = NSRect(x: kMenuTextInset, y: 60, width: kMenuWidth - 2 * kMenuTextInset, height: 16)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: kMenuTextInset, y: 4, width: kMenuWidth - 2 * kMenuTextInset, height: 14)
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
    private let format: (Int) -> String
    var onChange: ((Int) -> Void)?
    /// Snap the value to this increment (the trim slider moves in 50 K steps).
    var step = 1

    /// `bipolar` marks the neutral point. Hiding the accent fill would be the
    /// nicer answer — on a centred control a bar growing from the left edge reads
    /// as a quantity — but `trackFillColor` paints a dark bar whatever colour it
    /// is given, so instead the midpoint is ticked and the half-filled track
    /// reads as "middle of the range".
    ///
    /// `ends` is a pair of captions anchored to the slider's left and right
    /// (Night Shift's "Less Warm" / "More Warm"). A single left-aligned hint
    /// sat off-centre under a 0-centred knob.
    init(title: String, min: Double, max: Double,
         ends: (String, String)? = nil,
         bipolar: Bool = false,
         format: @escaping (Int) -> String) {
        self.caption = NSTextField(labelWithString: title)
        self.slider = NSSlider(value: min, minValue: min, maxValue: max, target: nil, action: nil)
        self.format = format
        let h: CGFloat = ends == nil ? 50 : 66
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: h))

        let top = h - 20
        caption.font = .systemFont(ofSize: 12)
        caption.frame = NSRect(x: kMenuTextInset, y: top, width: 150, height: 16)
        value.font = .systemFont(ofSize: 12)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: kMenuWidth - kMenuTextInset - 96, y: top, width: 96, height: 16)
        slider.frame = NSRect(x: kMenuTextInset - 2, y: top - 26, width: kMenuWidth - 2 * kMenuTextInset + 4, height: 20)
        slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        if bipolar {
            slider.numberOfTickMarks = 3          // ends + the neutral midpoint
            slider.tickMarkPosition = .below
            slider.allowsTickMarkValuesOnly = false
        }
        slider.target = self
        slider.action = #selector(changed)
        addSubview(caption); addSubview(value); addSubview(slider)

        if let ends {
            let w: CGFloat = 90
            let y: CGFloat = 2
            let left = Self.endLabel(ends.0, alignment: .left)
            left.frame = NSRect(x: slider.frame.minX + 2, y: y, width: w, height: 13)
            let right = Self.endLabel(ends.1, alignment: .right)
            right.frame = NSRect(x: slider.frame.maxX - 2 - w, y: y, width: w, height: 13)
            addSubview(left); addSubview(right)
        }
    }
    required init?(coder: NSCoder) { nil }

    private static func endLabel(_ text: String, alignment: NSTextAlignment) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 10)
        t.textColor = .tertiaryLabelColor
        t.alignment = alignment
        return t
    }

    private func snapped(_ raw: Double) -> Int {
        snapSteppedValue(raw, step: step,
                         min: Int(slider.minValue.rounded()),
                         max: Int(slider.maxValue.rounded()))
    }

    func set(_ v: Int) {
        let s = snapped(Double(v))
        slider.doubleValue = Double(s)
        value.stringValue = format(s)
    }
    func setEnabled(_ on: Bool) {
        slider.isEnabled = on
        caption.textColor = on ? .labelColor : .tertiaryLabelColor
        value.textColor = on ? .secondaryLabelColor : .tertiaryLabelColor
    }
    @objc private func changed() {
        let v = snapped(slider.doubleValue)
        slider.doubleValue = Double(v)
        value.stringValue = format(v)
        onChange?(v)
    }
}
