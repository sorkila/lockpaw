import SwiftUI
import AppKit
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

private let buyMeACoffeeURL = URL(string: "https://www.buymeacoffee.com/eriknielsen")!
private let creatorURL = URL(string: "https://sorkila.com")!
private let settingsAccentColor = Color("LockpawTeal")

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case lockScreen
    case shortcuts
    case general
    case permissions
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .lockScreen: return "Lock Screen"
        case .shortcuts: return "Shortcuts"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .lockScreen: return "lock.display"
        case .shortcuts: return "command"
        case .general: return "gearshape"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .lockScreen: return "Mascot, displays, and lock message"
        case .shortcuts: return "Hotkey and unlock options"
        case .general: return "Startup, appearance, and updates"
        case .permissions: return "System access"
        case .about: return "Version, credits, and security note"
        }
    }
}

struct SettingsView: View {
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = HotkeyConfig.defaultEnabled
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("appearanceMode") private var appearanceMode = 0 // 0=System, 1=Light, 2=Dark
    @AppStorage("multiDisplayMode") private var multiDisplayMode = 0 // 0=Ambient, 1=Mirror
    @AppStorage(Mascot.storageKey) private var selectedMascot = Mascot.defaultValue
    @AppStorage("hotkeyDisplay") private var hotkeyDisplay = HotkeyConfig.defaultDisplay
    @AppStorage(HotkeyConfig.requireAuthenticationToUnlockKey) private var requiresAuthenticationToUnlock = HotkeyConfig.defaultRequireAuthenticationToUnlock
    @AppStorage(Constants.agentPingSoundKey) private var agentPingSound = false

    @ObservedObject var updateCheckViewModel: UpdateCheckViewModel

    @State private var selectedSection: SettingsSection = .lockScreen
    @State private var isRecording = false
    @State private var hotkeyConflict: String?
    @State private var keyMonitor: Any?
    @State private var accessibilityGranted = AccessibilityChecker.isEnabled
    @State private var accessibilityTimer: Timer?
    @State private var copiedItem: String?
    @State private var agentSetupResults: [String: AgentSetupResult] = [:]

    init(viewModel: UpdateCheckViewModel) {
        self.updateCheckViewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selectedSection)

