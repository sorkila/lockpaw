import SwiftUI

struct AmbientScreenView: View {
    var phaseOffset: CGFloat = 0

    @State private var phase: CGFloat = 0
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if !reduceMotion {
                    blobs(geo: geo)
                        .opacity(appeared ? 1 : 0)
                }

                // Vignette: darkens edges so blobs fade naturally at screen borders
                RadialGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    center: .center,
                    startRadius: min(geo.size.width, geo.size.height) * 0.25,
                    endRadius: max(geo.size.width, geo.size.height) * 0.6
                ).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeIn(duration: 3.0)) { appeared = true }
            withAnimation(Constants.Anim.breathe) { phase = 1 }
        }
    }

    // MARK: - Blobs

    private func blobs(geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let p = phase + phaseOffset

        return ZStack {
            // Blob A — deep teal, largest, anchor blob
            blob(
                color: Color("LockpawTeal"),
                width: w * 0.5, height: w * 0.4,
                blur: 140,
                opacity: 0.13 + 0.06 * osc(p, freq: 0.2),
                x: w * 0.38 + w * 0.15 * osc(p, freq: 0.4),
                y: h * 0.38 + h * 0.12 * osc(p, freq: 0.6, cos: true),
                scale: 1.0 + 0.18 * osc(p, freq: 0.25, offset: 1.0),
                rotation: 35 * osc(p, freq: 0.15)
            )

            // Blob B — cool teal-blue
            blob(
                color: Color(red: 0, green: 0.53, blue: 0.67),
                width: w * 0.38, height: w * 0.32,
                blur: 120,
                opacity: 0.10 + 0.05 * osc(p, freq: 0.3, offset: 0.5),
                x: w * 0.65 + w * 0.14 * osc(p, freq: 0.7, offset: 2.0),
                y: h * 0.48 + h * 0.14 * osc(p, freq: 0.5, cos: true, offset: 1.5),
                scale: 1.0 + 0.15 * osc(p, freq: 0.35, offset: 2.0),
                rotation: 30 * osc(p, freq: 0.2, offset: 1.0)
            )

            // Blob C — warm amber
            blob(
                color: Color("LockpawAmber"),
                width: w * 0.35, height: w * 0.3,
                blur: 110,
                opacity: 0.08 + 0.05 * osc(p, freq: 0.25, offset: 1.5),
                x: w * 0.55 + w * 0.16 * osc(p, freq: 0.6, offset: 3.0),
                y: h * 0.62 + h * 0.12 * osc(p, freq: 0.9, cos: true, offset: 0.7),
                scale: 1.0 + 0.16 * osc(p, freq: 0.3, offset: 3.0),
                rotation: 40 * osc(p, freq: 0.18, offset: 2.0)
            )

            // Blob D — soft rose, adds depth
            blob(
                color: Color(red: 0.55, green: 0.15, blue: 0.35),
                width: w * 0.3, height: w * 0.25,
                blur: 100,
                opacity: 0.06 + 0.04 * osc(p, freq: 0.35, offset: 2.5),
                x: w * 0.32 + w * 0.15 * osc(p, freq: 1.0, offset: 1.0),
                y: h * 0.55 + h * 0.10 * osc(p, freq: 0.7, cos: true, offset: 3.0),
                scale: 1.0 + 0.14 * osc(p, freq: 0.4, offset: 1.5),
                rotation: 45 * osc(p, freq: 0.25, offset: 3.0)
            )

            // Blob E — pale teal accent, smallest
            blob(
                color: Color(red: 0.2, green: 0.8, blue: 0.65),
                width: w * 0.28, height: w * 0.22,
                blur: 90,
                opacity: 0.07 + 0.04 * osc(p, freq: 0.4, offset: 0.3),
                x: w * 0.5 + w * 0.18 * osc(p, freq: 0.9, offset: 2.5),
                y: h * 0.3 + h * 0.14 * osc(p, freq: 0.4, cos: true, offset: 2.0),
                scale: 1.0 + 0.20 * osc(p, freq: 0.45, offset: 0.5),
                rotation: 50 * osc(p, freq: 0.3, offset: 1.0)
            )
        }
        .allowsHitTesting(false)
    }

    private func blob(color: Color, width: CGFloat, height: CGFloat, blur: CGFloat, opacity: CGFloat, x: CGFloat, y: CGFloat, scale: CGFloat, rotation: CGFloat) -> some View {
        Ellipse()
            .fill(color)
            .opacity(opacity)
            .frame(width: width, height: height)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .position(x: x, y: y)
            .blur(radius: blur)
    }

    private func osc(_ phase: CGFloat, freq: CGFloat, cos useCos: Bool = false, offset: CGFloat = 0) -> CGFloat {
        let angle = (phase + offset) * .pi * 2 * freq
        return useCos ? Foundation.cos(angle) : sin(angle)
    }
}
