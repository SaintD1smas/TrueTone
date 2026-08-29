import Foundation

/// Reads the MacBook's ambient-light sensor (STMicro VD6286, "AppleALSColorSensor")
/// via the private IOHIDEventSystemClient API. Gives illuminance (lux) and the
/// sensor's own correlated colour temperature, with no entitlement / no TCC prompt.
///
/// See `Sources/ttprobe` and the repo README for how these fields were found.
final class AmbientSensor {

    struct Reading {
        var lux: Double
        var cct: Double          // Kelvin, from the sensor
        var channels: [Double]   // raw CRGB-ish channels, for debugging
    }

    // MARK: private IOKit symbols

    private typealias FnCreate       = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias FnSetMatching  = @convention(c) (UnsafeRawPointer, CFDictionary?) -> Void
    private typealias FnCopyServices = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFArray>?
    private typealias FnCopyEvent    = @convention(c) (UnsafeRawPointer, Int32, UInt32, UInt64) -> UnsafeMutableRawPointer?
    private typealias FnGetFloat     = @convention(c) (UnsafeRawPointer, UInt32) -> Double

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ name: String, _ t: T.Type) -> T? {
        dlsym(iokit, name).map { unsafeBitCast($0, to: t) }
    }

    private let getFloat: FnGetFloat
    private let copyEvent: FnCopyEvent
    private let servicesCF: CFArray          // retained for the lifetime of `service`
    private let service: UnsafeRawPointer

    private let kALS: Int32 = 12
    private let base: UInt32 = 12 << 16      // 0xC0000
    private let offLux: UInt32 = 0x00
    private let offCCT: UInt32 = 0x0a
    private let offChannels: [UInt32] = [0x01, 0x02, 0x03, 0x04]

    // MARK: setup

    init?() {
        guard
            let create       = Self.sym("IOHIDEventSystemClientCreate", FnCreate.self),
            let setMatching  = Self.sym("IOHIDEventSystemClientSetMatching", FnSetMatching.self),
            let copyServices = Self.sym("IOHIDEventSystemClientCopyServices", FnCopyServices.self),
            let copyEvent    = Self.sym("IOHIDServiceClientCopyEvent", FnCopyEvent.self),
            let getFloat     = Self.sym("IOHIDEventGetFloatValue", FnGetFloat.self)
        else { return nil }

        guard let client = create(kCFAllocatorDefault) else { return nil }
        setMatching(client, nil)                       // nil == match everything
        guard let services = copyServices(client)?.takeRetainedValue() else { return nil }

        // The ALS service is the one that yields a type-12 event.
        var found: UnsafeRawPointer?
        for i in 0..<CFArrayGetCount(services) {
            guard let svc = CFArrayGetValueAtIndex(services, i) else { continue }
            if let ev = copyEvent(svc, kALS, 0, 0) {
                Unmanaged<AnyObject>.fromOpaque(ev).release()
                found = svc
                break
            }
        }
        guard let svc = found else { return nil }

        self.getFloat = getFloat
        self.copyEvent = copyEvent
        self.servicesCF = services
        self.service = svc
        _ = client                                    // client can be released; service stays valid
    }

    // MARK: read

    func read() -> Reading? {
        guard let ev = copyEvent(service, kALS, 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(ev).release() }
        return Reading(
            lux: getFloat(ev, base + offLux),
            cct: getFloat(ev, base + offCCT),
            channels: offChannels.map { getFloat(ev, base + $0) }
        )
    }
}
