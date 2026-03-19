import Cocoa
import Carbon
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.bevaka", category: "InputBlocker")

class InputBlocker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isBlocking = false
    private static let inputQueue = DispatchQueue(label: "com.eriknielsen.bevaka.input", qos: .userInteractive)

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .scrollWheel,
            .tabletPointer, .tabletProximity
        ]
        return types.reduce(CGEventMask(0)) { mask, type in mask | (1 << type.rawValue) }
    }()

    func startBlocking() {
        guard !isBlocking else { return }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async {
                        if let refcon = refcon {
                            let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()
                            if let tap = blocker.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                        }
                    }
                    return nil
                }

                if type == .keyDown {
                    let flags = event.flags
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                    // Read saved hotkey from UserDefaults (default: Cmd+Shift+L)
                    let defaults = UserDefaults.standard
                    let savedKeyCode = Int64(defaults.object(forKey: "hotkeyKeyCode") as? Int ?? 37)
                    let savedMods = defaults.object(forKey: "hotkeyModifiers") as? Int ?? (cmdKey | shiftKey)
                    var modifiersMatch = true
                    if savedMods & cmdKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskCommand) }
                    if savedMods & shiftKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskShift) }
                    if savedMods & optionKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskAlternate) }
                    if savedMods & controlKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskControl) }

                    // Let the unlock hotkey through
                    if modifiersMatch && keyCode == savedKeyCode {
                        InputBlocker.inputQueue.async {
                            NotificationCenter.default.post(name: .toggleBevaka, object: nil)
                        }
                        return nil
                    }

                    #if DEBUG
                    if flags.contains(.maskCommand) && flags.contains(.maskShift) && keyCode == 12 {
                        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                        return nil
                    }
                    #endif
                }

                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            logger.error("Could not create event tap")
            NotificationCenter.default.post(name: .bevakInputBlockerFailed, object: nil)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isBlocking = true
    }

    func stopBlocking() {
        guard isBlocking else { return }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isBlocking = false
    }

    deinit { stopBlocking() }
}
