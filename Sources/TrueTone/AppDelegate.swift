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

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
