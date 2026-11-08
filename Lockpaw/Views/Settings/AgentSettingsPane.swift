import SwiftUI

/// Agents: connect them first (with which ones already are), then how a ping looks and
/// sounds, then the optional relay to a phone or webhook.
struct AgentSettingsPane: View {
    @AppStorage(GlowIntensity.storageKey) private var glowIntensity = GlowIntensity.defaultValue.rawValue
    @AppStorage(Constants.agentPingSoundKey) private var pingSound = false
    @AppStorage(Constants.lockScreenShowsProjectsKey) private var showsProjects = false

    @State private var statuses: [String: AgentConnection.Status] = [:]
    @State private var presenceConfigured = false
    @State private var presenceCopied = false
    @State private var results: [String: SetupResult] = [:]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(AgentConnection.agents, id: \.self) { agent in
                        AgentButton(
                            name: AgentConnection.displayName(agent),
                            state: buttonState(agent)
                        ) {
                            run(["install-hook", agent], mark: agent)
                        }
                    }
                }
                .padding(.vertical, 4)

                if let failure = failureMessage {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(Color("LockpawAmber"))
                        .textSelection(.enabled)
                } else if let note = attentionMessage {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(Color("LockpawAmber"))
                }
            } header: {
                Text("Connect an agent")
            } footer: {
                Text("One click adds Lockpaw's ping to the agent's settings and keeps a backup. Codex asks you to trust new hooks once: run /hooks in Codex.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button(presenceCopied ? "Copied" : "Copy Setup", action: copyPresenceSetup)
                        Button {
                            run(["install-hook", "claude", "--presence"], mark: Self.presenceMark)
                        } label: {
                            switch results[Self.presenceMark] {
                            case .running: ProgressView().controlSize(.small)
                            default:
                                if presenceIsSetUp {
                                    Label("Set Up", systemImage: "checkmark.circle.fill")
                                } else {
                                    Text("Set Up")
                                }
                            }
                        }
                        .disabled(results[Self.presenceMark] == .running)
                        .help(presenceIsSetUp ? "Set up in Claude Code. Click to write it again." : "Adds the env line and the Claude Code hook to ~/.claude/settings.json.")
                    }
                } label: {
                    SettingLabel(
                        "Claude phone pushes only while away",
                        detail: presenceIsSetUp
                            ? "On. Claude Code skips Remote Control pushes while this Mac is unlocked. Lock or step away and they come to your phone."
                            : "With Remote Control, Claude Code can skip phone pushes while you're at this Mac. Lockpaw tells it when you lock or step away."
                    )
                }
            }

            Section("When an agent pings") {
                Picker("Glow", selection: $glowIntensity) {
                    ForEach(GlowIntensity.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $pingSound) {
                    SettingLabel("Play a sound", detail: "Off by default, for shared spaces.")
                }

                Toggle(isOn: $showsProjects) {
                    SettingLabel("Show project names on the lock screen", detail: "\u{201C}Claude Code \u{00B7} web-app\u{201D} instead of \u{201C}Claude Code\u{201D}.")
                }

                LabeledContent("Try it") {
                    Button("Send a Test Ping") {
                        AgentNotifier.shared.notify(body: "Claude Code finished in lockpaw.", withSound: pingSound)
                    }
                }
            }

            RelaySection()

            Section {
                LabeledContent {
                    Button {
                        run(["install-cli"], mark: "cli", treatWarningAsFailure: false)
                    } label: {
                        switch results["cli"] {
                        case .running: ProgressView().controlSize(.small)
                        case .success: Text("Installed")
                        default: Text("Install")
                        }
                    }
                    .disabled(results["cli"] == .running || results["cli"] == .success)
                } label: {
                    SettingLabel("Command-line tool", detail: "Optional. Puts lockpaw in ~/.local/bin for your own scripts. Connecting an agent installs it too.")
                }
            }
        }
        .settingsPane(.agents)
        .onAppear(perform: refreshConnections)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshConnections()
        }
    }

    // MARK: - Setup (runs the bundled CLI, which backs up configs)

    enum SetupResult: Equatable {
        case running
        case success
        case failure(String)
    }

    private func buttonState(_ agent: String) -> AgentButton.State {
        switch results[agent] {
        case .running: return .running
        case .failure: return .failed
        case .success: return .connected
        case nil:
            switch statuses[agent] ?? .notConnected {
            case .connected: return .connected
            case .notifyUsedByAnotherTool: return .attention
            case .notConnected: return .idle
            }
        }
    }

    /// Codex runs one notify command. When another tool's is set, Codex never calls
    /// Lockpaw, so the button must not read as connected.
    private var attentionMessage: String? {
        guard results["codex"] == nil, statuses["codex"] == .notifyUsedByAnotherTool else { return nil }
        return "Codex: notify is used by another tool. Click Codex to keep it and run Lockpaw first."
    }

    private var failureMessage: String? {
        for mark in AgentConnection.agents + [Self.presenceMark, "cli"] {
            if case .failure(let message) = results[mark], !message.isEmpty { return message }
        }
        return nil
    }

    private func refreshConnections() {
        Task {
            statuses = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: AgentConnection.agents.map { ($0, AgentConnection.status($0)) })
            }.value
            presenceConfigured = await Task.detached(priority: .utility) {
                guard let url = AgentConnection.configURL(for: "claude"),
                      let data = try? Data(contentsOf: url) else { return false }
                return ClaudePresence.isConfigured(settingsData: data)
            }.value
        }
    }

    // MARK: - Claude presence marker

    private static let presenceMark = "presence"

    private var presenceIsSetUp: Bool {
        results[Self.presenceMark] == .success || (results[Self.presenceMark] == nil && presenceConfigured)
    }

    /// The env line for settings.json, for anyone who keeps that file by hand.
    private func copyPresenceSetup() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ClaudePresence.settingsSnippet(path: ClaudePresence.markerURL.path), forType: .string)
        presenceCopied = true
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Constants.Timing.copiedConfirmation * 1_000_000_000))
            presenceCopied = false
        }
    }

    /// Runs the bundled `lockpaw` CLI off the main thread. A ⚠️ on stdout with exit 0 (a
    /// Codex `notify` it can't safely edit) counts as a failure, so the button never
    /// claims a write that didn't happen.
    private func run(_ arguments: [String], mark: String, treatWarningAsFailure: Bool = true) {
        if results[mark] == .running { return }
        guard let cli = Bundle.main.sharedSupportURL?.appendingPathComponent("lockpaw"),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            results[mark] = .failure("The bundled lockpaw tool is missing. Reinstall Lockpaw.")
            return
        }
        results[mark] = .running
        let startedAt = Date()
        Task.detached {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let result: SetupResult
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
            // The CLI finishes in milliseconds; hold the spinner briefly so success reads
            // as an event rather than a flicker.
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < Constants.Timing.agentSetupMinSpin {
                try? await Task.sleep(nanoseconds: UInt64((Constants.Timing.agentSetupMinSpin - elapsed) * 1_000_000_000))
            }
            await MainActor.run {
                results[mark] = result
                // install-hook installs the CLI as a side effect; mirror that.
                if mark != "cli", result == .success { results["cli"] = .success }
                // The presence setup writes the Claude hook too.
                if mark == Self.presenceMark, result == .success { results["claude"] = .success }
            }
        }
    }
}

