import AppKit
import Carbon.HIToolbox

/// One process-wide hotkey via Carbon's RegisterEventHotKey — works without the
/// Accessibility / Input Monitoring permission that NSEvent global monitors need.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void

    nonisolated(unsafe) private static var current: HotKey?

    /// Default combo: ⌃⌥⌘T  (control + option + command + T).
    init(keyCode: UInt32 = UInt32(kVK_ANSI_T),
         modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey),
         onFire: @escaping () -> Void) {
        self.onFire = onFire
        HotKey.current = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let h = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.current?.onFire() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x54544B59), id: 1)   // 'TTKY'
        let r = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)

        if ProcessInfo.processInfo.environment["TRUETONE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[hotkey] InstallEventHandler=\(h) RegisterEventHotKey=\(r) ref=\(ref != nil)\n".utf8))
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
