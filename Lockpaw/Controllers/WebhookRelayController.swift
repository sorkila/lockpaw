import Foundation
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "WebhookRelay")

/// Sends agent pings off the Mac when the user has set up a relay (see `WebhookRelay`).
/// Only the provider choice and the project opt-in live in UserDefaults; topics, tokens,
/// keys and URLs are secrets (a public ntfy topic or a Home Assistant webhook id *is* the
/// credential), so they live in the Keychain.
@MainActor
final class WebhookRelayController: ObservableObject {
    static let shared = WebhookRelayController()

    static let providerKey = "webhookProvider"
    static let includeProjectKey = "webhookIncludeProject"
    static let keychainService = "com.eriknielsen.lockpaw.relay"

    enum Secret: String, CaseIterable {
        case ntfyServer, ntfyTopic, ntfyToken, pushoverUser, pushoverToken, webhookURL
    }

    @Published private(set) var lastResult: String?

    private var throttle = RelayThrottle()
    /// Ephemeral: no cookies, no cache, no credentials stored. Short timeout and no retry
    /// queue — a ping that can't be delivered in 5s is stale anyway.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.Timing.relayTimeout
        configuration.timeoutIntervalForResource = Constants.Timing.relayTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {}

    var provider: WebhookRelay.Provider {
        WebhookRelay.Provider(rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? "") ?? .off
    }

    var config: WebhookRelay.Config {
        let server = secret(.ntfyServer)
        return WebhookRelay.Config(
            provider: provider,
            ntfyServer: server.isEmpty ? "https://ntfy.sh" : server,
            ntfyTopic: secret(.ntfyTopic),
            ntfyToken: secret(.ntfyToken),
            pushoverUser: secret(.pushoverUser),
            pushoverToken: secret(.pushoverToken),
            webhookURL: secret(.webhookURL),
            includeProject: UserDefaults.standard.bool(forKey: Self.includeProjectKey)
        )
    }

    func secret(_ secret: Secret) -> String { Keychain.read(service: Self.keychainService, account: secret.rawValue) ?? "" }

    func setSecret(_ secret: Secret, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(service: Self.keychainService, account: secret.rawValue)
        } else {
            Keychain.write(service: Self.keychainService, account: secret.rawValue, value: trimmed)
        }
    }

    /// A fresh unguessable topic the first time ntfy is chosen.
    func ensureNtfyTopic() {
        if secret(.ntfyTopic).isEmpty { setSecret(.ntfyTopic, WebhookRelay.randomTopic()) }
    }

    func lockSessionBegan() { throttle.reset() }

    /// Called alongside the notification, so it follows the same rule: only while locked.
    func relay(_ ping: AgentPing) {
        // Checked before `config`, which reads the Keychain, so a relay that's off costs nothing.
        guard provider != .off, throttle.allows(ping) else { return }
        send(ping, reportResult: false)
    }

    func sendTest() {
        let sample = AgentPing(agent: "Claude Code", project: "lockpaw", kind: .finished, sessionID: nil, receivedAt: Date())
        send(sample, reportResult: true)
    }

    private func send(_ ping: AgentPing, reportResult: Bool) {
        let request: URLRequest
        do {
            request = try WebhookRelay.request(for: ping, config: config)
        } catch {
            if reportResult { lastResult = error.localizedDescription }
            return
        }
        if reportResult { lastResult = "Sending\u{2026}" }
        session.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let outcome: String
            if let error {
                outcome = "Failed: \(error.localizedDescription)"
                logger.error("relay failed: \(error.localizedDescription, privacy: .public)")
            } else if let status, (200..<300).contains(status) {
                outcome = "Sent \u{2713}"
            } else {
                outcome = "Failed: HTTP \(status ?? 0)"
                logger.error("relay HTTP \(status ?? 0, privacy: .public)")
            }
            guard reportResult else { return }
            Task { @MainActor in self?.lastResult = outcome }
        }.resume()
    }
}
