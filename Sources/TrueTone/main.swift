import AppKit

// Menu-bar-only app (no Dock icon, no window). Top-level code runs on the main
// thread; hop onto the main actor explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Single instance: launching a second copy (double-click in Finder /
    // Launchpad / Spotlight) just tells the running one to reveal its menu.
    let bundleID = Bundle.main.bundleIdentifier ?? "com.dmitriy.truetone"
    let others = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.dmitriy.truetone.reveal"), object: nil, userInfo: nil,
            deliverImmediately: true)
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    _ = delegate
}
