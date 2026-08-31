import Foundation
import IOKit

// Does the external "Mi Monitor" answer DDC/CI over the video link? If yes we can
// drive its brightness (VCP 0x10) to follow the MacBook's brightness keys.

nonisolated(unsafe) let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(iokit, n).map { unsafeBitCast($0, to: t) } }

typealias FnCreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
typealias FnCopyEDID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32
typealias FnRW      = @convention(c) (UnsafeRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

guard
    let createWith = sym("IOAVServiceCreateWithService", FnCreateWithService.self),
    let readI2C    = sym("IOAVServiceReadI2C", FnRW.self),
    let writeI2C   = sym("IOAVServiceWriteI2C", FnRW.self)
else { print("symbols missing"); exit(1) }
let copyEDID = sym("IOAVServiceCopyEDID", FnCopyEDID.self)

// --- find the External DCPAVServiceProxy ---
var it: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)
var target: io_service_t = 0
var svc = IOIteratorNext(it)
while svc != 0 {
    let loc = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
    print("DCPAVServiceProxy Location=\(loc ?? "?")")
    if loc == "External", target == 0 { target = svc } else { IOObjectRelease(svc) }
    svc = IOIteratorNext(it)
}
IOObjectRelease(it)
guard target != 0 else { print("no External display service"); exit(1) }

guard let avObj = createWith(kCFAllocatorDefault, target)?.takeRetainedValue() else {
    print("IOAVServiceCreateWithService -> nil"); exit(1)
}
let av = Unmanaged.passUnretained(avObj).toOpaque()
print("IOAVService created OK")

// --- EDID sanity ---
if let copyEDID {
    var edid: Unmanaged<CFData>?
    let r = copyEDID(av, &edid)
    if r == 0, let d = edid?.takeRetainedValue() as Data? {
        let bytes = [UInt8](d)
        // EDID bytes 8-9 = manufacturer id, 10-11 = product code
        print(String(format: "EDID %d bytes, mfg=%02x%02x product=%02x%02x",
                     bytes.count, bytes.count > 9 ? bytes[8] : 0, bytes.count > 9 ? bytes[9] : 0,
                     bytes.count > 11 ? bytes[10] : 0, bytes.count > 11 ? bytes[11] : 0))
    } else {
        print("CopyEDID ret=\(r)")
    }
}

// --- DDC/CI: read VCP 0x10 (brightness) ---
func ddcRead(_ vcp: UInt8) {
    var msg: [UInt8] = [0x51, 0x82, 0x01, vcp]
    var chk: UInt8 = 0x6E
    for b in msg { chk ^= b }
    msg.append(chk)

    let w = writeI2C(av, 0x37, 0x51, &msg, UInt32(msg.count))
    usleep(50_000)
    var rd = [UInt8](repeating: 0, count: 12)
    let r = readI2C(av, 0x37, 0x51, &rd, UInt32(rd.count))
    let hex = rd.map { String(format: "%02x", $0) }.joined(separator: " ")
    print(String(format: "VCP 0x%02x  write=%d read=%d  <- %@", vcp, w, r, hex))

    // typical reply: 6e 88 02 00 <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
    if rd.count >= 10, rd[2] == 0x02, rd[4] == vcp {
        let maxV = Int(rd[6]) << 8 | Int(rd[7])
        let curV = Int(rd[8]) << 8 | Int(rd[9])
        print("   -> current \(curV) / max \(maxV)   ✅ DDC works")
    }
}

func ddcCurrent(_ vcp: UInt8) -> (cur: Int, max: Int)? {
    var msg: [UInt8] = [0x51, 0x82, 0x01, vcp]
    var chk: UInt8 = 0x6E; for b in msg { chk ^= b }; msg.append(chk)
    _ = writeI2C(av, 0x37, 0x51, &msg, UInt32(msg.count))
    usleep(50_000)
    var rd = [UInt8](repeating: 0, count: 12)
    _ = readI2C(av, 0x37, 0x51, &rd, UInt32(rd.count))
    // locate the VCP payload: ... <vcp> <type> <maxH> <maxL> <curH> <curL>
    for i in 0..<(rd.count - 5) where rd[i] == vcp {
        let maxV = Int(rd[i + 2]) << 8 | Int(rd[i + 3])
        let curV = Int(rd[i + 4]) << 8 | Int(rd[i + 5])
        if maxV > 0, maxV <= 0xFFFF { return (curV, maxV) }
    }
    return nil
}

func ddcWrite(_ vcp: UInt8, _ value: Int, retries: Int = 4) {
    let hi = UInt8((value >> 8) & 0xFF), lo = UInt8(value & 0xFF)
    var msg: [UInt8] = [0x51, 0x84, 0x03, vcp, hi, lo]
    var chk: UInt8 = 0x6E; for b in msg { chk ^= b }; msg.append(chk)
    for _ in 0..<retries {
        usleep(40_000)
        let w = writeI2C(av, 0x37, 0x51, &msg, UInt32(msg.count))
        usleep(50_000)
        _ = w
    }
    print("   wrote VCP 0x\(String(vcp, radix: 16)) = \(value) (x\(retries))")
}

print("\n-- DDC reads --")
for _ in 0..<3 { ddcRead(0x10); usleep(100_000) }

print("\n-- DDC write test (set brightness to 40, then restore) --")
if let (cur, maxV) = ddcCurrent(0x10) {
    print("   before: \(cur)/\(maxV)")
    ddcWrite(0x10, 40)
    usleep(600_000)
    if let (after, _) = ddcCurrent(0x10) {
        print("   after write: \(after)   \(after == 40 ? "✅ WRITE WORKS" : "❌ ignored — DDC/CI writes likely disabled in the monitor's OSD menu")")
    }
    ddcWrite(0x10, cur)
    usleep(400_000)
    if let (r, _) = ddcCurrent(0x10) { print("   restored: \(r)") }
} else {
    print("   couldn't read current brightness")
}

probeBrightnessAPIs()
