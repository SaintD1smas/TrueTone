import AppKit

// Menu-bar-only app (no Dock icon, no window). Top-level code runs on the main
// thread; hop onto the main actor explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    _ = delegate
}
