import AppKit

/// The parts of the display setup the overlays depend on: which screens exist, where,
/// and at what scale. Deliberately not `visibleFrame` — the Dock or menu bar showing or
/// hiding posts `didChangeScreenParametersNotification` too, and rebuilding the overlays
/// for that tears them down and fades them back in, flashing the desktop. Activation
/// changes (Touch ID arming hands activation to the LocalAuthentication agent) can show
/// or hide an auto-hidden Dock or menu bar mid-lock, so without this a lock could flash.
struct ScreenLayout: Equatable {
    struct Screen: Equatable {
        let displayID: UInt32
        let frame: CGRect
        let scale: CGFloat
    }

    let screens: [Screen]

    static var current: ScreenLayout {
        ScreenLayout(screens: NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Screen(displayID: id, frame: screen.frame, scale: screen.backingScaleFactor)
        })
    }
}