/// One agent: its name, and a check once Lockpaw's hook is in its settings. Clicking a
/// connected agent runs the installer again, which upgrades the hook in place.
private struct AgentButton: View {
    enum State { case idle, running, connected, attention, failed }

    let name: String
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                switch state {
                case .idle:
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                case .running:
                    ProgressView().controlSize(.small)
                case .connected:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(settingsAccentColor)
                case .attention:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color("LockpawAmber"))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color("LockpawAmber"))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .disabled(state == .running)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityValue)
        .help(helpText)
    }

    private var helpText: String {
        switch state {
        case .connected: return "Connected. Click to update the hook."
        case .attention: return "Notify is used by another tool. Click to keep it and run Lockpaw first."
        default: return "Connect \(name)"
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .idle: return "Not connected"
        case .running: return "Connecting"
        case .connected: return "Connected"
        case .attention: return "Notify is used by another tool"
        case .failed: return "Couldn't connect"
        }
    }
}

/// "Send pings to your phone": off by default, the one feature that sends ping data over
/// the network. Secrets go to the Keychain, never UserDefaults: on Return, on Send Test,
/// when switching provider, and when the pane closes.
private struct RelaySection: View {
    @AppStorage(WebhookRelayController.providerKey) private var provider = WebhookRelay.Provider.off.rawValue
    @AppStorage(WebhookRelayController.includeProjectKey) private var includeProject = false
    @ObservedObject private var relay = WebhookRelayController.shared

