import SwiftUI
import Carbon

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var step = 0
    @State private var isRecording = false
    @State private var recordedKeyDisplay = UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? "Cmd+Shift+L"
    @State private var accessibilityGranted = AccessibilityChecker.isEnabled
    @State private var accessibilityTimer: Timer?

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: hotkeyStep
                case 2: accessibilityStep
                case 3: readyStep
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
                            .fill(i == step ? Color("BevakaTeal") : .gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                Button {
                    advance()
                } label: {
                    Text(buttonLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(canAdvance
                                      ? Color("BevakaTeal")
                                      : Color.gray.opacity(0.3))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAdvance)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 420, height: 500)
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
        case 3: return "Get Started"
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
                hasCompletedOnboarding = true
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)

            VStack(spacing: 8) {
                Text("Welcome to Bevaka")
                    .font(.title2.weight(.semibold))

                Text("A screen guard for when your\ncomputer is working and you're not.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
    }

    // MARK: - Step 2: Hotkey

    private var hotkeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color("BevakaTeal"))

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
                            .foregroundStyle(Color("BevakaTeal").opacity(0.7))
                    } else {
                        Text(recordedKeyDisplay)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color("BevakaTeal"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color("BevakaTeal").opacity(isRecording ? 0.15 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color("BevakaTeal").opacity(isRecording ? 0.4 : 0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Text(isRecording ? "Press any modifier + key" : "Click to change")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
                        .foregroundStyle(Color("BevakaTeal"))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.3), value: accessibilityGranted)

            VStack(spacing: 8) {
                Text(accessibilityGranted ? "Access granted" : "One more thing")
                    .font(.title2.weight(.semibold))
                    .animation(.none, value: accessibilityGranted)

                if accessibilityGranted {
                    Text("Bevaka can now block keyboard input\nwhile your screen is locked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                } else {
                    Text("Bevaka needs Accessibility permission to\nblock keyboard input while locked.")
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
                        .foregroundStyle(Color("BevakaTeal"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color("BevakaTeal").opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        Text("Find Bevaka in the list and toggle it on.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("This window will update automatically.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Step 4: Ready

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
                        .foregroundStyle(.white.opacity(0.4))
                    Image(systemName: "battery.75percent")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))

                    // Bevaka icon — highlighted
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color("BevakaTeal").opacity(0.15))
                            .frame(width: 24, height: 20)

                        Image(systemName: "lock.open")
                            .font(.system(size: 11))
                            .foregroundStyle(Color("BevakaTeal"))
                    }

                    // Clock
                    Text("11:21")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))

                    Spacer().frame(width: 8)
                }
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
            }
            .frame(width: 220)

            VStack(spacing: 8) {
                Text("Bevaka lives in your menu bar")
                    .font(.title3.weight(.semibold))

                Text("Look for the lock icon in the top-right\nof your screen. That's your control center.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            // Hotkey reminder
            VStack(spacing: 4) {
                Text("Your hotkey")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(recordedKeyDisplay)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color("BevakaTeal"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color("BevakaTeal").opacity(0.08))
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

            recordedKeyDisplay = parts.joined(separator: "+")
            isRecording = false

            // Persist the hotkey to UserDefaults
            var carbonMods: Int = 0
            if event.modifierFlags.contains(.command) { carbonMods |= cmdKey }
            if event.modifierFlags.contains(.shift) { carbonMods |= shiftKey }
            if event.modifierFlags.contains(.option) { carbonMods |= optionKey }
            if event.modifierFlags.contains(.control) { carbonMods |= controlKey }
            UserDefaults.standard.set(Int(event.keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(carbonMods, forKey: "hotkeyModifiers")
            UserDefaults.standard.set(recordedKeyDisplay, forKey: "hotkeyDisplay")

            return nil
        }
    }

    // MARK: - Accessibility Polling

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                accessibilityGranted = AccessibilityChecker.isEnabled
            }
        }
    }
}
