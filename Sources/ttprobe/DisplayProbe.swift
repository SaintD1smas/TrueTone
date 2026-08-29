import Foundation
import CoreGraphics

func runDisplayProbe() {
    print("\n\n########## 1. DISPLAYS (CoreGraphics) ##########")

    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)

    for id in ids {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let main = CGDisplayIsMain(id) != 0
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let sizeMM = CGDisplayScreenSize(id)
        let px = "\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"

        print("\n  ── display \(id)  \(builtin ? "[BUILT-IN]" : "[EXTERNAL]")\(main ? " [MAIN]" : "")")
        print("     vendor=0x\(String(vendor, radix: 16)) model=0x\(String(model, radix: 16)) serial=0x\(String(serial, radix: 16))")
        print("     \(px) px   \(Int(sizeMM.width))x\(Int(sizeMM.height)) mm")

        if let cs = CGDisplayCopyColorSpace(id) as CGColorSpace?,
           let name = cs.name as String? {
            print("     colorSpace: \(name)")
        }

        // --- current gamma / transfer table ---
        let cap = CGDisplayGammaTableCapacity(id)
        var r = [CGGammaValue](repeating: 0, count: Int(cap))
        var g = [CGGammaValue](repeating: 0, count: Int(cap))
        var b = [CGGammaValue](repeating: 0, count: Int(cap))
        var got: UInt32 = 0
        let err = CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &got)
        if err == .success, got > 1 {
            let n = Int(got)
            let idxs = [0, n / 4, n / 2, 3 * n / 4, n - 1]
            func row(_ t: [CGGammaValue]) -> String {
                idxs.map { String(format: "%.4f", t[$0]) }.joined(separator: "  ")
            }
            print("     gamma entries=\(n)   (sampled at 0, 25, 50, 75, 100%)")
            print("        R: \(row(r))")
            print("        G: \(row(g))")
            print("        B: \(row(b))")
            let endWhiteNeutral =
                abs(r[n - 1] - 1) < 0.02 && abs(g[n - 1] - 1) < 0.02 && abs(b[n - 1] - 1) < 0.02
            print("     top entry ≈ (1,1,1): \(endWhiteNeutral)  → \(endWhiteNeutral ? "no white-point shift visible in CG gamma" : "a shift IS present in CG gamma")")
        } else {
            print("     CGGetDisplayTransferByTable err=\(err.rawValue) got=\(got)")
        }
    }

    print("""

      INTERPRETATION
      - EXTERNAL 'Mi Monitor' gamma readable  → we can drive its white point via
        CGSetDisplayTransferByTable (the planned apply path).
      - If BUILT-IN shows top entry ≈ (1,1,1) while True Tone is ON in System
        Settings → Apple applies True Tone below CoreGraphics (in DCP/hardware),
        so we CANNOT read the live shift from CG gamma; mirroring needs a private API.
    """)
}
