import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "OverlayWindow")

/// Borderless windows refuse key status by default; the primary overlay must be able
/// to become key so the app can be activated while locked — cursor concealment
/// (`NSCursor.setHiddenUntilMouseMoves`) only works while the app is active.
private final class OverlayWindow: NSWindow {
    /// Only the primary overlay takes key status. Ambient windows still swallow clicks
    /// (see `ignoresMouseEvents` below), but must not steal focus from the screen that
    /// carries the fallback-auth controls.
    var acceptsKey = true
    override var canBecomeKey: Bool { acceptsKey }
}

/// Belt and braces for the armed-Touch ID case: the LocalAuthentication agent holds
/// activation, so the overlay is not key and a first click could be spent activating
/// Lockpaw rather than pressing the control under the pointer. Measured on macOS 26 a stock
/// NSHostingView already presses the button on that first click, so this changes nothing
/// today — it is here so a future AppKit that reverts to the documented behaviour cannot
/// cost the fallback-auth button a second click.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class OverlayWindowManager {
    private var windows: [NSWindow] = []
    private var screenObserver: Any?
    private var sessionObserver: Any?
    private var contentFactory: ((Int, Bool) -> AnyView)?
    private var screenChangeWork: DispatchWorkItem?
    private var mouseMoveMonitors: [Any] = []
    private var cursorRehideTimer: Timer?
    private var activationObserver: Any?
    /// Overlay holding key for the current auth attempt (Mirror mode), or nil when the
    /// primary has it as usual — see OverlayPolicy.acceptsKey.
    private var focusedIndex: Int?
    /// Called once when the lock's initial fade-in completes — the cover is opaque.
    private var onCoverOpaque: (() -> Void)?
    /// Display setup the current overlays were built for — see ScreenLayout.
    private var builtLayout: ScreenLayout?
    private var kioskKeyMonitor: Any?
    /// The activation policy kiosk mode replaced, or nil when kiosk mode is off. Settings
    /// also makes the app regular while its window is open, so leaving kiosk mode restores
    /// whatever was there rather than assuming accessory.
    private var policyBeforeKiosk: NSApplication.ActivationPolicy?

    private let shieldLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    @discardableResult
    func showOverlay(
        contentFactory factory: @escaping (Int, Bool) -> AnyView,
        onOpaque: (() -> Void)? = nil
    ) -> Bool {
        contentFactory = factory
        dismissOverlay()
        focusedIndex = nil
        onCoverOpaque = onOpaque
        createWindows()
        guard !windows.isEmpty else {
            logger.error("showOverlay failed — no windows created")
            return false
        }
        startObservingScreenChanges()
        startObservingSessionChanges()
        startCursorConcealment()
        return true
    }

    func dismissOverlay(animated: Bool = false) {
        exitKioskMode()
        stopObservingScreenChanges()
        stopObservingSessionChanges()
        stopCursorConcealment()
        onCoverOpaque = nil
        focusedIndex = nil

        if animated {
            let windowsToClose = windows
            windows.removeAll()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for window in windowsToClose {
                    window.animator().alphaValue = 0
                }
            }, completionHandler: {
                // Delay cleanup so animation objects are fully released
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    for window in windowsToClose {
                        window.orderOut(nil)
                        window.contentView = nil
                    }
                }
            })
        } else {
            for window in windows {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            windows.removeAll()
        }
    }

    /// For the lock-screen password field on screen `index`. Presentation options are
    /// ignored for an accessory (LSUIElement) app — measured on macOS 26, Cmd+Tab still
    /// switched apps — so Lockpaw becomes a regular app for as long as the field is up.
    /// `.hideDock` keeps the Dock icon that comes with that out of sight.
    func enterKioskMode(screenAt index: Int) {
        if policyBeforeKiosk == nil { policyBeforeKiosk = NSApp.activationPolicy() }
        NSApp.setActivationPolicy(.regular)
        focus(screenAt: index)
        NSApp.presentationOptions = PasswordEntryPolicy.kioskOptions
        if kioskKeyMonitor == nil {
            kioskKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // The unlock hotkey still works with the field focused: secure input hides
                // it from the hotkey tap, so it is recognised here instead.
                if HotkeyConfig.matches(keyCode: Int(event.keyCode), modifierFlags: event.modifierFlags) {
                    NotificationCenter.default.post(name: .toggleLockpaw, object: nil)
                    return nil
                }
                return PasswordEntryPolicy.swallowsKeyEquivalent(modifiers: event.modifierFlags) ? nil : event
            }
        }
    }

    func exitKioskMode() {
        if let monitor = kioskKeyMonitor {
            NSEvent.removeMonitor(monitor)
            kioskKeyMonitor = nil
        }
        guard let previous = policyBeforeKiosk else { return }
        policyBeforeKiosk = nil
        NSApp.presentationOptions = []
        NSApp.setActivationPolicy(previous)
        blockSystemDialogs()
    }

    /// Auth is over and the lock resumes — also hands key status back to the primary,
    /// undoing any `focus(screenAt:)` for the attempt that just ended.
    func blockSystemDialogs() {
        for window in windows { window.level = shieldLevel }
        guard focusedIndex != nil else { return }
        focusedIndex = nil
        applyKeyRouting()
        // Restoring acceptsKey only governs future key changes; the focused secondary
        // would otherwise stay key and the next hotkey or menu unlock would open its
        // dialog there.
        windows.first?.makeKey()
    }

    /// Hand key status to the overlay on screen `index` (the order `contentFactory` was
    /// called in) for one auth attempt, so in Mirror mode the password field takes the
    /// keyboard on the screen whose button was clicked.
    func focus(screenAt index: Int) {
        guard windows.indices.contains(index) else { return }
        focusedIndex = index
        applyKeyRouting()
        NSApp.activate(ignoringOtherApps: true)
        windows[index].makeKey()
    }

    /// Same displays as before (the lid opened onto the layout we built for): put each
    /// overlay back on its screen at full opacity without a rebuild, so nothing fades in.
    private func reassertCover() {
        for (window, screen) in zip(windows, NSScreen.screens) {
            window.setFrame(screen.frame, display: true)
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    private func applyKeyRouting() {
        for (index, window) in windows.enumerated() {
            (window as? OverlayWindow)?.acceptsKey = OverlayPolicy.acceptsKey(index: index, focusedIndex: focusedIndex)
        }
    }

    private func createWindows() {
        guard let factory = contentFactory else {
            logger.error("No content factory to display in overlay")
            return
        }
        let screens = NSScreen.screens
        builtLayout = ScreenLayout.current
        guard !screens.isEmpty else {
            logger.critical("No screens available — cannot create overlay")
            return
        }

        for (index, screen) in screens.enumerated() {
            let isPrimary = (index == 0)
            let content = factory(index, isPrimary)
            let frame = screen.frame
            logger.info("Creating overlay — screen: \(screen.localizedName), role: \(isPrimary ? "primary" : "ambient"), frame: \(frame.debugDescription), scale: \(screen.backingScaleFactor)")
            let window = OverlayWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(frame, display: true)
            window.level = shieldLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            // Every overlay swallows clicks, ambient ones included. With
            // ignoresMouseEvents the window is transparent to the pointer, so on a
            // secondary display each click passed through the (visually opaque) overlay
            // to whatever app sat underneath — keyboard was blocked, but buttons under
            // the cover were still clickable while locked. Rules in OverlayPolicy.
            let config = OverlayPolicy.config(isPrimary: isPrimary)
            window.ignoresMouseEvents = config.ignoresMouseEvents
            window.acceptsKey = OverlayPolicy.acceptsKey(index: index, focusedIndex: focusedIndex)
            window.hasShadow = false

            // NSHostingView defaults to autoresizingMask=0 (no flex), which can cause
            // the SwiftUI content to not fill the window on external/scaled displays.
            let hostingView = OverlayHostingView(rootView: content)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = window.contentLayoutRect
            window.contentView = hostingView

            if hostingView.frame.size != frame.size {
                logger.warning("Content view size mismatch — expected \(frame.size.debugDescription), got \(hostingView.frame.size.debugDescription)")
            }

            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }

        // One group for every screen, so its completion means the whole cover is opaque.
        // Touch ID arms from there: its prompt opens the instant the sensor arms and would
        // show through a cover that is still fading in (#28).
        let fadingIn = windows
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.Timing.overlayFadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for window in fadingIn { window.animator().alphaValue = 1 }
        }, completionHandler: { [weak self] in
            guard let self, let opaque = self.onCoverOpaque else { return }
            self.onCoverOpaque = nil
            opaque()
        })
    }

    // MARK: - Cursor concealment

    /// Hide the pointer while locked, but never trap the user: the cursor reappears
    /// the moment the mouse moves (it's needed to reach the fallback-auth controls)
    /// and slips away again after a few seconds of stillness. NSCursor.hide() is
    /// deliberately avoided — an unbalanced hide would leave the pointer invisible
    /// while someone tries to click the unlock chevron.
    private func startCursorConcealment() {
        stopCursorConcealment()
        // setHiddenUntilMouseMoves only takes effect while the app is active — and
        // when locking via the global hotkey some other app is frontmost. Activate
        // and make the primary overlay key first, then hide on the next runloop turn
        // so the activation has landed.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)
        DispatchQueue.main.async {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        let onMove: () -> Void = { [weak self] in self?.scheduleCursorRehide() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { _ in onMove() }) {
            mouseMoveMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            onMove()
            return event
        }) {
            mouseMoveMonitors.append(local)
        }
    }

    /// While the Touch ID sensor is armed this re-hide does nothing, and that is deliberate.
    /// `setHiddenUntilMouseMoves` is a no-op unless the app is active, and the
    /// LocalAuthentication agent holds activation for the whole armed period — arming alone
    /// puts the pointer back on screen within half a second. Measured on macOS 26: Lockpaw
    /// *can* take activation back (~400-500ms) and a hide applied in that window does land,
    /// but the agent reclaims it about a second later and reveals the pointer again, so
    /// fighting for it buys a flicker and costs an activation steal every few seconds.
    /// Accepted trade, in the spirit of the fade-to-black pointer note: while a finger press
    /// can unlock, the pointer is visible over the lock screen. It conceals as before
    /// whenever nothing is armed — no Touch ID, biometry unavailable, passive auth
    /// suspended, or faded to black (see `reconcealCursor`). `NSCursor.hide()` remains
    /// rejected for the reasons in CLAUDE.md.
    private func scheduleCursorRehide() {
        cursorRehideTimer?.invalidate()
        cursorRehideTimer = Timer.scheduledTimer(withTimeInterval: Constants.Timing.cursorIdleHide, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// After Touch ID is disarmed for black (#39). Cancelling the evaluation doesn't promise
    /// activation comes back here, and the hide is a no-op until it lands (~400-500ms), so
    /// the hide that counts is the one on `didBecomeActive`.
    func reconcealCursor() {
        guard !windows.isEmpty else { return }
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let observer = self.activationObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                self.activationObserver = nil
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)
        DispatchQueue.main.async {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func stopCursorConcealment() {
        cursorRehideTimer?.invalidate()
        cursorRehideTimer = nil
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
        activationObserver = nil
        for monitor in mouseMoveMonitors { NSEvent.removeMonitor(monitor) }
        mouseMoveMonitors.removeAll()
        // Make sure the pointer isn't left hidden after unlock.
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func startObservingScreenChanges() {
        stopObservingScreenChanges()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Cancel any pending recreation — true debounce so only the last
            // notification in a burst triggers work.
            self.screenChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Dock / menu bar visibility changes post this too; only rebuild when the
                // screens themselves changed, or the overlays flash the desktop.
                // Lid closed with no external display: there is no screen at all for a
                // moment. Keep the overlays rather than tearing them down — rebuilding when
                // the lid opens would fade back in from transparent and show the desktop.
                guard !NSScreen.screens.isEmpty else {
                    logger.info("No screens (lid closed?) — keeping overlays until displays return")
                    return
                }
                guard ScreenLayout.current != self.builtLayout else {
                    logger.debug("Screen parameters changed — layout unchanged, keeping overlays")
                    self.reassertCover()
                    return
                }
                logger.info("Screen parameters changed — recreating overlay windows")
                // Do NOT call window.close() — closing during a fade-in animation
                // causes EXC_BAD_ACCESS in _NSWindowTransformAnimation dealloc.
                for window in self.windows {
                    window.animator().alphaValue = 0
                    window.orderOut(nil)
                    window.contentView = nil
                }
                self.windows.removeAll()
                self.createWindows()
            }
            self.screenChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func stopObservingScreenChanges() {
        // A rebuild queued by the debounce must not run after dismiss: it would put
        // shield-level overlays back up over an unlocked Mac with nothing to take them down.
        screenChangeWork?.cancel()
        screenChangeWork = nil
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
    }

    private func startObservingSessionChanges() {
        stopObservingSessionChanges()
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .lockpawSessionLost, object: nil)
        }
    }

    private func stopObservingSessionChanges() {
        if let observer = sessionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sessionObserver = nil
        }
    }

    deinit {
        stopObservingScreenChanges()
        stopObservingSessionChanges()
        stopCursorConcealment()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }
}
