import Testing
@testable import TrueTone

/// The colour path has shipped wrong twice, both times silently — the curve was
/// ~3× too aggressive, and gains were computed with an sRGB matrix on a
/// wide-gamut panel. Neither crashed or logged; both were only caught by
/// measuring by hand. These pin the invariants so the next one shows up here.

private func ~= (a: Double, b: Double) -> Bool { abs(a - b) < 0.002 }

// MARK: - PanelProfile

@Test func sRGBMatrixMapsItsOwnWhiteToEqualChannels() {
    // D65, the sRGB white point, must come out as neutral (1,1,1).
    let (x, y) = (0.3127, 0.3290)
    let xyz = [x / y, 1.0, (1 - x - y) / y]
    let m = PanelProfile.sRGB.xyzToRGB
    let rgb = (0..<3).map { i in (0..<3).map { j in m[i][j] * xyz[j] }.reduce(0, +) }
    #expect(rgb[0] ~= 1.0)
    #expect(rgb[1] ~= 1.0)
    #expect(rgb[2] ~= 1.0)
}

@Test func matrixBuiltFromSRGBPrimariesMatchesTheHardcodedOne() {
    let built = PanelProfile(rx: 0.640, ry: 0.330, gx: 0.300, gy: 0.600,
                             bx: 0.150, by: 0.060, wx: 0.3127, wy: 0.3290)
    let profile = try! #require(built)
    for r in 0..<3 {
        for c in 0..<3 {
            #expect(abs(profile.xyzToRGB[r][c] - PanelProfile.sRGB.xyzToRGB[r][c]) < 0.01)
        }
    }
}

@Test func miPrimariesGiveADSixtyFiveWhitePoint() {
    // Values read from the Mi's EDID. Its white really is D65 — it was the
    // primaries that differed from sRGB, not the white point.
    let mi = try! #require(PanelProfile(rx: 0.6729, ry: 0.3223, gx: 0.2568, gy: 0.6748,
                                        bx: 0.1484, by: 0.0537, wx: 0.3125, wy: 0.3291))
    #expect(abs(mi.nativeCCT - 6515) < 40)
}

@Test func degeneratePrimariesAreRejected() {
    #expect(PanelProfile(rx: 0.64, ry: 0, gx: 0.3, gy: 0.6,
                         bx: 0.15, by: 0.06, wx: 0.3127, wy: 0.329) == nil)
}

// MARK: - gains

@Test func targetEqualToNativeIsNeutral() {
    let g = WhitePointModel.gains(fromCCT: 6504, nativeCCT: 6504, panel: .sRGB)
    #expect(g.r ~= 1.0)
    #expect(g.g ~= 1.0)
    #expect(g.b ~= 1.0)
}

@Test func warmerTargetPullsBlueDownMost() {
    let g = WhitePointModel.gains(fromCCT: 5000, nativeCCT: 6504, panel: .sRGB)
    #expect(g.r ~= 1.0)          // red is the untouched channel when warming
    #expect(g.b < g.g)
    #expect(g.g < 1.0)
}

@Test func warmerTargetsAreMonotonic() {
    let a = WhitePointModel.gains(fromCCT: 6000, nativeCCT: 6504, panel: .sRGB)
    let b = WhitePointModel.gains(fromCCT: 5000, nativeCCT: 6504, panel: .sRGB)
    let c = WhitePointModel.gains(fromCCT: 4500, nativeCCT: 6504, panel: .sRGB)
    #expect(b.b < a.b)
    #expect(c.b < b.b)
}

@Test func coolerTargetPullsRedDown() {
    let g = WhitePointModel.gains(fromCCT: 8000, nativeCCT: 6504, panel: .sRGB)
    #expect(g.b ~= 1.0)
    #expect(g.r < 1.0)
}

