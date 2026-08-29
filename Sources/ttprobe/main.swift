import Foundation
import Darwin
import ObjectiveC.runtime

// TrueTone spike probe.
// Goal: find out what signal we can get on THIS Mac to drive a True Tone clone
// on the external "Mi Monitor", using the MacBook's own ambient light sensor.
//
//   1. DISPLAYS      - can we read/write the Mi's white point? Does the built-in
//                      panel's live True Tone shift show up in CoreGraphics gamma?
//   2. HID EVENT     - IOHIDEventSystemClient live AmbientLightSensor event: does it
//                      carry only lux, or also raw CRGB channels / colour temperature?
//   3. ALS ioreg     - the AppleALSColorSensor (STMicro VD6286) driver properties.
//   4. CoreBrightness - does the private framework expose a readable / settable
//                      True Tone state we can cross-check against?
//
// Default run is read-only. Pass --poke to also instantiate CoreBrightness clients.

setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
let poke = args.contains("--poke")
let probeCB = args.contains("--cb")          // CoreBrightness probe destabilises the ObjC
                                             // runtime in-process; off unless asked.
let watchSeconds: Int = args.firstIndex(of: "--watch").map { idx in
    Int(args[safe: idx + 1] ?? "") ?? 15
} ?? 0

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

func hwModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
}

/// String form of an arbitrary CF/NS value that never sends a message to an
/// object that might not survive it (the earlier abort came from doing exactly that).
func describe(_ value: Any, depth: Int = 0) -> String {
    switch value {
    case let n as NSNumber:
        return n.stringValue
    case let s as String:
        return "\"\(s)\""
    case let d as Data:
        let hex = d.prefix(40).map { String(format: "%02x", $0) }.joined()
        return "Data(\(d.count))<\(hex)\(d.count > 40 ? "…" : "")>"
    case let date as Date:
        return "\(date)"
    case let arr as [Any]:
        if depth > 2 { return "[\(arr.count) items]" }
        return "[" + arr.prefix(8).map { describe($0, depth: depth + 1) }.joined(separator: ", ")
            + (arr.count > 8 ? ", …]" : "]")
    case let dict as [String: Any]:
        if depth > 3 { return "{\(dict.count) keys}" }
        return "{" + dict.sorted { $0.key < $1.key }.prefix(20)
            .map { "\($0.key): \(describe($0.value, depth: depth + 1))" }
            .joined(separator: ", ") + (dict.count > 20 ? ", …}" : "}")
    case let dict as NSDictionary:
        return describe(dict as? [String: Any] ?? [:], depth: depth)
    default:
        return "<\(String(cString: object_getClassName(value as AnyObject)))>"
    }
}

/// Print a property dict, but only stringify values that round-trip through
/// PropertyListSerialization (which *throws* on bad input rather than abort()).
func safeDump(_ props: [String: Any], indent: String) {
    for (k, v) in props.sorted(by: { $0.key < $1.key }) {
        let plistable = (try? PropertyListSerialization.data(fromPropertyList: [k: v], format: .binary, options: 0)) != nil
        if plistable {
            print("\(indent)\(k) = \(describe(v))")
        } else {
            print("\(indent)\(k) = <non-plist \(String(cString: object_getClassName(v as AnyObject)))>")
        }
    }
}

print(String(repeating: "=", count: 68))
print("TrueTone spike probe   \(Date())")
print("\(ProcessInfo.processInfo.operatingSystemVersionString)   \(hwModel())   poke=\(poke)")
print(String(repeating: "=", count: 68))

runDisplayProbe();               fflush(stdout)
runHIDEventProbe(watch: watchSeconds); fflush(stdout)
runALSProbe();                    fflush(stdout)
if probeCB { runCoreBrightnessProbe(poke: poke); fflush(stdout) }

print("\n[done]")
