import SwiftUI

struct LockScreenView: View {
    @ObservedObject var controller: LockController

    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage

    @State private var phase: CGFloat = 0
    @State private var appeared = false
    @State private var showingHelp = false
    @State private var hoveringAuth = false
    @State private var shakeOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var breathe: CGFloat { reduceMotion ? 0 : sin(phase * .pi * 2 * 0.2) }
    private var drift: CGFloat { reduceMotion ? 0 : sin(phase * .pi * 2 * 0.05) }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let dogSize = min(geo.size.width * 0.2, geo.size.height * 0.3)
            let unit = dogSize * 0.12

            ZStack {
                background(geo: geo)

                if !reduceMotion {
                    Circle()
                        .strokeBorder(Color("LockpawTeal").opacity(appeared ? 0 : 0.15), lineWidth: 1)
                        .frame(width: 60, height: 60)
                        .scaleEffect(appeared ? 2.5 : 0.95)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    Spacer()

                    // Dog
                    ZStack {
                        if controller.unlockSucceeded {
                            EmptyView()
                        } else {
                            ZStack {
                                Ellipse()
                                    .fill(Color("LockpawTeal").opacity(0.02 + breathe * 0.02))
                                    .frame(width: dogSize * 0.45, height: dogSize * 0.1)
                                    .blur(radius: 12)
                                    .offset(y: dogSize * 0.45)

                                Image("Mascot")
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: dogSize, height: dogSize)
                                    .shadow(color: Color("LockpawTeal").opacity(0.15 + breathe * 0.08), radius: 35 + breathe * 8, y: 10)
                                    .shadow(color: .black.opacity(0.15), radius: 45, y: 30)
                                    .offset(y: breathe * 4)
                            }
                            .opacity(controller.isAuthenticating ? 0.5 : 1)
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .animation(Constants.Anim.gentle, value: controller.unlockSucceeded)

                    Spacer().frame(height: unit * 2.5)

                    // Message
                    Group {
                        if controller.unlockSucceeded {
                            EmptyView()
                        } else if controller.isAuthenticating {
                            Text("Authenticating\u{2026}")
                                .font(.system(size: compact ? 14 : 16, weight: .regular))
                                .foregroundStyle(.white.opacity(0.55))
                        } else if let error = controller.lastError {
                            Text(error)
                                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                                .foregroundStyle(Color("LockpawError"))
                                .shadow(color: Color("LockpawError").opacity(0.15), radius: 8)
                        } else if showMessage {
                            Text(message)
                                .font(.system(size: compact ? 14 : 16, weight: .regular))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .tracking(0.35)
                    .padding(.horizontal, max(64, geo.size.width * 0.2))
                    .opacity(appeared ? 1 : 0)
                    .animation(Constants.Anim.gentle, value: controller.isAuthenticating)
                    .animation(Constants.Anim.gentle, value: controller.unlockSucceeded)
                    .animation(Constants.Anim.standard, value: controller.lastError)
                    .allowsHitTesting(false)

                    // Time
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Constants.formatElapsedTime(controller.elapsedTime))
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                            .tracking(0.5)
                            .padding(.top, unit)
                            .accessibilityLabel("Locked for \(Constants.formatElapsedTimeAccessible(controller.elapsedTime))")
                    }
                    .opacity(appeared ? 1 : 0)
                    .opacity(controller.isAuthenticating || controller.unlockSucceeded ? 0.15 : 1)
                    .allowsHitTesting(false)

                    Spacer()

                    // Bottom area
                    ZStack {
                        if controller.unlockSucceeded {
                            EmptyView()
                        } else if controller.isAuthenticating {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(1.2)
                                    .tint(Color("LockpawTeal"))
                                VStack(spacing: 4) {
                                    Text("Use Touch ID or enter your Mac password")
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.55))
                                    Text("Check for a system dialog")
                                        .font(.system(size: 11, weight: .light))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                            .transition(.opacity)
                        } else if showingHelp {
                            VStack(spacing: 16) {
                                Text("Use your hotkey to unlock, or")
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .tracking(0.3)

                                Button {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                    controller.requestUnlock()
                                } label: {
                                    Text("Authenticate with Touch ID")
                                        .font(.system(size: 13, weight: .light))
                                        .foregroundStyle(.white.opacity(hoveringAuth ? 0.45 : 0.3))
                                        .tracking(0.5)
                                        .frame(minHeight: 44)
                                        .padding(.horizontal, 16)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(.white.opacity(hoveringAuth ? 0.03 : 0.01))
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { hoveringAuth = $0 }
                                .accessibilityLabel("Authenticate with Touch ID or Mac password")
                            }
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)),
                                removal: .opacity
                            ))
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 12, weight: .ultraLight))
                                    .foregroundStyle(.white.opacity(0.2 + breathe * 0.1))
                                    .offset(y: breathe * -2)

                                Text("Tap for help")
                                    .font(.system(size: 10, weight: .light))
                                    .foregroundStyle(.white.opacity(0.12))
                                    .tracking(0.5)
                            }
                            .transition(.opacity)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 120)
                    .padding(.bottom, compact ? 16 : 40)
                    .animation(Constants.Anim.gentle, value: controller.isAuthenticating)
                    .animation(Constants.Anim.gentle, value: controller.unlockSucceeded)
                    .animation(Constants.Anim.spring, value: showingHelp)
                    .offset(x: shakeOffset)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !showingHelp && !controller.isAuthenticating {
                    withAnimation(Constants.Anim.spring) { showingHelp = true }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .environment(\.colorScheme, .dark) // Lock screen is always dark
        .onAppear {
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.5)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(Constants.Anim.breathe) { phase = 1 }
            // Auto-show help after inactivity
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.autoShowHelpDelay) {
                if !showingHelp && !controller.isAuthenticating {
                    withAnimation(Constants.Anim.gentle) { showingHelp = true }
                }
            }
        }
        .onChange(of: controller.lastError) { _, error in
            guard error != nil else { return }
            withAnimation(.easeInOut(duration: 0.12).repeatCount(4, autoreverses: true)) { shakeOffset = 6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.12)) { shakeOffset = 0 }
            }
        }
        .onChange(of: controller.unlockSucceeded) { _, succeeded in
            if succeeded { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        }
    }

    // MARK: - Background

    private func background(geo: GeometryProxy) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.01, green: 0.005, blue: 0.025), .black, Color(red: 0.01, green: 0.005, blue: 0.02)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            RadialGradient(
                colors: [Color("LockpawTeal").opacity(0.015 + breathe * 0.005), .clear],
                center: .bottom, startRadius: 0, endRadius: 500
            ).ignoresSafeArea().allowsHitTesting(false)

            if !reduceMotion { colorPools(geo: geo) }
        }
    }

    private func colorPools(geo: GeometryProxy) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color("LockpawTeal").opacity(0.04 + breathe * 0.04), .clear], center: .center, startRadius: 0, endRadius: 300 + breathe * 40))
                .frame(width: 600, height: 600)
                .position(x: geo.size.width * 0.35 + drift * 10, y: geo.size.height * 0.3 + breathe * 8)
                .blur(radius: 80)

            Circle()
                .fill(RadialGradient(colors: [Color("LockpawAmber").opacity(0.02 + drift * 0.025), .clear], center: .center, startRadius: 0, endRadius: 250 + drift * 30))
                .frame(width: 500, height: 500)
                .position(x: geo.size.width * 0.65 - drift * 8, y: geo.size.height * 0.65 - breathe * 6)
                .blur(radius: 60)
        }
        .opacity(appeared ? 1 : 0)
        .allowsHitTesting(false)
    }
}

private struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
