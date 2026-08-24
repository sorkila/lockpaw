import SwiftUI

/// Per-screen root of the lock overlay: switches between the normal lock UI, pure
/// black (fade-to-black burn-in protection), and the bounded agent-attention pulse.
/// The constant black backdrop is load-bearing — overlay windows have clear
/// backgrounds, so the slow cross-fade would otherwise blend through to the desktop.
///
/// Cross-fades are driven by explicit opacity values, not `.transition(.opacity)`
/// on switched-out branches — removal transitions hard-cut inside NSHostingView
/// overlay windows on macOS 26. Subtrees unmount only after their fade completes
/// (so a black screen still costs nothing: no TimelineView, no breathing, no blobs).
struct OverlayRootView: View {
    @ObservedObject var controller: LockController
    @ObservedObject var presentationController: PresentationController
    /// Primary screen, or any screen in Mirror mode — shows the full lock UI.
    let showsLockUI: Bool
    let phaseOffset: CGFloat

    @State private var lockUIMounted = true
    @State private var lockUIOpacity: Double = 1
    @State private var pulseMounted = false
    @State private var pulseOpacity: Double = 0
    /// Bumped on every presentation change — a delayed unmount only lands if no
    /// newer change superseded it (same guard pattern as the ping-glow generation).
    @State private var fadeGeneration = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lockUIMounted {
                Group {
                    if showsLockUI {
                        LockScreenView(controller: controller, screenRole: .primary, phaseOffset: phaseOffset)
                    } else {
                        AmbientScreenView(phaseOffset: phaseOffset)
                    }
                }
                .opacity(lockUIOpacity)
            }

            if pulseMounted {
                // Keyed by generation so a re-ping remounts and restarts the breaths.
                AttentionPulseView()
                    .id(presentationController.attentionGeneration)
                    .opacity(pulseOpacity)
            }
        }
        .ignoresSafeArea()
        .onChange(of: presentationController.presentation) { old, new in
            apply(from: old, to: new)
        }
    }

    private func apply(from old: LockPresentation, to new: LockPresentation) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = PresentationController.animation(from: old, to: new)

        func animate(_ changes: () -> Void) {
            if reduceMotion { changes() } else { withAnimation(animation, changes) }
        }
        func unmountAfter(_ delay: TimeInterval, _ changes: @escaping () -> Void) {
            guard !reduceMotion else { changes(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == fadeGeneration else { return }
                changes()
            }
        }

        switch new {
        case .visible:
            lockUIMounted = true
            animate {
                lockUIOpacity = 1
                pulseOpacity = 0
            }
            unmountAfter(Constants.Timing.revealFade) { pulseMounted = false }

        case .black:
            let duration = old == .attention
                ? Constants.Timing.attentionFadeOut
                : Constants.Timing.fadeToBlackDuration
            animate {
                lockUIOpacity = 0
                pulseOpacity = 0
            }
            unmountAfter(duration) {
                lockUIMounted = false
                pulseMounted = false
            }

        case .attention:
            pulseMounted = true
            animate { pulseOpacity = 1 }
        }
    }
}

/// The agent-ping pulse while black, on every screen (the primary lock UI is
/// unmounted): the lock screen's teal glow breathing the same envelope, rising from
/// black and settling to the pulse floor until the attention window fades back out.
/// Under Reduce Motion the glow holds at the floor with no motion.
private struct AttentionPulseView: View {
    @State private var glow: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            RadialGradient(
                stops: [
                    .init(color: Color("LockpawTeal").opacity(0.30 * glow), location: 0),
                    .init(color: Color("LockpawTeal").opacity(0.14 * glow), location: 0.45),
                    .init(color: .clear, location: 1)
                ],
                center: .center,
                startRadius: 0,
                endRadius: max(geo.size.width, geo.size.height) * 0.8
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else {
                glow = Constants.Timing.pingPulseFloor
                return
            }
            let half = Constants.Timing.pingPulsePeriod / 2
            for breath in 0..<Constants.Timing.pingPulseCount {
                let start = Double(breath) * Constants.Timing.pingPulsePeriod
                DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                    withAnimation(.easeInOut(duration: half)) { glow = 1 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + half) {
                    withAnimation(.easeInOut(duration: half)) { glow = Constants.Timing.pingPulseFloor }
                }
            }
        }
    }
}
