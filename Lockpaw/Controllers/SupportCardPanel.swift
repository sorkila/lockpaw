import AppKit
import SwiftUI

/// The once-ever supporter card: a small dark panel hanging under the menu bar icon (or the
/// top-right corner when the icon is hidden). Non-activating, so it never takes the keyboard
/// from the app the user is typing in; its buttons answer a single click while another app
/// stays frontmost. `SupportAskController` decides when it shows and what each answer does.
@MainActor
final class SupportCardPanel {
    enum Phase: Equatable {
        /// The ask, with its opening line chosen by how this user uses Lockpaw.
        case ask(SupportAsk.CardReason)
        case thanks
        case notNow
        case already
        case welcome(friends: [Mascot])
    }

    enum Action: Equatable {
        case support
        case notNow
        case alreadySupport
        case freeLicence
        case openSettings(SettingsSection)
        case close
    }

    var onAction: ((Action) -> Void)?

    private let model = SupportCardModel()
    private var panel: CardPanel?
    private var hosting: NSHostingView<SupportCardView>?
    private var autoClose: DispatchWorkItem?
    /// Bumped on every show and dismiss, so a fade-out that finishes after a re-show
    /// can't order the panel out from under it.
    private var generation = 0

    private var isPresented: Bool { panel?.isVisible == true }

    func show(_ phase: Phase) {
        autoClose?.cancel()
        generation &+= 1
        // Mid fade-out counts as gone: swapping the phase on a panel fading to zero would
        // leave it invisible on screen.
        let wasPresented = isPresented && (panel?.alphaValue ?? 0) >= 1
        if wasPresented {
            withAnimation(Constants.Anim.standard) { model.phase = phase }
        } else {
            model.phase = phase
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if wasPresented {
            // Let SwiftUI lay out the new phase before measuring it.
            DispatchQueue.main.async { [weak self] in self?.place(panel, animated: true) }
        } else {
            present(panel)
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: phase.announcement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])

        if phase == .notNow {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            autoClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.supportCardAutoClose, execute: work)
        }
    }

    func dismiss() {
        autoClose?.cancel()
        guard let panel, isPresented else { return }
        generation &+= 1
        let ending = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == ending else { return }
                // orderOut only, never close(): see the overlay dismiss note in CLAUDE.md.
                panel.orderOut(nil)
            }
        })
    }

    /// A lock started with the card still up: step aside without answering.
    func foldAway() { dismiss() }

    // MARK: - Window

    private func makePanel() -> CardPanel {
        let panel = CardPanel(
            contentRect: NSRect(x: 0, y: 0, width: SupportCardView.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        // Always dark, like the lock screen it follows.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if case .ask = self.model.phase { self.onAction?(.notNow) } else { self.onAction?(.close) }
        }

        let view = SupportCardView(model: model) { [weak self] action in self?.onAction?(action) }
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    private func present(_ panel: CardPanel) {
        let target = frame(for: panel)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: 10), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }

    private func place(_ panel: CardPanel, animated: Bool) {
        let target = frame(for: panel)
        guard target != panel.frame else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }

    /// Hang from the menu bar icon when it's showing, else from the top-right corner of the
    /// main screen. The top edge stays put while the card grows or shrinks between phases.
    private func frame(for panel: CardPanel) -> NSRect {
        let size = NSSize(width: SupportCardView.width, height: hosting?.fittingSize.height ?? 200)
        let statusItem = NSApp.windows.first {
            $0.className == "NSStatusBarWindow" && $0.isVisible && $0.frame.width < 200
        }
        guard let screen = statusItem?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame
        let margin: CGFloat = 10
        let preferredRight = statusItem.map { $0.frame.maxX + 12 } ?? visible.maxX - margin
        let right = min(max(preferredRight, visible.minX + margin + size.width), visible.maxX - margin)
        return NSRect(x: right - size.width, y: visible.maxY - 8 - size.height, width: size.width, height: size.height)
    }
}

/// Holds the phase for the hosted view, so a new phase cross-fades in the same window.
@MainActor
final class SupportCardModel: ObservableObject {
    @Published var phase: SupportCardPanel.Phase = .thanks
}

/// Borderless panels refuse key status; this one may take it if clicked into, so Esc works.
private final class CardPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