    @State private var ntfyServer = ""
    @State private var ntfyTopic = ""
    @State private var ntfyToken = ""
    @State private var pushoverUser = ""
    @State private var pushoverToken = ""
    @State private var webhookURL = ""

    private var selected: WebhookRelay.Provider { WebhookRelay.Provider(rawValue: provider) ?? .off }

    var body: some View {
        Section {
            Picker(selection: $provider) {
                ForEach(WebhookRelay.Provider.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            } label: {
                SettingLabel("Send to", detail: selected == .off ? "Get pings on your phone, or in Home Assistant, while you're away." : nil)
            }
            .pickerStyle(.menu)
            .onChange(of: provider) { _, newValue in
                commitAll()
                if newValue == WebhookRelay.Provider.ntfy.rawValue {
                    relay.ensureNtfyTopic()
                    load()
                }
            }

            switch selected {
            case .off:
                EmptyView()
            case .ntfy:
                field("Server", text: $ntfyServer, secret: .ntfyServer, prompt: "https://ntfy.sh")
                field("Topic", detail: "Subscribe to this in the ntfy app. On a public server, the topic is the password.", text: $ntfyTopic, secret: .ntfyTopic, prompt: "lockpaw-\u{2026}")
                field("Access token", detail: "Only if your server needs one.", text: $ntfyToken, secret: .ntfyToken, prompt: "Optional", isSecure: true)
            case .pushover:
                field("User key", text: $pushoverUser, secret: .pushoverUser, prompt: "u\u{2026}", isSecure: true)
                field("App token", detail: "Create an application at pushover.net to get one.", text: $pushoverToken, secret: .pushoverToken, prompt: "a\u{2026}", isSecure: true)
            case .webhook:
                field("URL", detail: "Gets a JSON POST with the agent, what happened and when.", text: $webhookURL, secret: .webhookURL, prompt: "https://\u{2026}", isSecure: true)
            }

            if selected != .off {
                Toggle(isOn: $includeProject) {
                    SettingLabel("Include the project name", detail: "\u{201C}Claude Code finished in web-app\u{201D} instead of \u{201C}Claude Code finished\u{201D}.")
                }
                LabeledContent {
                    Button("Send Test") {
                        commitAll()
                        relay.sendTest()
                    }
                } label: {
                    SettingLabel("Test", detail: relay.lastResult)
                }
            }
        } header: {
            Text("Send pings off this Mac")
        } footer: {
            if selected != .off {
                Text("Only the agent and what happened are sent, never paths or what the agent wrote.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: commitAll)
    }

    private func field(
        _ title: String, detail: String? = nil, text: Binding<String>,
        secret: WebhookRelayController.Secret, prompt: String, isSecure: Bool = false
    ) -> some View {
        LabeledContent {
            Group {
                if isSecure {
                    SecureField(title, text: text, prompt: Text(prompt))
                } else {
                    TextField(title, text: text, prompt: Text(prompt))
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 260)
            .onSubmit { relay.setSecret(secret, text.wrappedValue) }
        } label: {
            SettingLabel(title, detail: detail)
        }
    }

    private func load() {
        // Empty means ntfy.sh (the placeholder says so), so the default is never stored.
        ntfyServer = relay.secret(.ntfyServer)
        ntfyTopic = relay.secret(.ntfyTopic)
        ntfyToken = relay.secret(.ntfyToken)
        pushoverUser = relay.secret(.pushoverUser)
        pushoverToken = relay.secret(.pushoverToken)
        webhookURL = relay.secret(.webhookURL)
    }

    private func commitAll() {
        relay.setSecret(.ntfyServer, ntfyServer)
        relay.setSecret(.ntfyTopic, ntfyTopic)
        relay.setSecret(.ntfyToken, ntfyToken)
        relay.setSecret(.pushoverUser, pushoverUser)
        relay.setSecret(.pushoverToken, pushoverToken)
        relay.setSecret(.webhookURL, webhookURL)
    }
}
