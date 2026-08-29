import Foundation
import IOKit
import IOKit.hid

func runALSProbe() {
    print("\n\n########## 3. ALS DRIVER (ioreg) ##########")

    print("\n-- 3a. AppleSPUVD6286  (com.apple.driver.AppleALSColorSensor — the sensor) --")
    dumpMatchingClass("AppleSPUVD6286")

    print("\n-- 3b. any node carrying 'CurrentLux' --")
    dumpNodesWithKey("CurrentLux")

    print("\n-- 3c. IOHIDManager: sensor-page (0x20) + vendor-page (0xFF00) devices --")
    dumpHIDSensors()
}

// MARK: - IORegistry helpers

private func dumpMatchingClass(_ cls: String) {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else {
        print("   IOServiceGetMatchingServices(\(cls)) failed"); return
    }
    defer { IOObjectRelease(it) }

    var any = false
    var svc = IOIteratorNext(it)
    while svc != 0 {
        any = true
        var nameC = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(svc, &nameC)

        var ref: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(svc, &ref, kCFAllocatorDefault, 0)
        let props = ref?.takeRetainedValue() as? [String: Any] ?? [:]

        print("\n   • <\(cls)> \"\(String(cString: nameC))\"   (\(props.count) keys)")
        safeDump(props, indent: "       ")

        IOObjectRelease(svc)
        svc = IOIteratorNext(it)
    }
    if !any { print("   (no live instances)") }
}

private func dumpNodesWithKey(_ key: String) {
    var it: io_iterator_t = 0
    guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                   IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS
    else { print("   iterator failed"); return }
    defer { IOObjectRelease(it) }

    var hits = 0
    var entry = IOIteratorNext(it)
    while entry != 0 {
        var ref: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(entry, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let props = ref?.takeRetainedValue() as? [String: Any], props[key] != nil {
            hits += 1
            var nameC = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameC)
            var classC = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &classC)
            print("\n   • \"\(String(cString: nameC))\" <\(String(cString: classC))>")
            safeDump(props, indent: "       ")
        }
        IOObjectRelease(entry)
        entry = IOIteratorNext(it)
    }
    if hits == 0 { print("   (nothing carries \(key))") }
}

// MARK: - IOHIDManager

private func dumpHIDSensors() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matches: [[String: Any]] = [
        [kIOHIDDeviceUsagePageKey as String: 0x20],
        [kIOHIDDeviceUsagePageKey as String: 0xFF00],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
    let open = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    print("   IOHIDManagerOpen -> \(open == kIOReturnSuccess ? "OK" : String(format: "0x%08x", open))")

    guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !devices.isEmpty else {
        print("   no matching HID devices"); return
    }
    for dev in devices {
        let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        let up = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
        let us = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
        print("\n   • \"\(product)\"  primaryUsage=0x\(String(up, radix: 16))/0x\(String(us, radix: 16))")
        guard let elts = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else { continue }
        var seen = Set<UInt64>()
        for e in elts {
            let ep = UInt64(IOHIDElementGetUsagePage(e))
            let eu = UInt64(IOHIDElementGetUsage(e))
            let k = ep << 32 | eu
            if !seen.insert(k).inserted { continue }
            let nm = IOHIDElementGetName(e) as String? ?? ""
            print("       elt page=0x\(String(ep, radix: 16)) usage=0x\(String(eu, radix: 16)) \(nm)")
        }
    }
    IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
}
