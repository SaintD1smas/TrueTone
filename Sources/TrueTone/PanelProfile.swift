import Foundation
import IOKit
import CoreGraphics

/// The external panel's actual colour primaries, read from its EDID.
///
/// The first version computed channel gains with a hardcoded sRGB matrix. The Mi
/// is wide-gamut (green sits at 0.257/0.675, nowhere near sRGB's 0.300/0.600), so
/// those gains cut green and blue harder than the target white point actually
/// needs — the screen came out warmer than asked, by ~2 % at a 6000 K target and
/// ~9 % at 4500 K. Using the panel's own matrix removes that bias.
struct PanelProfile {
    /// XYZ → linear RGB for this panel.
    let xyzToRGB: [[Double]]
    /// The panel's native white point, in Kelvin (from EDID).
    let nativeCCT: Double

    static let sRGB = PanelProfile(
        xyzToRGB: [[ 3.2406, -1.5372, -0.4986],
                   [-0.9689,  1.8758,  0.0415],
                   [ 0.0557, -0.2040,  1.0570]],
        nativeCCT: 6504)

    // MARK: build from primaries

    init(xyzToRGB: [[Double]], nativeCCT: Double) {
        self.xyzToRGB = xyzToRGB
        self.nativeCCT = nativeCCT
    }

    init?(rx: Double, ry: Double, gx: Double, gy: Double,
          bx: Double, by: Double, wx: Double, wy: Double) {
        guard ry > 0, gy > 0, by > 0, wy > 0 else { return nil }
        let m = [[rx / ry, gx / gy, bx / by],
                 [1.0, 1.0, 1.0],
                 [(1 - rx - ry) / ry, (1 - gx - gy) / gy, (1 - bx - by) / by]]
        guard let mInv = Self.invert(m) else { return nil }
        let w = [wx / wy, 1.0, (1 - wx - wy) / wy]
        let s = (0..<3).map { i in (0..<3).map { j in mInv[i][j] * w[j] }.reduce(0, +) }
        let rgbToXYZ = (0..<3).map { r in (0..<3).map { c in m[r][c] * s[c] } }
        guard let inv = Self.invert(rgbToXYZ) else { return nil }

        // McCamy's approximation for the white point's CCT
        let n = (wx - 0.3320) / (0.1858 - wy)
        let cct = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33

        self.xyzToRGB = inv
        self.nativeCCT = (4000...9000).contains(cct) ? cct : 6504
    }

    private static func invert(_ m: [[Double]]) -> [[Double]]? {
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        guard abs(det) > 1e-9 else { return nil }
        func cofactor(_ r: Int, _ c: Int) -> Double {
            let rs = [0, 1, 2].filter { $0 != r }, cs = [0, 1, 2].filter { $0 != c }
            let s = m[rs[0]][cs[0]] * m[rs[1]][cs[1]] - m[rs[0]][cs[1]] * m[rs[1]][cs[0]]
            return (r + c) % 2 == 0 ? s : -s
        }
        return (0..<3).map { r in (0..<3).map { c in cofactor(c, r) / det } }
    }

    // MARK: read the external display's EDID

    private typealias FnCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias FnEDID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32

    /// Profile of the first external display, or nil if the EDID can't be read.
    static func forExternalDisplay() -> PanelProfile? {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let cSym = dlsym(iokit, "IOAVServiceCreateWithService"),
              let eSym = dlsym(iokit, "IOAVServiceCopyEDID")
        else { return nil }
        let create = unsafeBitCast(cSym, to: FnCreate.self)
        let copyEDID = unsafeBitCast(eSym, to: FnEDID.self)

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var target: io_service_t = 0
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            let loc = IORegistryEntryCreateCFProperty(
                svc, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if loc == "External", target == 0 { target = svc } else { IOObjectRelease(svc) }
            svc = IOIteratorNext(iter)
        }
        guard target != 0 else { return nil }
        defer { IOObjectRelease(target) }

        guard let av = create(kCFAllocatorDefault, target)?.takeRetainedValue() else { return nil }
        var data: Unmanaged<CFData>?
        guard copyEDID(Unmanaged.passUnretained(av).toOpaque(), &data) == 0,
              let d = data?.takeRetainedValue() as Data?, d.count >= 35
        else { return nil }

        // EDID 1.x colour characteristics: byte 25/26 hold the low 2 bits of each
        // 10-bit coordinate, bytes 27…34 the high 8 bits.
        let e = [UInt8](d)
        func coord(_ hiByte: Int, _ lowByte: Int, _ shift: Int) -> Double {
            Double((Int(e[hiByte]) << 2) | ((Int(e[lowByte]) >> shift) & 3)) / 1024.0
        }
        return PanelProfile(
            rx: coord(27, 25, 6), ry: coord(28, 25, 4),
            gx: coord(29, 25, 2), gy: coord(30, 25, 0),
            bx: coord(31, 26, 6), by: coord(32, 26, 4),
            wx: coord(33, 26, 2), wy: coord(34, 26, 0))
    }
}
