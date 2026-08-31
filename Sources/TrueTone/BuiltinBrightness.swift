import Foundation
import CoreGraphics

/// Reads the built-in display's brightness (0…1) — the value the F1/F2 keys move.
/// `DisplayServicesGetBrightness` works unentitled on Apple Silicon for the
/// built-in panel (it returns a real value; the external one it refuses).
enum BuiltinBrightness {
    private typealias FnGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    private static let get: FnGet? = {
        guard let h = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
            let s = dlsym(h, "DisplayServicesGetBrightness")
        else { return nil }
        return unsafeBitCast(s, to: FnGet.self)
    }()

    private static var builtinID: CGDirectDisplayID? {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 0…1, or nil if it can't be read.
    static func read() -> Double? {
        guard let get, let id = builtinID else { return nil }
        var f: Float = -1
        return get(id, &f) == 0 && f >= 0 ? Double(f) : nil
    }
}
