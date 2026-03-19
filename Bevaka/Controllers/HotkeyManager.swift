import Carbon
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.bevaka", category: "HotkeyManager")

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false

    func registerHotkey() {
        guard !isRegistered else { return }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4256_4B41),
            id: 1
        )
        let defaults = UserDefaults.standard
        let savedKeyCode = defaults.object(forKey: "hotkeyKeyCode") as? Int ?? 37
        let savedModifiers = defaults.object(forKey: "hotkeyModifiers") as? Int ?? (cmdKey | shiftKey)
        let modifiers: UInt32 = UInt32(savedModifiers)
        let keyCode: UInt32 = UInt32(savedKeyCode)

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
                NotificationCenter.default.post(name: .toggleBevaka, object: nil)
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
