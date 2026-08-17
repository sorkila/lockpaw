import SwiftUI

/// Per-screen root of the lock overlay: switches between the normal lock UI, pure
/// black (fade-to-black burn-in protection), and the bounded agent-attention pulse.
/// The constant black backdrop is load-bearing — overlay windows have clear
/// backgrounds, so the slow cross-fade would otherwise blend through to the desktop.
struct OverlayRootView: View {
    @ObservedObject var controller: LockController
    @ObservedObject var presentationController: PresentationController
    /// Primary screen, or any screen in Mirror mode — shows the full lock UI.
    let showsLockUI: Bool
    let phaseOffset: CGFloat

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch presentationController.presentation {
            case .visible:
                if showsLockUI {
                    LockScreenView(controller: controller, screenRole: .primary, phaseOffset: phaseOffset)
                        .transition(.opacity)
                } else {
                    AmbientScreenView(phaseOffset: phaseOffset)
                        .transition(.opacity)
                }
            case .black:
                // Nothing mounted: no TimelineView, no breathing, no blob compositing.
                EmptyView()
            case .attention:
                // Keyed by generation so a re-ping remounts and restarts the breaths.
                AttentionPulseView()
                    .id(presentationController.attentionGeneration)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
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
