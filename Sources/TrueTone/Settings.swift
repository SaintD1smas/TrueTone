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

    /// How dark the Mi is allowed to go, as a % of signal (floor of the sync).
    var brightnessFloorPercent: Int {
        get { d.object(forKey: "brightnessFloorPercent") as? Int ?? 30 }
        set { d.set(newValue, forKey: "brightnessFloorPercent") }
    }

    /// Manual Mi brightness (0…100), used when syncBrightness is off. 100 = the
    /// Mi's own hardware brightness, untouched.
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