            // Cross-fade between sections (motion echo of the shared ease-out language).
            ZStack {
                selectedSettingsPage
                    .id(selectedSection)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: selectedSection)
        }
        .tint(settingsAccentColor)
        .accentColor(settingsAccentColor)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 720, idealHeight: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                configureSettingsWindow()
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            applyAppearance(appearanceMode)
            startAccessibilityPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityStatus()
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var selectedSettingsPage: some View {
        switch selectedSection {
        case .lockScreen:
            settingsPage(.lockScreen) { lockScreenSettings }
        case .shortcuts:
            settingsPage(.shortcuts) { shortcutSettings }
        case .general:
            settingsPage(.general) { generalSettings }
        case .permissions:
            settingsPage(.permissions) { permissionSettings }
        case .about:
            settingsPage(.about) { aboutSettings }
        }
    }

    private func settingsPage<Content: View>(_ section: SettingsSection, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(for: section)
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: 820, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func detailHeader(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title)
                .font(.system(size: 22, weight: .semibold))
            Text(section.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var lockScreenSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            mascotPreview

            SettingsPanel {
                SettingsRow("Mascot") {
                    SettingsSegmentedControl(
                        selection: $selectedMascot,
                        options: Mascot.allCases.map { ($0.displayName, $0.rawValue) }
                    )
                }

                SettingsDivider()

                SettingsRow("Secondary displays", subtitle: "Choose what appears on additional screens.") {
                    SettingsSegmentedControl(
                        selection: $multiDisplayMode,
                        options: [("Ambient", 0), ("Mirror", 1)],
                        width: 220
                    )
                }

                SettingsDivider()

                SettingsRow("Show lock message", subtitle: "Display a short line beneath the mascot.") {
                    SettingsCheckbox(isOn: $showMessage)
                }

                if showMessage {
                    SettingsDivider()

                    SettingsRow("Message") {
                        TextField("Lock message", text: $message, axis: .vertical)
                            .lineLimit(1...3)
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 420)
                            .onChange(of: message) { _, newValue in
                                if newValue.count > 120 {
                                    message = String(newValue.prefix(120))
                                }
                            }
                    }
                }
            }

            SettingsPanel {
                SettingsRow("Lock now", subtitle: "Start the lock screen immediately.") {
                    Button {
                        NotificationCenter.default.post(name: .lockpawLock, object: nil)
                    } label: {
                        Text("Lock Now")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    private var mascotPreview: some View {
        let mascot = Mascot.resolved(from: selectedMascot)

        return HStack(spacing: 18) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.035, blue: 0.045),
                        Color(red: 0.01, green: 0.012, blue: 0.018)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [Color("LockpawTeal").opacity(0.18), .clear],
                    center: .bottomLeading,
                    startRadius: 4,
                    endRadius: 120
                )

                Image(mascot.assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(18)
            }
            .frame(width: 132, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text("\(mascot.displayName) takeover")
                    .font(.system(size: 15, weight: .semibold))
                Text("Shown on the primary display while Lockpaw is active.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var shortcutSettings: some View {
        SettingsPanel {
            SettingsRow("Lock / Unlock", subtitle: "Use one shortcut to lock or unlock.") {
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Text(isRecording ? "Press shortcut…" : hotkeyDisplay)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(isRecording ? Color("LockpawTeal") : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isRecording ? Color("LockpawTeal").opacity(0.12) : Color(.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isRecording ? Color("LockpawTeal").opacity(0.45) : Color(.separatorColor), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }

            if let conflict = hotkeyConflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(Color("LockpawError"))
            }

            SettingsDivider()

            SettingsRow("Require authentication", subtitle: "Ask for Touch ID or your Mac password before unlocking.") {
                SettingsCheckbox(isOn: $requiresAuthenticationToUnlock)
            }

            SettingsDivider()

            SettingsRow("Global hotkey", subtitle: "Keep the shortcut active while Lockpaw is running.") {
                SettingsCheckbox(isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { _, enabled in
                        NotificationCenter.default.post(
                            name: .lockpawHotkeyPreferenceChanged,
                            object: nil,
                            userInfo: ["enabled": enabled]
                        )
                    }
            }
        }
    }

    // MARK: - Agent setup (one-click; runs the bundled CLI, which backs up configs)

    private enum AgentSetupResult {
        case running
        case success
        case failure(String)
    }

    private var cliURL: URL? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("lockpaw")
    }

    /// Run the bundled `lockpaw` CLI with the given arguments off the main thread,
    /// then record the outcome for the row identified by `mark`. A ⚠️ on stdout with
    /// exit 0 (e.g. Codex already has a foreign `notify`) is surfaced as a failure
    /// so the button doesn't claim success for a write that didn't happen.
    private func runAgentSetup(_ arguments: [String], mark: String, treatWarningAsFailure: Bool = true) {
        if case .running = agentSetupResults[mark] { return }
        guard let cli = cliURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            agentSetupResults[mark] = .failure("The bundled lockpaw tool is missing — reinstall Lockpaw.")
            return
        }
        agentSetupResults[mark] = .running
        let startedAt = Date()
        Task.detached {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let result: AgentSetupResult
            do {
                try process.run()
                process.waitUntilExit()
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    result = .failure(err.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if treatWarningAsFailure, out.contains("⚠️") {
                    result = .failure(out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    result = .success
                }
            } catch {
                result = .failure(error.localizedDescription)
            }
            // The CLI finishes in milliseconds; hold the spinner briefly so the
            // success state registers as an event rather than an instant flicker.
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < Constants.Timing.agentSetupMinSpin {
                try? await Task.sleep(nanoseconds: UInt64((Constants.Timing.agentSetupMinSpin - elapsed) * 1_000_000_000))
            }
            await MainActor.run {
                agentSetupResults[mark] = result
                // install-hook installs the CLI as a side effect — mirror that.
                if mark != "cli", case .success = result {
                    agentSetupResults["cli"] = .success
                }
            }
        }
    }

    private func isSetupRunning(_ mark: String) -> Bool {
        if case .running = agentSetupResults[mark] { return true }
        return false
    }

    @ViewBuilder
    private func setupButtonLabel(mark: String, idle: String, done: String) -> some View {
        switch agentSetupResults[mark] {
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(idle)
            }
            .padding(.horizontal, 4)
        case .success:
            Text(done).padding(.horizontal, 4)
        case .failure:
            Text("\(idle) ⚠︎").padding(.horizontal, 4)
        case nil:
            Text(idle).padding(.horizontal, 4)
        }
    }

    private var agentSetupFailureMessage: String? {
        for tool in ["claude", "codex", "cli"] {
            if case .failure(let message) = agentSetupResults[tool], !message.isEmpty {
                return message
            }
        }
        return nil
    }

    private func agentLabel(_ tool: String) -> String {
        switch tool {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        default: return tool
        }
    }

    private func copyToPasteboard(_ string: String, mark: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copiedItem = mark
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copiedItem == mark { copiedItem = nil }
        }
    }

    private func copyHook(for tool: String) {
        copyToPasteboard(hookSnippet(for: tool), mark: tool)
    }

    /// Source the snippet from the bundled CLI (`install-hook <tool> --print`) so it
    /// never drifts from the tool; fall back to a literal if the CLI can't be run.
    private func hookSnippet(for tool: String) -> String {
        if let cli = cliURL, FileManager.default.isExecutableFile(atPath: cli.path) {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["install-hook", tool, "--print"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            if (try? process.run()) != nil {
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
            }
        }
        switch tool {
        case "codex": return "notify = [\"lockpaw\", \"ping\"]"
        case "gemini": return "Add a hook running `lockpaw ping` in ~/.gemini/settings.json — see https://geminicli.com/docs/hooks/"
        default: return "\"hooks\": {\n  \"Notification\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"lockpaw ping\" }] }],\n  \"Stop\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"lockpaw ping\" }] }]\n}"
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPanel {
                SettingsRow("Launch at login", subtitle: "Open Lockpaw automatically when you sign in.") {
                    SettingsCheckbox(isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = !enabled
                            }
                        }
                }

                SettingsDivider()

                SettingsRow("Appearance") {
                    SettingsSegmentedControl(
                        selection: $appearanceMode,
                        options: [("System", 0), ("Light", 1), ("Dark", 2)],
                        width: 240
                    )
                    .onChange(of: appearanceMode) { _, mode in
                        applyAppearance(mode)
                    }
                }
            }

            SettingsPanel {
                SettingsRow("Play a sound on agent ping", subtitle: "Off by default for shared spaces. The locked screen always glows.") {
                    SettingsCheckbox(isOn: $agentPingSound)
                }

                SettingsDivider()

                SettingsRow("Test agent ping", subtitle: "Send a sample notification to confirm alerts work.") {
                    Button {
                        AgentNotifier.shared.notify(withSound: agentPingSound)
                    } label: {
                        Text("Send")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                }

                SettingsDivider()

                SettingsRow("Connect your agent", subtitle: "One click sets up everything — the command-line tool and the agent's ping hook (a .bak backup is kept). Gemini copies a snippet to paste.") {
                    HStack(spacing: 8) {
                        ForEach(["claude", "codex", "gemini"], id: \.self) { tool in
                            Button {
                                if tool == "gemini" {
                                    copyHook(for: tool)
                                } else {
                                    runAgentSetup(["install-hook", tool], mark: tool)
                                }
                            } label: {
                                if tool == "gemini" {
                                    Text(copiedItem == tool ? "Copied ✓" : agentLabel(tool))
                                        .padding(.horizontal, 4)
                                } else {
                                    setupButtonLabel(mark: tool, idle: agentLabel(tool), done: "\(agentLabel(tool)) ✓")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSetupRunning(tool))
                        }
                    }
                }

                SettingsDivider()

                SettingsRow("Command-line tool", subtitle: "Optional — connecting an agent installs this automatically. Puts lockpaw in ~/.local/bin for your own scripts.") {
                    Button {
                        runAgentSetup(["install-cli"], mark: "cli", treatWarningAsFailure: false)
                    } label: {
                        setupButtonLabel(mark: "cli", idle: "Install", done: "Installed ✓")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSetupRunning("cli"))
                }

                if let failure = agentSetupFailureMessage {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                }
            }

            SettingsPanel {
                SettingsRow("Software updates", subtitle: "Check for signed updates from Lockpaw.") {
                    Button {
                        updateCheckViewModel.checkForUpdates()
                    } label: {
                        if updateCheckViewModel.isChecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking\u{2026}")
                            }
                            .padding(.horizontal, 8)
                        } else {
                            Text("Check Now")
                                .padding(.horizontal, 8)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!updateCheckViewModel.canCheckForUpdates || updateCheckViewModel.isChecking)
                }

                if let status = updateCheckViewModel.updateStatus {
                    SettingsDivider()
                    updateStatusView(status)
                }
            }

        }
    }

    @ViewBuilder
    private func updateStatusView(_ status: UpdateCheckViewModel.UpdateStatus) -> some View {
        switch status {
        case .upToDate:
            Label("You\u{2019}re up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color("LockpawTeal"))
        case .available(let version):
            Label("Version \(version) available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color("LockpawError"))
        }
    }

    private var permissionSettings: some View {
        SettingsPanel {
            SettingsRow(
                "Accessibility",
                subtitle: accessibilityGranted ? "Granted" : "Required to block keyboard input while locked."
            ) {
                HStack(spacing: 10) {
                    Label(
                        accessibilityGranted ? "Granted" : "Required",
                        systemImage: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(accessibilityGranted ? Color("LockpawTeal") : Color("LockpawAmber"))

                    if !accessibilityGranted {
                        Button {
                            AccessibilityChecker.openSystemSettings()
                        } label: {
                            Text("Grant Access")
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPanel {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lockpaw")
                            .font(.system(size: 17, weight: .semibold))
                        Text(appVersionText)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            SettingsPanel {
                SettingsRow("Made by Erik Nielsen") {
                    Link("sorkila.com", destination: creatorURL)
                        .buttonStyle(.link)
                }

                SettingsDivider()

                Text("Lockpaw is a visual privacy tool. It helps prevent accidental input while your screen is guarded. For security, use your Mac's lock screen (Ctrl+Cmd+Q).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

                SettingsRow("Support Lockpaw") {
                    Button {
                        NSWorkspace.shared.open(buyMeACoffeeURL)
                    } label: {
                        Text("Buy Me a Coffee")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)): return "Version \(version) (\(build))"
        case let (.some(version), .none): return "Version \(version)"
        case let (.none, .some(build)): return "Build \(build)"
        default: return "Version unknown"
        }
    }

    private func refreshAccessibilityStatus() {
        accessibilityGranted = AccessibilityChecker.isEnabled
    }

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        refreshAccessibilityStatus()

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshAccessibilityStatus()
            }
        }
        accessibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func configureSettingsWindow() {
        guard let window = NSApp.keyWindow else { return }
        window.title = "Lockpaw Settings"
        window.minSize = NSSize(width: 760, height: 720)

        let targetSize = NSSize(width: 820, height: 740)
        let contentSize = window.contentView?.frame.size ?? .zero
        if contentSize.width < targetSize.width || contentSize.height < targetSize.height {
            window.setContentSize(targetSize)
            window.center()
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

private struct SettingsPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .font(.system(size: 14))
        .controlSize(.regular)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        // The window titlebar already says "Lockpaw Settings" — no in-content title.
        HStack(alignment: .center, spacing: 12) {
            ForEach(SettingsSection.allCases) { section in
                SettingsTabButton(
                    section: section,
                    isSelected: selection == section
                ) {
                    selection = section
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsTabButton: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)

                Text(section.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? settingsAccentColor : .secondary)
            .padding(.horizontal, 8)
            .frame(width: 90, height: 56)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(settingsAccentColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(settingsAccentColor.opacity(0.22), lineWidth: 1)
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
    }
}

private struct SettingsRow<Control: View>: View {
    private let title: String
    private let subtitle: String?
    private let control: Control

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 18)

            control
                .frame(minWidth: 280, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: subtitle == nil ? 32 : 44)
    }
}

private struct SettingsSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    var width: CGFloat = 190

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection

                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? settingsAccentColor : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(settingsAccentColor.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(settingsAccentColor.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(2)
        .frame(width: width)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsCheckbox: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? settingsAccentColor : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isOn ? 0 : 0.14), lineWidth: 1)
                    )

                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .frame(width: 20, height: 20)
            .padding(4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 0)
    }
}
