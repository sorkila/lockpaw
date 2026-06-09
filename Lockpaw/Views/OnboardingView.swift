import SwiftUI
import Carbon

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var step = 0
    @State private var isRecording = false
    @State private var recordedKeyDisplay = HotkeyConfig.display
    @State private var accessibilityGranted = AccessibilityChecker.isEnabled
    @State private var accessibilityTimer: Timer?
    @State private var hotkeyConflict: String?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Mascot.storageKey) private var selectedMascot = Mascot.defaultValue
    @State private var mascotBreath = false
    @State private var pulse: CGFloat = 0

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: hotkeyStep
                case 2: accessibilityStep
                case 3: agentAlertsStep
                case 4: readyStep
                default: EmptyView()
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 20)),
                removal: .opacity.combined(with: .offset(x: -20))
            ))
            .padding(.horizontal, 40)

            Spacer()

            // Progress + action
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color("LockpawTeal") : .gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                Button {
                    advance()
                } label: {
                    Text(buttonLabel)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(Color("LockpawTeal"))
                .disabled(!canAdvance)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 420, height: 500)
        .onAppear {
            accessibilityGranted = AccessibilityChecker.isEnabled
            if step == 2 && !accessibilityGranted {
                startAccessibilityPolling()
            }
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
        }
    }

    private var canAdvance: Bool {
        if step == 2 && !accessibilityGranted { return false }
        return true
    }

    private var buttonLabel: String {
        switch step {
        case 2 where !accessibilityGranted: return "Waiting for access…"
        case 4: return "Get Started"
        default: return "Continue"
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.3)) {
            if step < totalSteps - 1 {
                step += 1
                if step == 2 { startAccessibilityPolling() }
            } else {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                NotificationCenter.default.post(name: .lockpawHotkeyPreferenceChanged, object: nil)
                hasCompletedOnboarding = true
                // Open Settings immediately — this activates the event pipeline
                // so the global hotkey works without needing to click the menu bar.
                openSettings()
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            mascotHero(size: 96)

            VStack(spacing: 8) {
                Text("Welcome to Lockpaw")
                    .font(.title2.weight(.semibold))

                Text("A screen guard for when your\ncomputer is working and you're not.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Text("Lockpaw is a visual privacy tool, not a security lock. For real security, use your Mac's lock screen (Ctrl+Cmd+Q).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)
        }
    }

    /// The mascot in a breathing pool of light — the app's hero, reused across steps.
    private func mascotHero(size: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Color("LockpawTeal").opacity(0.05))
                .frame(width: size * 0.9, height: size * 0.25)
                .blur(radius: 18)
                .offset(y: size * 0.5)

            Image(Mascot.resolved(from: selectedMascot).assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: Color("LockpawTeal").opacity(0.18), radius: 24, y: 8)
                .scaleEffect(mascotBreath ? 1.03 : 1.0)
                .offset(y: mascotBreath ? -3 : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                mascotBreath = true
            }
        }
    }

    // MARK: - Step 2: Hotkey

    private var hotkeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color("LockpawTeal"))

            VStack(spacing: 8) {
                Text("Set your hotkey")
                    .font(.title2.weight(.semibold))

                Text("Press once to lock, press again to unlock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Recorder
            Button {
                isRecording = true
            } label: {
                Group {
                    if isRecording {
                        Text("Press your shortcut…")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color("LockpawTeal").opacity(0.7))
                    } else {
                        Text(recordedKeyDisplay)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color("LockpawTeal"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color("LockpawTeal").opacity(isRecording ? 0.15 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color("LockpawTeal").opacity(isRecording ? 0.4 : 0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if let conflict = hotkeyConflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(Color("LockpawError"))
            } else {
                Text(isRecording ? "Press any modifier + key" : "Click to change")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { setupKeyRecorder() }
    }

    // MARK: - Step 3: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            ZStack {
                if accessibilityGranted {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color("LockpawTeal"))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("✋")
                        .font(.system(size: 36))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.3), value: accessibilityGranted)

            VStack(spacing: 8) {
                Text(accessibilityGranted ? "Access granted" : "One more thing")
                    .font(.title2.weight(.semibold))
                    .animation(.none, value: accessibilityGranted)

                if accessibilityGranted {
                    Text("Lockpaw can now block keyboard input\nwhile your screen is locked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                } else {
                    Text("Lockpaw needs Accessibility permission to\nblock keyboard input while locked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }

            if !accessibilityGranted {
                VStack(spacing: 10) {
                    Button {
                        AccessibilityChecker.promptIfNeeded()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            AccessibilityChecker.openSystemSettings()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                                .font(.system(size: 12))
                            Text("Open System Settings")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .controlSize(.regular)
                    .buttonStyle(.bordered)
                    .tint(Color("LockpawTeal"))

                    VStack(spacing: 4) {
                        Text("Find Lockpaw in the list and toggle it on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("This window will update automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Step 4: Agent alerts

    private var agentAlertsStep: some View {
        VStack(spacing: 20) {
            // Mini lock-screen preview, pulsing teal — the "it needs you" moment.
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color("LockpawTeal").opacity(0.55 * pulse), .clear],
                        center: .center, startRadius: 0, endRadius: 95))
                    .blendMode(.plusLighter)

                Image(Mascot.resolved(from: selectedMascot).assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 46, height: 46)
            }
            .frame(width: 156, height: 104)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    pulse = 1
                }
            }

            VStack(spacing: 8) {
                Text("Lockpaw taps you")
                    .font(.title2.weight(.semibold))

                Text("Lock your screen and walk away. When Claude Code,\nCodex, or Gemini needs you, the screen glows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Text("Set it up anytime in Settings — works with any CLI agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 5: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            // Menu bar illustration
            VStack(spacing: 0) {
                // Fake menu bar
                HStack(spacing: 12) {
                    Spacer()

                    // Other menu bar icons (generic)
                    Image(systemName: "wifi")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Image(systemName: "battery.75percent")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    // Lockpaw icon — highlighted
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color("LockpawTeal").opacity(0.15))
                            .frame(width: 24, height: 20)

                        Image("MenuBarIcon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 12)
                            .foregroundStyle(Color("LockpawTeal"))
                    }

                    // Clock
                    Text("11:21")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer().frame(width: 8)
                }
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(0.06))
                )
            }
            .frame(width: 220)

            VStack(spacing: 8) {
                Text("Lockpaw lives in your menu bar")
                    .font(.title3.weight(.semibold))

                Text("Look for the dog icon in the top-right\nof your screen. That's your control center.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            // Hotkey reminder
            VStack(spacing: 4) {
                Text("Your hotkey")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(recordedKeyDisplay)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color("LockpawTeal"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color("LockpawTeal").opacity(0.08))
                    )
            }
        }
    }

    // MARK: - Hotkey Recorder

    private func setupKeyRecorder() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }

            var parts: [String] = []
            if event.modifierFlags.contains(.command) { parts.append("Cmd") }
            if event.modifierFlags.contains(.shift) { parts.append("Shift") }
            if event.modifierFlags.contains(.option) { parts.append("Opt") }
            if event.modifierFlags.contains(.control) { parts.append("Ctrl") }

            guard !parts.isEmpty else { return event }

            if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
                parts.append(chars)
            }

            let display = parts.joined(separator: "+")

            // Check for conflicts with common system shortcuts
            if let conflict = HotkeyConfig.systemConflict(keyCode: Int(event.keyCode), modifiers: event.modifierFlags) {
                hotkeyConflict = "\(display) conflicts with \(conflict). Try another."
                return nil
            }

            recordedKeyDisplay = display
            hotkeyConflict = nil
            isRecording = false

            // Persist the hotkey to UserDefaults
            var carbonMods: Int = 0
            if event.modifierFlags.contains(.command) { carbonMods |= cmdKey }
            if event.modifierFlags.contains(.shift) { carbonMods |= shiftKey }
            if event.modifierFlags.contains(.option) { carbonMods |= optionKey }
            if event.modifierFlags.contains(.control) { carbonMods |= controlKey }
            HotkeyConfig.saveKeyCode(Int(event.keyCode))
            HotkeyConfig.saveModifiers(carbonMods)
            HotkeyConfig.saveDisplay(recordedKeyDisplay)
            // Don't post lockpawHotkeyPreferenceChanged here — Accessibility isn't
            // granted yet during onboarding. The completion step posts it instead.

            return nil
        }
    }

    // MARK: - Accessibility Polling

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityGranted = AccessibilityChecker.isEnabled

        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            DispatchQueue.main.async {
                accessibilityGranted = AccessibilityChecker.isEnabled
                if accessibilityGranted {
                    timer.invalidate()
                    accessibilityTimer = nil
                }
            }
        }
        accessibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
