import Testing
@testable import TrueTone

/// The brightness mapping is what makes the two screens agree, and it is entirely
/// arithmetic — so it gets pinned here rather than discovered by eye later.

@Test func uncalibratedMapsOneToOne() {
    let m = BrightnessMap()
    #expect(m.isCalibrated == false)
    #expect(m.luminance(forBuiltin: 0.63) == 63)
    #expect(m.luminance(forBuiltin: 1.0) == 100)
}

@Test func neverLeavesTheSafeRange() {
    let m = BrightnessMap()
    #expect(m.luminance(forBuiltin: 0) >= BrightnessMap.hardMin)
    #expect(m.luminance(forBuiltin: 1) <= BrightnessMap.hardMax)
    #expect(m.luminance(forBuiltin: -5) >= BrightnessMap.hardMin)
    #expect(m.luminance(forBuiltin: 5) <= BrightnessMap.hardMax)
}

@Test func oneAnchorShiftsTheLineThroughIt() {
    var m = BrightnessMap()
    m.record(builtin: 0.60, luminance: 40)          // "at 60 % the Mi should be 40"
    #expect(m.luminance(forBuiltin: 0.60) == 40)
    // default slope preserved: +10 % builtin => +10 luminance
    #expect(m.luminance(forBuiltin: 0.70) == 50)
}

@Test func twoAnchorsSetBothOffsetAndSlope() {
    var m = BrightnessMap()
    m.record(builtin: 0.30, luminance: 20)
    m.record(builtin: 0.90, luminance: 80)
    #expect(m.luminance(forBuiltin: 0.30) == 20)
    #expect(m.luminance(forBuiltin: 0.90) == 80)
    #expect(m.luminance(forBuiltin: 0.60) == 50)     // halfway
}

@Test func aCompressedRangeIsHonoured() {
    // The Mi is dimmer overall, so its usable span is narrower than the Mac's.
    var m = BrightnessMap()
    m.record(builtin: 0.20, luminance: 35)
    m.record(builtin: 1.00, luminance: 75)
    #expect(m.luminance(forBuiltin: 0.60) == 55)
    #expect(m.luminance(forBuiltin: 1.00) == 75)     // never runs past the anchor
}

@Test func mappingIsMonotonic() {
    var m = BrightnessMap()
    m.record(builtin: 0.25, luminance: 30)
    m.record(builtin: 0.95, luminance: 85)
    var previous = -1
    for step in 0...20 {
        let v = m.luminance(forBuiltin: Double(step) / 20)
        #expect(v >= previous)
        previous = v
    }
}

@Test func recordingKeepsTheWidestPairOfAnchors() {
    var m = BrightnessMap()
    m.record(builtin: 0.20, luminance: 20)
    m.record(builtin: 0.50, luminance: 50)
    m.record(builtin: 0.90, luminance: 85)          // should displace the middle one
    #expect(m.luminance(forBuiltin: 0.20) == 20)
    #expect(m.luminance(forBuiltin: 0.90) == 85)
}

@Test func rerecordingNearAnAnchorRefinesIt() {
    var m = BrightnessMap()
    m.record(builtin: 0.30, luminance: 20)
    m.record(builtin: 0.90, luminance: 80)
    m.record(builtin: 0.31, luminance: 35)          // same end, corrected value
    #expect(m.luminance(forBuiltin: 0.31) == 35)
    #expect(m.luminance(forBuiltin: 0.90) == 80)    // far anchor survives
}

@Test func anchorsTooCloseTogetherDoNotDefineASlope() {
    var m = BrightnessMap()
    m.record(builtin: 0.50, luminance: 40)
    m.record(builtin: 0.52, luminance: 90)          // absurd slope if trusted
    // falls back to the single-anchor behaviour rather than a wild extrapolation
    #expect(m.luminance(forBuiltin: 0.60) < 100)
    #expect(m.luminance(forBuiltin: 0.40) > BrightnessMap.hardMin)
}

@Test func resetGoesBackToOneToOne() {
    var m = BrightnessMap()
    m.record(builtin: 0.30, luminance: 90)
    m.reset()
    #expect(m.isCalibrated == false)
    #expect(m.luminance(forBuiltin: 0.63) == 63)
}
