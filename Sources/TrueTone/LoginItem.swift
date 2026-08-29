import Foundation

/// "Start at login" = presence of the LaunchAgent plist. The menu toggle only
/// writes / removes the file; it never calls launchctl, so the running session
/// is never disturbed — the change takes effect at the next login.
/// `scripts/install.sh` is what actually loads it the first time.
enum LoginItem {
    static let label = "com.dmitriy.truetone"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// False when running unbundled (`swift run`) — the toggle is meaningless then.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) {
        guard isBundled else { return }
        if on {
            let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TrueTone").path
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>            <string>\(label)</string>
                <key>ProgramArguments</key> <array><string>\(bin)</string></array>
                <key>RunAtLoad</key>        <true/>
                <key>KeepAlive</key>        <dict><key>SuccessfulExit</key><false/></dict>
                <key>ProcessType</key>      <string>Interactive</string>
                <key>LimitLoadToSessionType</key> <string>Aqua</string>
                <key>StandardErrorPath</key> <string>/tmp/truetone.log</string>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
