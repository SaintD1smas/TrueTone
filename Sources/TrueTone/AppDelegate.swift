import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Settings().showInDock ? .regular : .accessory)
        // Create the status item only after the app is fully up — doing it earlier
        // (e.g. in a stored-property initializer before `run()`) means a
        // launchd-started accessory app never registers its menu-bar item.
        controller = MenuBarController()
    }

    /// Right-click on the Dock icon — a compact control menu (handy when Sequoia
    /// is hiding the menu-bar item).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        controller?.makeDockMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
