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

    /// Spacing between backlight writes. Kept short enough that holding the
    /// brightness keys doesn't visibly lag, but this is writes only — never a
    /// set+get loop, which is what wedged this monitor's MCU before.
    private static let minWriteInterval: TimeInterval = 0.2
    private static let queue = DispatchQueue(label: "truetone.ddc")

    nonisolated(unsafe) private static var lastWritten: Int?
    nonisolated(unsafe) private static var lastWriteAt: Date = .distantPast
    nonisolated(unsafe) private static var pending: Int?
    /// Consecutive failed writes, used to back off. A panel that refuses DDC used
    /// to cost one m1ddc process per tick of the 0.12 s brightness timer.
    nonisolated(unsafe) private static var failures = 0

    /// Spacing before the next write attempt: the normal floor while the panel is
    /// answering, seconds once it isn't.
    private static var writeInterval: TimeInterval {
        failures == 0 ? minWriteInterval : min(Double(failures), 5)
    }

    private static let binary: String? = {
        for p in ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    /// Arguments that pick the panel on m1ddc's command line.
    ///
    /// Preferably `["display", "<n>"]` from `display list`, but m1ddc 1.2.0
    /// segfaults on *any* `display` argument — `display list` included — as soon
    /// as a virtual screen is attached, and an iPad over Sidecar is enough. So
    /// the index is a preference, not a requirement: with one external monitor
    /// m1ddc's bare form addresses it correctly, and that form keeps working.
    ///
    /// Resolved lazily and *not* latched on failure: the app autostarts at login
    /// and the Mi can take ~10 s to come up, so a one-shot `static let` here left
    /// brightness sync permanently dead after every reboot.
    nonisolated(unsafe) private static var cachedSelector: [String]?

    /// Set once the panel has actually answered something. Lets the menu tell
    /// "m1ddc isn't installed" from "the monitor isn't talking" — one misleading
    /// message used to cover both.
    nonisolated(unsafe) private static var answered = false

    private static var selector: [String]? {
        if let cachedSelector { return cachedSelector }
        guard displayReady else { return nil }      // don't probe with no panel attached
        // Same lock as every other DDC call — `display list` talks to the MCU too.
        let s = (withLock({ listIndex() }) ?? nil).map { ["display", $0] } ?? []
        cachedSelector = s
        return s
    }

    /// The monitor's index in `m1ddc display list`, or nil when m1ddc can't list.
    private static func listIndex() -> String? {
        guard let out = run(["display", "list"]) else { return nil }
        for line in out.split(separator: "\n") {
            // "[1] Mi Monitor (UUID)"  — skip "(null)" entries
            guard let close = line.firstIndex(of: "]"), line.hasPrefix("[") else { continue }
            let idx = String(line[line.index(after: line.startIndex)..<close])
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.hasPrefix("(null)") { return idx }
        }
        return nil
    }

    /// Forget the resolved display (call when the display set changes).
    static func displaysChanged() {
        queue.async { cachedSelector = nil; answered = false; failures = 0
            lastWritten = nil; pending = nil }
    }

    /// Cheap and non-blocking — safe to call from the main thread every tick.
    /// It reports what we already know; probing happens on `queue` via prepare().
    static var isAvailable: Bool { binary != nil && answered }

    /// Whether m1ddc is on disk at all — distinct from the panel answering.
    static var isInstalled: Bool { binary != nil }

    /// Resolve how to address the display, off the main thread. Safe to call
    /// repeatedly. The check belongs on `queue`: done on the caller's thread it
    /// raced `displaysChanged()`, saw a not-yet-cleared value and never re-probed.
    static func prepare() {
        guard binary != nil else { return }
        queue.async { _ = selector }
    }

    /// Read the panel's current luminance off the main thread.
    static func readAsync(_ completion: @escaping (Int?) -> Void) {
        queue.async {
            let v = read()
            DispatchQueue.main.async { completion(v) }
        }
    }

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

    /// Run m1ddc with a hard timeout. `~/.monitor_ddc.zsh` wraps every DDC call
    /// the same way because a wedged MCU makes m1ddc never return — without this,
    /// readDataToEndOfFile() blocks forever and takes the caller with it.
    @discardableResult
    private static func run(_ args: [String], timeout: TimeInterval = 3) -> String? {
        guard let binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let done = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global(qos: .utility).async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 0.5)
            return nil
        }
        p.waitUntilExit()
        // A crash or a refusal prints nothing, and treating that as an empty
        // success let `write` record values the panel never received.
        guard p.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read the panel's current luminance. Only safe to call when idle — reads
    /// right after a write come back as errors. Used once, at startup.
    static func read() -> Int? {
        guard displayReady, let sel = selector else { return nil }
        guard let out = withLock({ run(sel + ["get", "luminance"]) }) ?? nil,
              let v = Int(out), (0...100).contains(v)
        else { return nil }
        answered = true
        return v
    }

    /// Set luminance (0…100). Coalesced and rate-limited; runs off the caller's
    /// thread. A no-op if the value hasn't changed.
    static func set(_ value: Int) {
        let v = min(max(value, 0), 100)
        queue.async {
            guard v != lastWritten else { return }
            let since = Date().timeIntervalSince(lastWriteAt)
            let gap = writeInterval
            if since < gap {
                // coalesce: remember the latest target, flush after the gap
                pending = v
                queue.asyncAfter(deadline: .now() + (gap - since)) {
                    if let p = pending { pending = nil; write(p) }
                }
                return
            }
            write(v)
        }
    }

    private static func write(_ v: Int) {
        guard let sel = selector, v != lastWritten, displayReady else { return }
        // Stamp the attempt, not the success. Keyed off success, a failing write
        // left this at `.distantPast`, so the rate limit never engaged and the
        // brightness timer spawned an m1ddc every 0.12 s against a dead panel.
        lastWriteAt = Date()
        // If the wake-repair scripts hold the lock, skip — the next tick retries.
        guard (withLock({ run(sel + ["set", "luminance", String(v)]) }) ?? nil) != nil else {
            failures += 1
            return
        }
        failures = 0
        answered = true
        lastWritten = v
    }

}
