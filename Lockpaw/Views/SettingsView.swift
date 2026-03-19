import SwiftUI
import ServiceManagement
import Sparkle

struct SettingsView: View {
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = HotkeyConfig.defaultEnabled
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("appearanceMode") private var appearanceMode = 0 // 0=System, 1=Light, 2=Dark
    @AppStorage("hotkeyDisplay") private var hotkeyDisplay = HotkeyConfig.defaultDisplay

    var body: some View {
        Form {
            // Header
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lockpaw")
                            .font(.title3.weight(.semibold))
                        Text("Screen guard for when your computer is working and you're not")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            // Lock Screen
            Section("Lock Screen") {
                Toggle("Show message", isOn: $showMessage)

                if showMessage {
                    LabeledContent("Text") {
                        TextField("", text: $message, axis: .vertical)
                            .lineLimit(1...3)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: message) { _, newValue in
                                if newValue.count > 120 {
                                    message = String(newValue.prefix(120))
                                }
                            }
                    }
                }
            }

            // Shortcuts
            Section("Shortcuts") {
                LabeledContent("Lock / Unlock") {
                    Text(hotkeyDisplay)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.background)
                                .shadow(color: .primary.opacity(0.06), radius: 0.5, y: 0.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        )
                }

                Toggle("Global hotkey enabled", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { _, enabled in
                        NotificationCenter.default.post(
                            name: .lockpawHotkeyPreferenceChanged,
                            object: nil,
                            userInfo: ["enabled": enabled]
                        )
                    }
            }

            // General
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = !enabled }
                    }

                Picker("Appearance", selection: $appearanceMode) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .onChange(of: appearanceMode) { _, mode in
                    applyAppearance(mode)
                }

                Button("Check for Updates\u{2026}") {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.updaterController.checkForUpdates(nil)
                    }
                }
            }

            // Permissions
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if AccessibilityChecker.isEnabled {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color("LockpawTeal"))
                    } else {
                        Button("Grant Access") {
                            AccessibilityChecker.openSystemSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }

            // Lock now
            Section {
                Button {
                    NotificationCenter.default.post(name: .lockpawLock, object: nil)
                } label: {
                    HStack {
                        Label("Lock Screen Now", systemImage: "lock.fill")
                        Spacer()
                        Text(hotkeyDisplay)
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // About
            Section("About") {
                Text("Lockpaw is a visual privacy tool — it prevents accidental input while your screen is guarded. For real security, use your Mac's lock screen (Ctrl+Cmd+Q).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, idealWidth: 480, maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            applyAppearance(appearanceMode)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func applyAppearance(_ mode: Int) {
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // Follow system
        }
    }
}
