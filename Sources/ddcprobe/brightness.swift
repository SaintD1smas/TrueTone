import Foundation
import CoreGraphics

// Called from main after the DDC test. Tries the higher-level private brightness
// APIs on the external display; if any of them actually moves the panel we can
// use it for brightness sync instead of raw I2C.

func externalDisplayID() -> CGDirectDisplayID? {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids.first { CGDisplayIsBuiltin($0) == 0 }
}

func builtinDisplayID() -> CGDirectDisplayID? {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids.first { CGDisplayIsBuiltin($0) != 0 }
}

func probeBrightnessAPIs() {
    print("\n\n########## higher-level brightness APIs ##########")

    // Can we READ the built-in brightness (to follow the brightness keys)?
    if let b = builtinDisplayID() {
        let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
        typealias FnGetD = @convention(c) (UInt32) -> Double
        if let g = dlsym(cd, "CoreDisplay_Display_GetUserBrightness").map({ unsafeBitCast($0, to: FnGetD.self) }) {
            print("built-in (id \(b)) CoreDisplay UserBrightness = \(g(b))   << change screen brightness and re-run to confirm it tracks")
        }
        let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        typealias FnGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        if let g = dlsym(ds, "DisplayServicesGetBrightness").map({ unsafeBitCast($0, to: FnGet.self) }) {
            var f: Float = -1; let r = g(b, &f)
            print("built-in DisplayServicesGetBrightness ret=\(r) value=\(f)")
        }
    }

    guard let ext = externalDisplayID() else { print("no external display"); return }
    print("\nexternal display id = \(ext)")

    // --- DisplayServices ---
    let dsPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    if let h = dlopen(dsPath, RTLD_NOW) {
        typealias FnGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        typealias FnSet = @convention(c) (UInt32, Float) -> Int32
        typealias FnCan = @convention(c) (UInt32) -> UInt8
        let get = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: FnGet.self) }
        let set = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: FnSet.self) }
        let can = dlsym(h, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: FnCan.self) }
        print("\n[DisplayServices] loaded  get=\(get != nil) set=\(set != nil) can=\(can != nil)")
        if let can { print("  CanChangeBrightness -> \(can(ext))") }
        if let get, let set {
            var b: Float = -1
            let gr = get(ext, &b)
            print("  GetBrightness ret=\(gr) value=\(b)")
            let sr = set(ext, 0.35)
            usleep(500_000)
            var b2: Float = -1
            _ = get(ext, &b2)
            print("  SetBrightness(0.35) ret=\(sr)  now=\(b2)  \(abs(b2 - 0.35) < 0.05 ? "✅ works" : "❌ no change")")
            if b >= 0 { _ = set(ext, b); print("  restored to \(b)") }
        }
    } else {
        print("\n[DisplayServices] dlopen failed")
    }

    // --- CoreDisplay ---
    let cdPaths = [
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
    ]
    var cd: UnsafeMutableRawPointer?
    for p in cdPaths { cd = dlopen(p, RTLD_NOW); if cd != nil { break } }
    if let cd {
        typealias FnGetD = @convention(c) (UInt32) -> Double
        typealias FnSetD = @convention(c) (UInt32, Double) -> Void
        let get = dlsym(cd, "CoreDisplay_Display_GetUserBrightness").map { unsafeBitCast($0, to: FnGetD.self) }
        let set = dlsym(cd, "CoreDisplay_Display_SetUserBrightness").map { unsafeBitCast($0, to: FnSetD.self) }
        let setLin = dlsym(cd, "CoreDisplay_Display_SetLinearBrightness").map { unsafeBitCast($0, to: FnSetD.self) }
        print("\n[CoreDisplay] loaded  get=\(get != nil) set=\(set != nil) setLinear=\(setLin != nil)")
        if let get, let set {
            let b = get(ext)
            print("  GetUserBrightness -> \(b)")
            set(ext, 0.35)
            usleep(500_000)
            let b2 = get(ext)
            print("  SetUserBrightness(0.35)  now=\(b2)  \(abs(b2 - 0.35) < 0.05 ? "✅ works" : "❌ no change")")
            set(ext, b > 0 ? b : 0.7)
            print("  restored to \(b)")
        }
    } else {
        print("\n[CoreDisplay] dlopen failed")
    }
}
