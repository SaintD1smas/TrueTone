import AppKit

// Menu-bar-only app (no Dock icon, no window).
// Top-level code runs on the main thread; hop onto the main actor explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController()
    _ = controller
    app.run()
}
