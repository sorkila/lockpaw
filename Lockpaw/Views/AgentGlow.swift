import SwiftUI

/// The agent-ping glow: a full-screen radial bloom at `level` (0 off, 1 the top of a
/// breath), scaled by the Glow strength setting (#19). The one implementation behind the
/// lock screen's glow and the attention pulse over fade-to-black, so the two never drift.
///
/// The mid-stop keeps a wide band at full saturation — a single stop-to-clear ramp washed
/// the brand green toward pale cyan.
///
/// A colour change cross-fades one layer per tone by opacity, on its own slow curve and
/// scoped to that opacity alone (`animation(_:body:)`), instead of re-colouring a single
/// gradient: the colour used to be read outside any animation, so the resting glow snapped
/// when the kind changed. Scoping it also leaves the caller's breath animation on `level`
/// untouched when a ping changes the colour and starts a breath in the same update.
/// Each layer adds light (`.plusLighter`), so mid-fade is a straight mix, not a dip.
struct AgentGlow: View {
    let color: AgentGlowTone
    let level: CGFloat

    @AppStorage(GlowIntensity.storageKey) private var glowIntensityRaw = GlowIntensity.defaultValue.rawValue
    private var intensity: GlowIntensity { GlowIntensity.resolved(from: glowIntensityRaw) }

    /// DESIGN.md glow-out: 1.6s on the looping curve — the glow settles slow.
    static let colourChange: Animation = .easeInOut(duration: 1.6)

    var body: some View {
        GeometryReader { geo in
            let radius = max(geo.size.width, geo.size.height) * 0.8
            ZStack {
                ForEach([AgentGlowTone.teal, .amber], id: \.self) { tone in
                    bloom(tone, radius: radius)
                        .animation(Self.colourChange) { $0.opacity(tone == color ? 1 : 0) }
                        .blendMode(.plusLighter)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func bloom(_ tone: AgentGlowTone, radius: CGFloat) -> some View {
        RadialGradient(
            stops: [
                .init(color: tone.color.opacity(intensity.centreOpacity(at: level)), location: 0),
                .init(color: tone.color.opacity(min(0.14 * level * intensity.peakScale, 0.25)), location: 0.45),
                .init(color: .clear, location: 1)
            ],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

extension AgentGlowTone {
    var color: Color {
        switch self {
        case .teal: return Color("LockpawTeal")
        case .amber: return Color("LockpawAmber")
        }
    }
}
