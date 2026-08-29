import Foundation

// Private IOHIDEventSystemClient API. Symbols are in IOKit.framework but have no
// public header. We keep every opaque ref as a raw pointer so ARC never touches it.
nonisolated(unsafe) private let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

private func sym<T>(_ name: String, as type: T.Type) -> T? {
    guard let p = dlsym(iokit, name) else { return nil }
    return unsafeBitCast(p, to: type)
}

private typealias FnCreate       = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias FnSetMatching  = @convention(c) (UnsafeRawPointer, CFDictionary?) -> Void
private typealias FnCopyServices = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFArray>?
private typealias FnCopyEvent    = @convention(c) (UnsafeRawPointer, Int32, UInt32, UInt64) -> UnsafeMutableRawPointer?
private typealias FnGetFloat     = @convention(c) (UnsafeRawPointer, UInt32) -> Double
private typealias FnGetInt       = @convention(c) (UnsafeRawPointer, UInt32) -> Int
private typealias FnCopyProp     = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?

private let kALS: Int32 = 12                       // kIOHIDEventTypeAmbientLightSensor
private let alsBase: UInt32 = UInt32(kALS) << 16   // 0xC0000

func runHIDEventProbe(watch: Int = 0) {
    print("\n\n########## 2. LIVE ALS EVENT (IOHIDEventSystemClient) ##########")

    guard
        let create       = sym("IOHIDEventSystemClientCreate", as: FnCreate.self),
        let setMatching  = sym("IOHIDEventSystemClientSetMatching", as: FnSetMatching.self),
        let copyServices = sym("IOHIDEventSystemClientCopyServices", as: FnCopyServices.self),
        let copyEvent    = sym("IOHIDServiceClientCopyEvent", as: FnCopyEvent.self),
        let getFloat     = sym("IOHIDEventGetFloatValue", as: FnGetFloat.self),
        let getInt       = sym("IOHIDEventGetIntegerValue", as: FnGetInt.self)
    else { print("   symbol resolve failed — skipping"); return }
    let copyProp = sym("IOHIDServiceClientCopyProperty", as: FnCopyProp.self)

    guard let client = create(kCFAllocatorDefault) else {
        print("   IOHIDEventSystemClientCreate -> nil (needs entitlement) — skipping"); return
    }
    setMatching(client, nil)                          // nil == match everything
    fflush(stdout)

    guard let servicesCF = copyServices(client)?.takeRetainedValue() else {
        print("   copyServices -> nil"); return
    }
    let n = CFArrayGetCount(servicesCF)
    print("   \(n) HID service(s); scanning for AmbientLightSensor (type 12) events…")

    var alsCount = 0
    var alsSvc: UnsafeRawPointer? = nil
    for i in 0..<n {
        guard let svc = CFArrayGetValueAtIndex(servicesCF, i) else { continue }
        guard let ev = copyEvent(svc, kALS, 0, 0) else { continue }
        alsCount += 1
        if alsSvc == nil { alsSvc = svc }

        var label = ""
        if let copyProp {
            for k in ["Product", "PrimaryUsagePage", "PrimaryUsage", "Transport"] {
                if let v = copyProp(svc, k as CFString)?.takeRetainedValue() {
                    label += " \(k)=\(v)"
                }
            }
        }
        print("\n   ── ALS service #\(i)\(label)")
        var any = false
        for off: UInt32 in 0...0x1F {
            let field = alsBase + off
            let f = getFloat(ev, field)
            let iv = getInt(ev, field)
            if f != 0 || iv != 0 {
                any = true
                print(String(format: "      +0x%02x   float = %-18.6f int = %ld", off, f, iv))
            }
        }
        if !any { print("      (all fields read as zero)") }
        Unmanaged<AnyObject>.fromOpaque(ev).release()   // balances the +1 from Copy
    }

    print("""

      \(alsCount) service(s) produced an ALS event.
      offset legend (historical IOKit layout — confirm against the numbers above):
        +0x00 level/lux         +0x01..0x04 rawChannel0..3
        +0x05 colorSpace        +0x06/0x07/0x08 colorComponent0..2  (CIE x / y / …)
        +0x09 colorTemperature(K)
      Non-zero values in +0x01..+0x09  →  real ambient COLOUR is readable unentitled.
      Only +0x00 non-zero           →  lux only; colour needs another route.
    """)

    if watch > 0, let svc = alsSvc {
        print("\n   --watch: polling ALS every 0.5s for \(watch)s — change the room light to")
        print("   see which fields track brightness vs colour.\n")
        print("      time   lux   ch0   ch1   ch2   ch3    +07     +08      CCT(+0a)")
        let ticks = watch * 2
        for t in 0..<ticks {
            if let ev = copyEvent(svc, kALS, 0, 0) {
                func f(_ o: UInt32) -> Double { getFloat(ev, alsBase + o) }
                print(String(format: "     %5.1fs %5.0f %5.0f %5.0f %5.0f %5.0f  %6.1f  %6.1f   %7.1f",
                             Double(t) * 0.5, f(0), f(1), f(2), f(3), f(4), f(7), f(8), f(0x0a)))
                Unmanaged<AnyObject>.fromOpaque(ev).release()
            }
            usleep(500_000)
        }
    }
    _ = client   // keep alive to end of function
}
