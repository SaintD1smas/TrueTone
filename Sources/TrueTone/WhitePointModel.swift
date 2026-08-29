import Foundation

/// Turns an ambient reading into per-channel RGB gains for the display, the way
/// True Tone does: a *partial* shift of the display white point from its native
/// D65 toward the colour of the room, stronger in bright light, gentle and
/// time-smoothed so the screen never visibly jumps.
struct WhitePointModel {

    // Tunables. Defaults chosen so 100 % "Сила" is a clearly visible True-Tone-ish
    // shift that the menu slider dials *down* from; tune the rest by eye.
    var nativeCCT: Double = 6500          // display native white (D65)
    var maxAdapt: Double = 0.85          // never adapt more than this fraction of the way
    var intensity: Double = 1.0          // 0…1 from the menu slider
    var baseFrac: Double = 0.22          // adaptation even in a dim room
    var floorCCT: Double = 3900          // clamp target — never go orange
    var ceilCCT: Double = 7000
    var luxLow: Double = 8                // below this: only baseFrac
    var luxHigh: Double = 300             // at/above this: full lux term
    var tau: Double = 6.0                 // smoothing time constant, seconds
    var deadbandMired: Double = 1.5       // ignore sub-threshold wobble

    /// Smoothed state, in mired (10^6 / Kelvin). nil until first update.
    private(set) var currentMired: Double?

    /// The CCT the screen is currently being driven to (for the readout).
    var displayCCT: Double { currentMired.map { 1_000_000 / $0 } ?? nativeCCT }

    // MARK: update

    /// Advance the model by `dt` seconds toward the target implied by the reading.
    mutating func update(lux: Double, ambientCCT: Double, dt: Double) {
        let target = targetMired(lux: lux, ambientCCT: ambientCCT)
        guard let cur = currentMired else { currentMired = target; return }

        if abs(target - cur) < deadbandMired { return }
        let alpha = 1 - exp(-dt / max(tau, 0.1))
        currentMired = cur + alpha * (target - cur)
    }

    /// Jump straight to native (used when the feature is switched off).
    mutating func resetToNative() { currentMired = 1_000_000 / nativeCCT }

    /// Per-channel gains (each ≤ 1.0) to apply on top of an identity gamma ramp.
    func rgbGains() -> (r: Double, g: Double, b: Double) {
        Self.gains(fromCCT: displayCCT, nativeCCT: nativeCCT)
    }

    // MARK: adaptation curve

    private func targetMired(lux: Double, ambientCCT: Double) -> Double {
        let ambient = min(max(ambientCCT, 3500), 10_000)
        let luxT = smoothstep(lux, luxLow, luxHigh)
        let frac = min(max(intensity, 0), 1) * (baseFrac + (1 - baseFrac) * luxT) * maxAdapt

        let mNative = 1_000_000 / nativeCCT
        let mAmbient = 1_000_000 / ambient
        var m = mNative + frac * (mAmbient - mNative)

        // clamp in Kelvin, back to mired
        let k = min(max(1_000_000 / m, floorCCT), ceilCCT)
        m = 1_000_000 / k
        return m
    }

    private func smoothstep(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: colour math  (CCT → xy → linear sRGB → normalised gains)

    static func gains(fromCCT cct: Double, nativeCCT: Double) -> (r: Double, g: Double, b: Double) {
        let want = linearSRGBWhite(cct: cct)
        let have = linearSRGBWhite(cct: nativeCCT)
        // ratio that maps the native white onto the wanted white
        var r = want.0 / have.0
        var g = want.1 / have.1
        var b = want.2 / have.2
        let m = max(r, max(g, b))
        r /= m; g /= m; b /= m
        return (clamp01(r), clamp01(g), clamp01(b))
    }

    /// Linear-sRGB (D65 primaries) coordinates of a black-body white at `cct`, Y = 1.
    private static func linearSRGBWhite(cct: Double) -> (Double, Double, Double) {
        let (x, y) = chromaticity(cct: cct)
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        // XYZ (D65) → linear sRGB
        let r =  3.2406 * X - 1.5372 * Y - 0.4986 * Z
        let g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
        let b =  0.0557 * X - 0.2040 * Y + 1.0570 * Z
        return (max(r, 0), max(g, 0), max(b, 0))
    }

    /// Kim et al. CCT → CIE 1931 xy (valid ~1667–25000 K).
    private static func chromaticity(cct: Double) -> (Double, Double) {
        let T = min(max(cct, 1667), 25_000)
        let t = 1000.0 / T, t2 = t * t, t3 = t2 * t
        let x: Double
        if T <= 4000 {
            x = -0.2661239 * t3 - 0.2343589 * t2 + 0.8776956 * t + 0.179910
        } else {
            x = -3.0258469 * t3 + 2.1070379 * t2 + 0.2226347 * t + 0.240390
        }
        let x2 = x * x, x3 = x2 * x
        let y: Double
        if T <= 2222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if T <= 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y =  3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
