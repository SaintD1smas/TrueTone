import Foundation
import CoreGraphics

/// Applies a white-point tint to the external display(s) by scaling their
/// per-channel gamma ramps *on top of* whatever ramp is currently loaded (the
/// monitor's ICC / ColorSync calibration), so a calibrated profile is preserved.
/// Reverts to the calibrated ramps on demand.
final class DisplayController {

    private struct Ramp { var r: [CGGammaValue]; var g: [CGGammaValue]; var b: [CGGammaValue] }
    private var base: [CGDirectDisplayID: Ramp] = [:]
    private var tinted = false

    init() {
        // A previous run may have died while tinted; start from the clean
        // calibrated state so the captured base ramps are correct.
        CGDisplayRestoreColorSyncSettings()
    }

    /// External (non-built-in) online displays — the Mi Monitor, in practice.
    private func externalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private func baseRamp(for id: CGDirectDisplayID) -> Ramp {
        if let cached = base[id] { return cached }
        let cap = CGDisplayGammaTableCapacity(id)
        var r = [CGGammaValue](repeating: 0, count: Int(cap))
        var g = [CGGammaValue](repeating: 0, count: Int(cap))
        var b = [CGGammaValue](repeating: 0, count: Int(cap))
        var got: UInt32 = 0
        CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &got)
        let n = Int(got)
        let ramp = n > 1
            ? Ramp(r: Array(r.prefix(n)), g: Array(g.prefix(n)), b: Array(b.prefix(n)))
            : identityRamp(256)
        base[id] = ramp
        return ramp
    }

    private func identityRamp(_ n: Int) -> Ramp {
        let v = (0..<n).map { CGGammaValue(Double($0) / Double(n - 1)) }
        return Ramp(r: v, g: v, b: v)
    }

    /// Push the given gains (each 0…1) to every external display. Idempotent —
    /// safe to call every tick, which also re-asserts the ramp after the OS
    /// resets it on wake / display reconfiguration.
    func apply(r rGain: Double, g gGain: Double, b bGain: Double) {
        for id in externalDisplays() {
            let base = baseRamp(for: id)
            let n = base.r.count
            var r = [CGGammaValue](repeating: 0, count: n)
            var g = [CGGammaValue](repeating: 0, count: n)
            var b = [CGGammaValue](repeating: 0, count: n)
            for i in 0..<n {
                r[i] = CGGammaValue(Double(base.r[i]) * rGain)
                g[i] = CGGammaValue(Double(base.g[i]) * gGain)
                b[i] = CGGammaValue(Double(base.b[i]) * bGain)
            }
            CGSetDisplayTransferByTable(id, UInt32(n), &r, &g, &b)
        }
        tinted = true
    }

    /// Restore the calibrated gamma for all displays.
    func restore() {
        guard tinted else { return }
        CGDisplayRestoreColorSyncSettings()
        base.removeAll()
        tinted = false
    }

    var isTinted: Bool { tinted }
}
