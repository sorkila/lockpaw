import Carbon
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "HotkeyManager")

// NOTE: Carbon RegisterEventHotKey is deprecated but remains the only way to register
// global hotkeys without Accessibility permission. No modern AppKit/SwiftUI equivalent exists.
// Monitor for a replacement API in future macOS releases.
class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false

    func registerHotkey() {
        guard !isRegistered else { return }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4C4B_5057),
            id: 1
        )
        let modifiers: UInt32 = UInt32(HotkeyConfig.modifiers)
        let keyCode: UInt32 = UInt32(HotkeyConfig.keyCode)

        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )

        guard status == noErr else {
            logger.error("Failed to register hotkey: \(status)")
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                NotificationCenter.default.post(name: .toggleLockpaw, object: nil)
                return noErr
            },
            1, &eventType, nil, &handlerRef
        )

        isRegistered = true
    }

    func unregisterHotkey() {
        guard isRegistered else { return }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
        isRegistered = false
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { registerHotkey() } else { unregisterHotkey() }
    }

    deinit { unregisterHotkey() }
}
