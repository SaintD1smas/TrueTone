import AppKit

private let kMenuWidth: CGFloat = 264

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
        subtitle.frame = NSRect(x: 16, y: 10, width: 150, height: 14)
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: kMenuWidth - 16 - toggle.frame.width, y: 15)
        addSubview(title); addSubview(subtitle); addSubview(toggle)
    }
    required init?(coder: NSCoder) { nil }

    func set(on: Bool) { toggle.state = on ? .on : .off }
    @objc private func changed() { onToggle?(toggle.state == .on) }
}

/// Live status: a swatch of the current screen tint + "свет … → экран … · … lx".
@MainActor
final class ReadoutView: NSView {
    private let swatch = NSView()
    private let line1 = NSTextField(labelWithString: "")
    private let line2 = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: 44))
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.backgroundColor = NSColor.white.cgColor
        swatch.frame = NSRect(x: 16, y: 15, width: 14, height: 14)
        line1.font = .systemFont(ofSize: 12)
        line1.frame = NSRect(x: 40, y: 22, width: kMenuWidth - 56, height: 16)
        line2.font = .systemFont(ofSize: 11)
        line2.textColor = .secondaryLabelColor
        line2.frame = NSRect(x: 40, y: 6, width: kMenuWidth - 56, height: 14)
        addSubview(swatch); addSubview(line1); addSubview(line2)
    }
    required init?(coder: NSCoder) { nil }

    func update(ambientK: Double, screenK: Double, lux: Double, tint: NSColor) {
        line1.stringValue = String(format: "свет %.0f K   →   экран %.0f K", ambientK, screenK)
        line2.stringValue = String(format: "%.0f lx", lux)
        swatch.layer?.backgroundColor = tint.cgColor
    }
    func message(_ s: String, tint: NSColor = .white) {
        line1.stringValue = s
        line2.stringValue = ""
        swatch.layer?.backgroundColor = tint.cgColor
    }
}

/// "Сила" — the adaptation-strength slider.
@MainActor
final class StrengthView: NSView {
    private let caption = NSTextField(labelWithString: "Сила")
    private let value = NSTextField(labelWithString: "100 %")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    var onChange: ((Int) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: kMenuWidth, height: 52))
        caption.font = .systemFont(ofSize: 12)
        caption.frame = NSRect(x: 16, y: 30, width: 120, height: 16)
        value.font = .systemFont(ofSize: 12)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: kMenuWidth - 16 - 64, y: 30, width: 64, height: 16)
        slider.frame = NSRect(x: 14, y: 6, width: kMenuWidth - 28, height: 20)
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(caption); addSubview(value); addSubview(slider)
    }
    required init?(coder: NSCoder) { nil }

    func set(_ pct: Int) {
        slider.doubleValue = Double(pct)
        value.stringValue = "\(pct) %"
    }
    @objc private func changed() {
        let v = Int(slider.doubleValue.rounded())
        value.stringValue = "\(v) %"
        onChange?(v)
    }
}
