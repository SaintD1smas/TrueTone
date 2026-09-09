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
    private static let displayIndex: String? = {
        guard let out = run(["display", "list"]) else { return nil }
        for line in out.split(separator: "\n") {
            // "[1] Mi Monitor (UUID)"  — skip "(null)" entries
            guard let close = line.firstIndex(of: "]"), line.hasPrefix("[") else { continue }
            let idx = String(line[line.index(after: line.startIndex)..<close])
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.hasPrefix("(null)") { return idx }
        }
        return nil
    }()

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
        guard displayReady, let idx = displayIndex,
              let out = run(["display", idx, "get", "luminance"]),
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
        _ = run(["display", idx, "set", "luminance", String(v)])
        lastWritten = v
        lastWriteAt = Date()
    }

    /// Synchronous write — for shutdown paths, where the async queue would never
    /// get to run before the process exits.
    static func setNow(_ value: Int) {
        let v = min(max(value, 0), 100)
        guard let idx = displayIndex else { return }
        _ = run(["display", idx, "set", "luminance", String(v)])
        lastWritten = v
        lastWriteAt = Date()
    }

    /// Forget our cached state (so the next set() definitely writes).
    static func forget() { queue.async { lastWritten = nil; pending = nil } }
}
