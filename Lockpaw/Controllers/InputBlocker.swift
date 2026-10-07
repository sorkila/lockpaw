import Cocoa
import Carbon
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "InputBlocker")

class InputBlocker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isBlocking = false
    /// True while the system auth dialog is up: keys must reach it, but Space swipes
    /// stay swallowed — the dialog can sit open indefinitely (#18). Read by the tap
    /// callback, which runs on the main run loop that installed it, so no locking.
    var gesturesOnly = false
    private static let inputQueue = DispatchQueue(label: "com.eriknielsen.lockpaw.input", qos: .userInteractive)

    /// Cached hotkey values — read once, used in the event tap callback
    /// to avoid hitting UserDefaults on every keystroke.
    var cachedKeyCode: Int64 = Int64(HotkeyConfig.defaultKeyCode)
    var cachedModifiers: Int = HotkeyConfig.defaultModifiers

    /// Last time the tap posted `.lockpawPhysicalInput`. Only ever touched from the
    /// tap callback, which runs on the run loop that installed it — the main run
    /// loop, since startBlocking() is called from the main actor — so no locking.
    var lastPhysicalInputPost = Date.distantPast

    private var hotkeyObserver: NSObjectProtocol?

    /// Trackpad gestures are swallowed too: a three-finger swipe switches Spaces, and the
    /// incoming Space is drawn uncovered for the length of the slide (#18).
    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .scrollWheel,
            .tabletPointer, .tabletProximity
        ]
        return types.reduce(LockdownPolicy.gestureEventMask) { mask, type in mask | (1 << type.rawValue) }
    }()

    /// Rest of the gesture stream (a resting finger produces it too) — not proof that
    /// someone is at the keyboard, so it doesn't count toward `.lockpawPhysicalInput`.
    private static let passiveGestureTypes: Set<UInt32> = [
        UInt32(NSEvent.EventType.gesture.rawValue),
        UInt32(NSEvent.EventType.beginGesture.rawValue),
        UInt32(NSEvent.EventType.endGesture.rawValue),
    ]

    init() {
        reloadHotkeyConfig()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .lockpawHotkeyPreferenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadHotkeyConfig()
        }
    }

    /// Refresh cached hotkey key-code and modifiers from HotkeyConfig.
    func reloadHotkeyConfig() {
        cachedKeyCode = Int64(HotkeyConfig.keyCode)
        cachedModifiers = HotkeyConfig.modifiers
    }

    /// `gesturesOnly` keeps just trackpad gestures blocked — used while the auth dialog
    /// needs the keyboard. Switching modes flips a flag the running tap reads; the tap is
    /// never torn down and recreated for it, which would let input through in between.
    func startBlocking(gesturesOnly: Bool = false) {
        self.gesturesOnly = gesturesOnly
        // A tap can die under us (a locked macOS session, a timeout the system wouldn't let
        // us re-enable). Flipping the flag on a dead tap would leave the keyboard unblocked,
        // so only an enabled tap counts as already blocking.
        if isBlocking, let tap = eventTap, CGEvent.tapIsEnabled(tap: tap) { return }
        if isBlocking { stopBlocking() }

        // Ensure cached values are fresh before installing the tap.
        reloadHotkeyConfig()

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

                if let refcon,
                   !LockdownPolicy.swallows(
                       eventType: type.rawValue,
                       gesturesOnly: Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue().gesturesOnly
                   ) {
                    return Unmanaged.passUnretained(event)
                }

                // Physical (hardware) events carry eventSourceUnixProcessID == 0;
                // synthetic posts carry the poster's PID. Best-effort heuristic —
                // signal fade-to-black that the user is present, throttled. The
                // event is still swallowed below; blocking semantics are unchanged.
                if event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
                   !InputBlocker.passiveGestureTypes.contains(type.rawValue), let refcon {
                    let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()
                    let now = Date()
                    if now.timeIntervalSince(blocker.lastPhysicalInputPost) >= Constants.Timing.physicalInputThrottle {
                        blocker.lastPhysicalInputPost = now
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .lockpawPhysicalInput, object: nil)
                        }
                    }
                }

                if type == .keyDown {
                    let flags = event.flags
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                    guard let refcon = refcon else { return nil }
                    let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()

                    // Use cached hotkey values instead of reading UserDefaults
                    let savedKeyCode = blocker.cachedKeyCode
                    let savedMods = blocker.cachedModifiers

                    var modifiersMatch = true
                    if savedMods & cmdKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskCommand) }
                    if savedMods & shiftKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskShift) }
                    if savedMods & optionKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskAlternate) }
                    if savedMods & controlKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskControl) }

                    // Let the unlock hotkey through
                    if modifiersMatch && keyCode == savedKeyCode {
                        InputBlocker.inputQueue.async {
                            NotificationCenter.default.post(name: .toggleLockpaw, object: nil)
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
            NotificationCenter.default.post(name: .lockpawInputBlockerFailed, object: nil)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isBlocking = true
    }

    /// Tear the tap down and build a fresh one in the same mode — after the session or the
    /// display slept, when the old tap may be dead even though it still exists.
    func reinstall() {
        let mode = gesturesOnly
        stopBlocking()
        startBlocking(gesturesOnly: mode)
    }

    func stopBlocking() {
        guard isBlocking else { return }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isBlocking = false
    }

    deinit {
        stopBlocking()
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
