import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "OverlayWindow")

class OverlayWindowManager {
    private var windows: [NSWindow] = []
    private var screenObserver: Any?
    private var sessionObserver: Any?
    private var contentFactory: ((Int, Bool) -> AnyView)?
    private var screenChangeWork: DispatchWorkItem?

    private let shieldLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    @discardableResult
    func showOverlay(contentFactory factory: @escaping (Int, Bool) -> AnyView) -> Bool {
        contentFactory = factory
        dismissOverlay()
        createWindows()
        guard !windows.isEmpty else {
            logger.error("showOverlay failed — no windows created")
            return false
        }
        startObservingScreenChanges()
        startObservingSessionChanges()
        return true
    }

    func dismissOverlay(animated: Bool = false) {
        stopObservingScreenChanges()
        stopObservingSessionChanges()

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

    func allowSystemDialogs() {
        for window in windows { window.level = .statusBar }
    }

    func blockSystemDialogs() {
        for window in windows { window.level = shieldLevel }
    }

    private func createWindows() {
        guard let factory = contentFactory else {
            logger.error("No content factory to display in overlay")
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            logger.critical("No screens available — cannot create overlay")
            return
        }

        for (index, screen) in screens.enumerated() {
            let isPrimary = (index == 0)
            let content = factory(index, isPrimary)
            let frame = screen.frame
            logger.info("Creating overlay — screen: \(screen.localizedName), role: \(isPrimary ? "primary" : "ambient"), frame: \(frame.debugDescription), scale: \(screen.backingScaleFactor)")
            let window = NSWindow(
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
            window.ignoresMouseEvents = !isPrimary
            window.hasShadow = false

            // NSHostingView defaults to autoresizingMask=0 (no flex), which can cause
            // the SwiftUI content to not fill the window on external/scaled displays.
            let hostingView = NSHostingView(rootView: content)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = window.contentLayoutRect
            window.contentView = hostingView

            if hostingView.frame.size != frame.size {
                logger.warning("Content view size mismatch — expected \(frame.size.debugDescription), got \(hostingView.frame.size.debugDescription)")
            }

            window.alphaValue = 0
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }

            windows.append(window)
        }
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
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }
}