/// The regression that shipped: computing gains with the sRGB matrix on the
/// wide-gamut Mi cut green and blue harder than the target actually needs.
@Test func wideGamutPanelNeedsLessCutThanSRGBMath() {
    let mi = try! #require(PanelProfile(rx: 0.6729, ry: 0.3223, gx: 0.2568, gy: 0.6748,
                                        bx: 0.1484, by: 0.0537, wx: 0.3125, wy: 0.3291))
    for target in [6000.0, 5500.0, 5000.0, 4500.0] {
        let wrong = WhitePointModel.gains(fromCCT: target, nativeCCT: 6504, panel: .sRGB)
        let right = WhitePointModel.gains(fromCCT: target, nativeCCT: mi.nativeCCT, panel: mi)
        #expect(right.b > wrong.b, "at \(target) K the panel matrix must cut less blue")
        #expect(right.g > wrong.g, "at \(target) K the panel matrix must cut less green")
    }
}

// MARK: - adaptation curve

/// Settle the model on a reading (the first update snaps, later ones ease).
private func settled(lux: Double, cct: Double,
                     _ configure: (inout WhitePointModel) -> Void = { _ in }) -> WhitePointModel {
    var m = WhitePointModel()
    configure(&m)
    m.update(lux: lux, ambientCCT: cct, dt: 60)
    return m
}

@Test func darkRoomSitsAtNativeWhite() {
    // Below a few lux the sensor's CCT is garbage (it reads a few hundred K).
    let m = settled(lux: 1, cct: 200)
    #expect(m.displayCCT ~= m.nativeCCT)
}

@Test func implausiblyWarmReadingIsIgnored() {
    let m = settled(lux: 300, cct: 900)
    #expect(m.displayCCT ~= m.nativeCCT)
}

@Test func warmRoomWarmsTheScreenButOnlyPartway() {
    let m = settled(lux: 300, cct: 4200)
    #expect(m.displayCCT < m.nativeCCT)        // warmer than native
    #expect(m.displayCCT > 4200)               // but nowhere near all the way
    #expect(m.displayCCT > 5500)               // Apple-gentle, not orange
}

@Test func zeroIntensityDisablesAdaptation() {
    let m = settled(lux: 300, cct: 3000) { $0.intensity = 0 }
    #expect(m.displayCCT ~= m.nativeCCT)
}

@Test func targetNeverGoesBelowTheFloor() {
    let m = settled(lux: 5000, cct: 2000) { $0.intensity = 1 }
    #expect(m.displayCCT >= m.floorCCT - 1)
}

@Test func brighterLightAdaptsMoreThanDimLight() {
    let dim = settled(lux: 30, cct: 4000)
    let bright = settled(lux: 900, cct: 4000)
    #expect(bright.displayCCT < dim.displayCCT)
}

@Test func trimShiftsTheTargetAndIsClamped() {
    let neutral = settled(lux: 300, cct: 4200)
    let warmer = settled(lux: 300, cct: 4200) { $0.trimK = -600 }
    let cooler = settled(lux: 300, cct: 4200) { $0.trimK = 600 }
    #expect(warmer.displayCCT < neutral.displayCCT)
    #expect(cooler.displayCCT > neutral.displayCCT)

    let extreme = settled(lux: 300, cct: 4200) { $0.trimK = -100_000 }
    #expect(extreme.displayCCT >= 3500 - 1)
}

@Test func smoothingEasesInsteadOfJumping() {
    var m = WhitePointModel()
    m.update(lux: 300, ambientCCT: 6500, dt: 60)      // first reading snaps
    let start = m.displayCCT
    m.update(lux: 300, ambientCCT: 3200, dt: 0.5)     // sudden warm light
    let after = m.displayCCT
    let target = settled(lux: 300, cct: 3200).displayCCT
    #expect(after < start)                             // moved toward it
    #expect(after > target)                            // but did not arrive
}

@Test func resetToNativeParksAtTheNativeWhite() {
    var m = settled(lux: 300, cct: 3500)
    m.resetToNative()
    #expect(m.displayCCT ~= m.nativeCCT)
}
