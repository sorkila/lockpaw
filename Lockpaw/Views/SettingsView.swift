import SwiftUI
import ServiceManagement
import Sparkle
import Carbon

final class UpdateCheckViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var canCheckForUpdates = false
    @Published var isChecking = false
    @Published var updateStatus: UpdateStatus?

    enum UpdateStatus {
        case upToDate
        case available(String)
        case error(String)
    }

    weak var updater: SPUUpdater?
    private var userInitiated = false

    func bind(to updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard let updater else { return }
        NSApp.activate(ignoringOtherApps: true)
        userInitiated = true
        isChecking = true
        updateStatus = nil
        updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard userInitiated else { return }
        userInitiated = false
        isChecking = false
        updateStatus = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard userInitiated else { return }
        userInitiated = false
        isChecking = false
        updateStatus = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard userInitiated else { return }
        userInitiated = false
        isChecking = false
        updateStatus = .error(error.localizedDescription)
    }
}

struct SettingsView: View {
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = HotkeyConfig.defaultEnabled
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("appearanceMode") private var appearanceMode = 0 // 0=System, 1=Light, 2=Dark
    @AppStorage("multiDisplayMode") private var multiDisplayMode = 0 // 0=Ambient, 1=Mirror
    @AppStorage("hotkeyDisplay") private var hotkeyDisplay = HotkeyConfig.defaultDisplay

    @ObservedObject var updateCheckViewModel: UpdateCheckViewModel

    @State private var isRecording = false
    @State private var hotkeyConflict: String?
    @State private var keyMonitor: Any?

    init(viewModel: UpdateCheckViewModel) {
        self.updateCheckViewModel = viewModel
    }

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
                Picker("Multi-display", selection: $multiDisplayMode) {
                    Text("Ambient on secondary").tag(0)
                    Text("Same on all screens").tag(1)
                }

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
                    Button {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    } label: {
                        Text(isRecording ? "Press shortcut…" : hotkeyDisplay)
                            .font(.callout.monospaced())
                            .foregroundStyle(isRecording ? Color("LockpawTeal") : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isRecording ? Color("LockpawTeal").opacity(0.1) : Color(.controlBackgroundColor))
                                    .shadow(color: .primary.opacity(0.06), radius: 0.5, y: 0.5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(isRecording ? Color("LockpawTeal").opacity(0.4) : Color(.separatorColor), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                if let conflict = hotkeyConflict {
                    Text(conflict)
                        .font(.caption)
                        .foregroundStyle(Color("LockpawError"))
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

                Button {
                    updateCheckViewModel.checkForUpdates()
                } label: {
                    if updateCheckViewModel.isChecking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking\u{2026}")
                        }
                    } else {
                        Text("Check for Updates\u{2026}")
                    }
                }
                .disabled(!updateCheckViewModel.canCheckForUpdates || updateCheckViewModel.isChecking)

                if let status = updateCheckViewModel.updateStatus {
                    switch status {
                    case .upToDate:
                        Label("You\u{2019}re up to date", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color("LockpawTeal"))
                    case .available(let version):
                        Label("Version \(version) available", systemImage: "arrow.down.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.blue)
                    case .error(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color("LockpawError"))
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
                            .foregroundStyle(.secondary)
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

    // MARK: - Hotkey Recorder

    private func startRecording() {
        hotkeyConflict = nil
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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

            if let conflict = HotkeyConfig.systemConflict(keyCode: Int(event.keyCode), modifiers: event.modifierFlags) {
                hotkeyConflict = "\(display) conflicts with \(conflict)"
                return nil
            }

            // Save and apply
            var carbonMods: Int = 0
            if event.modifierFlags.contains(.command) { carbonMods |= cmdKey }
            if event.modifierFlags.contains(.shift) { carbonMods |= shiftKey }
            if event.modifierFlags.contains(.option) { carbonMods |= optionKey }
            if event.modifierFlags.contains(.control) { carbonMods |= controlKey }

            HotkeyConfig.saveKeyCode(Int(event.keyCode))
            HotkeyConfig.saveModifiers(carbonMods)
            HotkeyConfig.saveDisplay(display)
            hotkeyDisplay = display
            hotkeyConflict = nil
            stopRecording()

            NotificationCenter.default.post(name: .lockpawHotkeyPreferenceChanged, object: nil)

            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
