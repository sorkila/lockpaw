import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "OverlayWindow")

class OverlayWindowManager {
    private var windows: [NSWindow] = []
    private var screenObserver: Any?
    private var sessionObserver: Any?
    private var pendingContent: AnyView?

    private let shieldLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    @discardableResult
    func showOverlay(content: some View) -> Bool {
        pendingContent = AnyView(content)
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
                // Delay cleanup to ensure animation is fully complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    for window in windowsToClose {
                        window.orderOut(nil)
                        window.contentView = nil
                        window.close()
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
        guard let content = pendingContent else {
            logger.error("No content to display in overlay")
            return
        }
        guard !NSScreen.screens.isEmpty else {
            logger.critical("No screens available — cannot create overlay")
            return
        }

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = shieldLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.hasShadow = false
            window.contentView = NSHostingView(rootView: content)
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
            DispatchQueue.main.async {
                // Clean up old windows
                for window in self.windows {
                    window.orderOut(nil)
                    window.contentView = nil
                    window.close()
                }
                self.windows.removeAll()
                // Recreate from stored content — no closure capture leak
                self.createWindows()
            }
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
