import SwiftUI

enum ScreenRole {
    case primary
    case ambient
}

struct LockScreenView: View {
    @ObservedObject var controller: LockController
    var screenRole: ScreenRole = .primary
    var phaseOffset: CGFloat = 0

    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage(Mascot.storageKey) private var selectedMascot = Mascot.defaultValue
    @AppStorage(HotkeyConfig.requireAuthenticationToUnlockKey) private var requiresAuthenticationToUnlock = HotkeyConfig.defaultRequireAuthenticationToUnlock

    @State private var phase: CGFloat = 0
    @State private var appeared = false
    @State private var showingHelp = false
    @State private var hoveringAuth = false
    @State private var shakeOffset: CGFloat = 0
    @State private var successScale: CGFloat = 1.0
    @State private var pingGlow: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var breathe: CGFloat { reduceMotion ? 0 : sin((phase + phaseOffset) * .pi * 2 * 0.2) }
    private var drift: CGFloat { reduceMotion ? 0 : sin((phase + phaseOffset) * .pi * 2 * 0.05) }
    private var mascotAssetName: String { Mascot.resolved(from: selectedMascot).assetName }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let mascotSize = min(geo.size.width * 0.2, geo.size.height * 0.3)
            let unit = mascotSize * 0.12

            ZStack {
                background(geo: geo)

                // Content group — positioned at ~42% from top (slightly below center)
                VStack(spacing: 0) {
                    Spacer().frame(minHeight: 0)
                        .frame(height: geo.size.height * 0.32)

                    // Mascot + message + time as a tight cohesive group
                    VStack(spacing: unit * 1.2) {

                        // Mascot
                        ZStack {
                            if controller.unlockSucceeded {
                                // Success animation: mascot scales up and fades
                                Image(mascotAssetName)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: mascotSize, height: mascotSize)
                                    .scaleEffect(successScale)
                                    .opacity(2.0 - Double(successScale))
                                    .shadow(color: Color("LockpawTeal").opacity(0.3), radius: 50, y: 0)
                            } else {
                                ZStack {
                                    Ellipse()
                                        .fill(Color("LockpawTeal").opacity(0.02 + breathe * 0.02))
                                        .frame(width: mascotSize * 0.45, height: mascotSize * 0.1)
                                        .blur(radius: 12)
                                        .offset(y: mascotSize * 0.45)

                                    Image(mascotAssetName)
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .frame(width: mascotSize, height: mascotSize)
                                        .shadow(color: Color("LockpawTeal").opacity(0.15 + breathe * 0.08), radius: 35 + breathe * 8, y: 10)
                                        .shadow(color: .black.opacity(0.15), radius: 45, y: 30)
                                        .offset(y: breathe * 4)
                                }
                                .opacity(controller.isAuthenticating ? 0.5 : 1)
                            }
                        }
                        .scaleEffect(appeared ? 1 : 0.94)
                        .opacity(appeared ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .animation(Constants.Anim.gentle, value: controller.unlockSucceeded)

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
                                .accessibilityLabel("Locked for \(Constants.formatElapsedTimeAccessible(controller.elapsedTime))")
                        }
                        .opacity(appeared ? 1 : 0)
                        .opacity(controller.isAuthenticating || controller.unlockSucceeded ? 0.15 : 1)
                        .allowsHitTesting(false)
                    }

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
                                Text(requiresAuthenticationToUnlock ? "Authentication required to unlock" : "Use your hotkey to unlock, or")
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .tracking(0.3)

                                Button {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                    controller.requestUnlock()
                                } label: {
                                    Text(requiresAuthenticationToUnlock ? "Authenticate to Unlock" : "Authenticate with Touch ID")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white.opacity(hoveringAuth ? 0.6 : 0.4))
                                        .tracking(0.3)
                                        .frame(minHeight: 44)
                                        .padding(.horizontal, 20)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(.ultraThinMaterial.opacity(hoveringAuth ? 0.5 : 0.3))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(.white.opacity(hoveringAuth ? 0.08 : 0.04), lineWidth: 0.5)
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
                            VStack(spacing: 8) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 14, weight: .thin))
                                    .foregroundStyle(.white.opacity(0.25 + breathe * 0.1))
                                    .offset(y: breathe * -2)

                                Text("Tap for help")
                                    .font(.system(size: 11, weight: .light))
                                    .foregroundStyle(.white.opacity(0.2))
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
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(reduceMotion ? .none : .timingCurve(0.16, 1, 0.3, 1, duration: 0.6)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(Constants.Anim.breathe) { phase = Constants.Anim.breathePhaseTarget }
            if screenRole == .primary {
                DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.autoShowHelpDelay) {
                    if !showingHelp && !controller.isAuthenticating {
                        withAnimation(Constants.Anim.gentle) { showingHelp = true }
                    }
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
            if succeeded {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                withAnimation(.easeOut(duration: 0.35)) { successScale = 1.15 }
            }
        }
        .onChange(of: controller.pingPulse) { _, _ in
            triggerPingGlow()
        }
    }

    /// One-shot attention glow: ramp up fast, hold at peak, then ease away.
    /// Only the primary screen glows (secondary displays show the ambient view).
    private func triggerPingGlow() {
        guard screenRole == .primary else { return }
        let rise = reduceMotion ? Constants.Anim.standard : Constants.Anim.pingGlowIn
        let fall = reduceMotion ? Constants.Anim.gentle : Constants.Anim.pingGlowOut
        withAnimation(rise) { pingGlow = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Constants.Timing.pingGlowHoldNs) / 1_000_000_000) {
            withAnimation(fall) { pingGlow = 0 }
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

            // Attention glow — fires on an agent ping. Bright and full-screen so it
            // reads from across a room while the screen stays covered.
            if pingGlow > 0 {
                RadialGradient(
                    colors: [Color("LockpawTeal").opacity(0.28 * pingGlow), .clear],
                    center: .center, startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.8
                )
                .ignoresSafeArea()
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
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
