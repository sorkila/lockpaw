import Cocoa
import Carbon
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "HotkeyManager")

/// Manages global hotkey detection using a CGEventTap on a dedicated background thread.
/// Running on its own thread with its own run loop bypasses the LSUIElement activation
/// issue where the main run loop doesn't process events until user interaction.
/// Requires Accessibility permission.
class HotkeyManager {
    private var eventTap: CFMachPort?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private(set) var isRegistered = false

    func registerHotkey() {
        if isRegistered {
            guard !AXIsProcessTrusted() else { return }
            // Accessibility was revoked (dead tap) — tear down and re-register
            logger.info("registerHotkey: tap registered but Accessibility revoked — re-registering")
            unregisterHotkey()
        }

        guard AXIsProcessTrusted() else {
            logger.warning("registerHotkey: skipped — Accessibility not granted")
            return
        }

        logger.info("registerHotkey: accessibility=\(AXIsProcessTrusted())")

        // Create the event tap on the calling thread first
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                // Re-enable if the tap gets disabled by the system
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = manager.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags

                let savedKeyCode = HotkeyConfig.keyCode
                let savedMods = HotkeyConfig.modifiers

                guard keyCode == savedKeyCode else { return Unmanaged.passUnretained(event) }

                var matches = true
                if savedMods & cmdKey != 0 { matches = matches && flags.contains(.maskCommand) }
                if savedMods & shiftKey != 0 { matches = matches && flags.contains(.maskShift) }
                if savedMods & optionKey != 0 { matches = matches && flags.contains(.maskAlternate) }
                if savedMods & controlKey != 0 { matches = matches && flags.contains(.maskControl) }

                if matches {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .toggleLockpaw, object: nil)
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            logger.error("Failed to create event tap for hotkey")
            return
        }

        // Run the event tap on a dedicated background thread with its own run loop.
        // This avoids the LSUIElement main run loop activation issue entirely.
        let thread = Thread { [weak self] in
            guard let self, let tap = self.eventTap else { return }

            self.tapRunLoop = CFRunLoopGetCurrent()

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            logger.info("registerHotkey: event tap running on background thread")

            CFRunLoopRun()

            logger.info("registerHotkey: background run loop exited")
        }
        thread.name = "com.eriknielsen.lockpaw.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread

        isRegistered = true
        logger.info("registerHotkey: complete")
    }

    func unregisterHotkey() {
        guard isRegistered else { return }

        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = tapRunLoop { CFRunLoopStop(rl) }
        tapRunLoop = nil
        tapThread = nil
        eventTap = nil
        isRegistered = false
        logger.info("unregisterHotkey: complete")
    }

    func reregister() {
        logger.info("reregister called")
        unregisterHotkey()
        registerHotkey()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { registerHotkey() } else { unregisterHotkey() }
    }

    deinit { unregisterHotkey() }
}
