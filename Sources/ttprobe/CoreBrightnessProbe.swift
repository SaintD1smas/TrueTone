import Foundation
import ObjectiveC.runtime

func runCoreBrightnessProbe(poke: Bool) {
    print("\n\n########## 4. CoreBrightness (private, ObjC runtime) ##########")

    let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    guard dlopen(path, RTLD_NOW) != nil else {
        print("   dlopen FAILED: \(String(cString: dlerror()))"); return
    }
    print("   dlopen OK")

    for cls in [
        "CBTrueToneClient", "CBBlueLightClient", "BrightnessSystemClient",
        "CBDisplay", "CBColorAdaptationClient", "CBAdaptationClient",
        "CBTrueToneModel", "CBTrueToneAdaptation", "CBTemperatureAdaptationClient",
        "CBIntelligentBrightnessClient", "CBAmbientLightSensorClient",
    ] {
        dumpClass(cls)
    }

    if poke {
        print("\n-- 4b. --poke: instantiate + call zero-arg getters --")
        pokeClient("CBTrueToneClient", ["enabled", "available", "supported"])
        pokeClient("CBBlueLightClient", ["enabled", "available", "supported", "strength"])
    } else {
        print("\n   (run with --poke to try live getters)")
    }
}

private func dumpClass(_ name: String) {
    guard let cls: AnyClass = objc_getClass(name) as? AnyClass else {
        print("\n   [\(name)] — not present"); return
    }
    print("\n   ===== \(name) =====")

    var ic: UInt32 = 0
    if let ivars = class_copyIvarList(cls, &ic) {
        for i in 0..<Int(ic) {
            let nm = ivar_getName(ivars[i]).map { String(cString: $0) } ?? "?"
            print("     ivar  \(nm)")
        }
        free(ivars)
    }
    func methods(_ c: AnyClass, _ pfx: String) {
        var mc: UInt32 = 0
        guard let ml = class_copyMethodList(c, &mc) else { return }
        var sels: [String] = []
        for i in 0..<Int(mc) { sels.append(String(cString: sel_getName(method_getName(ml[i])))) }
        free(ml)
        for s in sels.sorted() { print("     \(pfx) \(s)") }
    }
    methods(cls, "-")
    if let meta: AnyClass = object_getClass(cls) { methods(meta, "+") }
}

private func pokeClient(_ name: String, _ selectors: [String]) {
    guard let cls = objc_getClass(name) as? NSObject.Type else {
        print("\n   [\(name)] not present"); return
    }
    let obj = cls.init()
    print("\n   [\(name)]")
    for s in selectors {
        let sel = NSSelectorFromString(s)
        guard obj.responds(to: sel) else { print("     \(s): (no)"); continue }
        let r = obj.perform(sel)?.takeUnretainedValue()
        print("     \(s) -> \(r.map { "\($0)" } ?? "nil / primitive")")
    }
}
