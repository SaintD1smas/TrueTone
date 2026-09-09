import Foundation

/// Maps the MacBook's brightness onto the Mi's backlight.
///
/// A straight 1:1 (built-in 63 % → luminance 63) matches the numbers but not the
/// eye: the panels differ in peak brightness, and macOS's slider is perceptual
/// while DDC luminance is a raw backlight scale. So the mapping is defined by up
/// to two calibration anchors the user records by eye — two points give both the
/// offset (things line up) and the slope (the useful range), which is why there
/// are no separate min/max knobs.
struct BrightnessMap: Equatable {
    /// MacBook brightness 0…1 ↔ Mi luminance 0…100, at the dim and bright ends.
    var loBuiltin: Double?
    var loLum: Int?
    var hiBuiltin: Double?
    var hiLum: Int?

    static let hardMin = 5
    static let hardMax = 100
    /// Anchors closer together than this can't define a trustworthy slope.
    static let minSpread = 0.15

    var isCalibrated: Bool { anchors.count > 0 }

    private var anchors: [(b: Double, lum: Int)] {
        var out: [(Double, Int)] = []
        if let b = loBuiltin, let l = loLum { out.append((b, l)) }
        if let b = hiBuiltin, let l = hiLum { out.append((b, l)) }
        return out.sorted { $0.0 < $1.0 }
    }

    func luminance(forBuiltin builtin: Double) -> Int {
        let x = min(max(builtin, 0), 1)
        let a = anchors
        let raw: Double

        if a.count == 2, a[1].b - a[0].b >= Self.minSpread {
            // Two usable points: a line through both, extrapolated past the ends.
            let t = (x - a[0].b) / (a[1].b - a[0].b)
            raw = Double(a[0].lum) + t * Double(a[1].lum - a[0].lum)
        } else if let only = a.first {
            // One point: keep the default 1:1 slope, slide it through the anchor.
            raw = Double(only.lum) + (x - only.b) * 100
        } else {
            raw = x * 100
        }
        return Int(min(max(raw.rounded(), Double(Self.hardMin)), Double(Self.hardMax)))
    }

    /// Remember "these two look the same". Keeps the two most widely separated
    /// anchors, so re-recording near an existing one refines it instead of
    /// collapsing the calibration onto a single brightness.
    mutating func record(builtin: Double, luminance: Int) {
        var pts = anchors.filter { abs($0.b - builtin) > Self.minSpread / 2 }
        pts.append((builtin, luminance))
        pts.sort { $0.b < $1.b }
        if pts.count > 2 { pts = [pts.first!, pts.last!] }

        loBuiltin = pts.first?.b;  loLum = pts.first?.lum
        if pts.count > 1 {
            hiBuiltin = pts.last?.b; hiLum = pts.last?.lum
        } else {
            hiBuiltin = nil; hiLum = nil
        }
    }

    mutating func reset() {
        loBuiltin = nil; loLum = nil; hiBuiltin = nil; hiLum = nil
    }

    /// Short description for the menu.
    var summary: String {
        let a = anchors
        switch a.count {
        case 0: return "без калибровки"
        case 1: return String(format: "1 точка: %.0f %% → %d", a[0].b * 100, a[0].lum)
        default: return String(format: "%.0f %% → %d  ·  %.0f %% → %d",
                               a[0].b * 100, a[0].lum, a[1].b * 100, a[1].lum)
        }
    }
}
