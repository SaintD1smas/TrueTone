import Foundation
import CoreGraphics

/// Applies a white-point tint to the external display(s) by scaling their
/// per-channel gamma transfer ramps. Reverts to the ColorSync-calibrated ramps
/// on demand.
final class DisplayController {

    private let rampSize = 256
    private var tinted = false

    /// External (non-built-in) online displays — the Mi Monitor, in practice.
    private func externalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Push the given gains (each 0…1) to every external display. Idempotent —
    /// safe to call every tick, which also re-asserts the ramp after the OS
    /// resets it on wake / display reconfiguration.
    func apply(r: Double, g: Double, b: Double) {
        let n = rampSize
        var red = [CGGammaValue](repeating: 0, count: n)
        var grn = [CGGammaValue](repeating: 0, count: n)
        var blu = [CGGammaValue](repeating: 0, count: n)
        for i in 0..<n {
            let v = Double(i) / Double(n - 1)        // identity ramp
            red[i] = CGGammaValue(v * r)
            grn[i] = CGGammaValue(v * g)
            blu[i] = CGGammaValue(v * b)
        }
        for id in externalDisplays() {
            CGSetDisplayTransferByTable(id, UInt32(n), &red, &grn, &blu)
        }
        tinted = true
    }

    /// Restore the calibrated gamma for all displays.
    func restore() {
        guard tinted else { return }
        CGDisplayRestoreColorSyncSettings()
        tinted = false
    }

    var isTinted: Bool { tinted }

    /// Top (white) entry of the first external display's current gamma ramp —
    /// i.e. the per-channel gain actually in effect. For verification / logging.
    func readbackTopGains() -> (r: Double, g: Double, b: Double)? {
        guard let id = externalDisplays().first else { return nil }
        let cap = CGDisplayGammaTableCapacity(id)
        var r = [CGGammaValue](repeating: 0, count: Int(cap))
        var g = [CGGammaValue](repeating: 0, count: Int(cap))
        var b = [CGGammaValue](repeating: 0, count: Int(cap))
        var got: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &got) == .success, got > 0 else { return nil }
        let i = Int(got) - 1
        return (Double(r[i]), Double(g[i]), Double(b[i]))
    }
}
