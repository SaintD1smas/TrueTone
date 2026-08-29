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

    /// Show the menu-bar item. When hidden, bring it back with the global
    /// hotkey (⌃⌥⌘T) or the `truetone show` command.
    var showInMenuBar: Bool {
        get { d.object(forKey: "showInMenuBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInMenuBar") }
    }
}
