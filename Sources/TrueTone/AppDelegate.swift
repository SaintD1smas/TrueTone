import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)          // menu-bar only, no Dock icon
        // Create the status item only after the app is fully up — doing it earlier
        // (e.g. in a stored-property initializer before `run()`) means a
        // launchd-started accessory app never registers its menu-bar item.
        controller = MenuBarController()
    }

    /// Re-opening the app from Finder / Launchpad / Spotlight while it's already
    /// running: bring the menu-bar icon back and show the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.revealMenu()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
