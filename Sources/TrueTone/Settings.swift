import Foundation

/// Thin wrapper over UserDefaults. For a plain (unbundled) binary this persists
/// under the executable name in ~/Library/Preferences — fine for personal use.
struct Settings {
    private let d = UserDefaults.standard

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }   // on by default
        set { d.set(newValue, forKey: "enabled") }
    }

    /// 0…100
    var intensityPercent: Int {
        get { d.object(forKey: "intensityPercent") as? Int ?? 100 }
        set { d.set(newValue, forKey: "intensityPercent") }
    }

    /// Manual white-point bias in Kelvin, −1000…+1000 (negative = warmer).
    var trimK: Int {
        get { d.object(forKey: "trimK") as? Int ?? 0 }
        set { d.set(newValue, forKey: "trimK") }
    }

    /// Follow the MacBook's brightness (F1/F2) on the external monitor by
    /// scaling its gamma (the Mi ignores hardware brightness control).
    var syncBrightness: Bool {
        get { d.object(forKey: "syncBrightness") as? Bool ?? false }
        set { d.set(newValue, forKey: "syncBrightness") }
    }

    /// Brightness calibration anchors ("these two look the same"), persisted as
    /// four scalars; a negative builtin value means the anchor is unset.
    var brightnessMap: BrightnessMap {
        get {
            func pair(_ b: String, _ l: String) -> (Double?, Int?) {
                guard let v = d.object(forKey: b) as? Double, v >= 0 else { return (nil, nil) }
                return (v, d.integer(forKey: l))
            }
            let lo = pair("calLoBuiltin", "calLoLum")
            let hi = pair("calHiBuiltin", "calHiLum")
            return BrightnessMap(loBuiltin: lo.0, loLum: lo.1, hiBuiltin: hi.0, hiLum: hi.1)
        }
        set {
            d.set(newValue.loBuiltin ?? -1, forKey: "calLoBuiltin")
            d.set(newValue.loLum ?? 0, forKey: "calLoLum")
            d.set(newValue.hiBuiltin ?? -1, forKey: "calHiBuiltin")
            d.set(newValue.hiLum ?? 0, forKey: "calHiLum")
        }
    }

    /// Last known health, published so `truetone status` can report it — on this
    /// Mac the menu-bar icon is often hidden, so the terminal is the only surface
    /// left for "why isn't it doing anything".
    var healthNote: String {
        get { d.string(forKey: "healthNote") ?? "ok" }
        set { d.set(newValue, forKey: "healthNote") }
    }

    /// Manual Mi backlight level (0…100, DDC luminance), used when
    /// syncBrightness is off. Seeded from the panel's own level at first launch.
    var manualBrightnessPercent: Int {
        get { d.object(forKey: "manualBrightnessPercent") as? Int ?? 100 }
        set { d.set(newValue, forKey: "manualBrightnessPercent") }
    }

    /// Show the menu-bar item. When hidden, bring it back with the global
    /// hotkey (⌃⌥⌘T) or the `truetone show` command.
    var showInMenuBar: Bool {
        get { d.object(forKey: "showInMenuBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInMenuBar") }
    }
}
