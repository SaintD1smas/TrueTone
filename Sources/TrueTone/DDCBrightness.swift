import Foundation
import CoreGraphics

/// Real backlight control for the external monitor over DDC/CI, via `m1ddc`.
///
/// A hand-rolled IOAVServiceWriteI2C path was tried first and this panel ignores
/// it (reads fine, writes silently dropped) — m1ddc's framing is the one it
/// accepts, so shell out rather than re-derive the quirk.
///
/// This monitor's MCU has been hung before by tight DDC loops, so: writes are
/// rate-limited and coalesced, and we never read except once at startup.
enum DDCBrightness {

    private static let minWriteInterval: TimeInterval = 0.5
    private static let queue = DispatchQueue(label: "truetone.ddc")

    nonisolated(unsafe) private static var lastWritten: Int?
    nonisolated(unsafe) private static var lastWriteAt: Date = .distantPast
    nonisolated(unsafe) private static var pending: Int?

    private static let binary: String? = {
        for p in ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    /// Index of the external monitor in `m1ddc display list` (the first named one).
    ///
    /// Resolved lazily and *not* latched on failure: the app autostarts at login
    /// and the Mi can take ~10 s to come up, so a one-shot `static let` here left
    /// brightness sync permanently dead after every reboot.
    nonisolated(unsafe) private static var cachedIndex: String?

    private static var displayIndex: String? {
        if let cachedIndex { return cachedIndex }
        guard displayReady else { return nil }      // don't probe with no panel attached
        for line in (run(["display", "list"]) ?? "").split(separator: "\n") {
            // "[1] Mi Monitor (UUID)"  — skip "(null)" entries
            guard let close = line.firstIndex(of: "]"), line.hasPrefix("[") else { continue }
            let idx = String(line[line.index(after: line.startIndex)..<close])
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.hasPrefix("(null)") { cachedIndex = idx; return idx }
        }
        return nil
    }

    /// Forget the resolved display (call when the display set changes).
    static func displaysChanged() {
        queue.async { cachedIndex = nil; lastWritten = nil; pending = nil }
    }

    static var isAvailable: Bool { binary != nil && displayIndex != nil }

    /// Only talk to the panel while it's actually online and awake. Writes across
    /// sleep/wake transitions are what has upset this monitor's MCU before.
    private static var displayReady: Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard let ext = ids.first(where: { CGDisplayIsBuiltin($0) == 0 }) else { return false }
        return CGDisplayIsActive(ext) != 0 && CGDisplayIsAsleep(ext) == 0
    }

    /// The same mutex ~/.monitor_ddc.zsh uses (`mkdir` on a directory is atomic).
    /// The wake-repair scripts take it before touching DDC precisely because
    /// concurrent access wedges this monitor's MCU — so we take it too, and just
    /// skip the write if they hold it. A write is ~85 ms, so we never block them
    /// for long; the next tick retries.
    private static let lockURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".monitor_hook.lock")
    private static let lockStaleAfter: TimeInterval = 25

    private static func withLock<T>(_ body: () -> T) -> T? {
        let fm = FileManager.default
        func grab() -> Bool {
            (try? fm.createDirectory(at: lockURL, withIntermediateDirectories: false)) != nil
        }
        if !grab() {
            // Same staleness rule as the shell helper, so a crashed script can't
            // lock us out forever.
            let age = (try? fm.attributesOfItem(atPath: lockURL.path)[.modificationDate] as? Date)
                .flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 0
            guard age > lockStaleAfter else { return nil }
            try? fm.removeItem(at: lockURL)
            guard grab() else { return nil }
        }
        defer { try? fm.removeItem(at: lockURL) }
        return body()
    }

    @discardableResult
    private static func run(_ args: [String]) -> String? {
        guard let binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read the panel's current luminance. Only safe to call when idle — reads
    /// right after a write come back as errors. Used once, at startup.
    static func read() -> Int? {
        guard displayReady, let idx = displayIndex else { return nil }
        guard let out = withLock({ run(["display", idx, "get", "luminance"]) }) ?? nil,
              let v = Int(out), (0...100).contains(v)
        else { return nil }
        return v
    }

    /// Set luminance (0…100). Coalesced and rate-limited; runs off the caller's
    /// thread. A no-op if the value hasn't changed.
    static func set(_ value: Int) {
        let v = min(max(value, 0), 100)
        queue.async {
            guard v != lastWritten else { return }
            let since = Date().timeIntervalSince(lastWriteAt)
            if since < minWriteInterval {
                // coalesce: remember the latest target, flush after the gap
                pending = v
                queue.asyncAfter(deadline: .now() + (minWriteInterval - since)) {
                    if let p = pending { pending = nil; write(p) }
                }
                return
            }
            write(v)
        }
    }

    private static func write(_ v: Int) {
        guard let idx = displayIndex, v != lastWritten, displayReady else { return }
        // If the wake-repair scripts hold the lock, skip — the next tick retries.
        guard withLock({ run(["display", idx, "set", "luminance", String(v)]) }) != nil else { return }
        lastWritten = v
        lastWriteAt = Date()
    }

    /// Synchronous write — for shutdown paths, where the async queue would never
    /// get to run before the process exits.
    static func setNow(_ value: Int) {
        let v = min(max(value, 0), 100)
        guard let idx = displayIndex else { return }
        _ = withLock { run(["display", idx, "set", "luminance", String(v)]) }
        lastWritten = v
        lastWriteAt = Date()
    }

}
