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

    /// Show a Dock icon (activation policy .regular) in addition to the menu bar.
    var showInDock: Bool {
        get { d.object(forKey: "showInDock") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInDock") }
    }

    /// Show the menu-bar item. The controller guarantees at least one of
    /// showInDock / showInMenuBar is always on, so you can't lock yourself out.
    var showInMenuBar: Bool {
        get { d.object(forKey: "showInMenuBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInMenuBar") }
    }
}
