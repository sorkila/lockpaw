import Foundation
import Security
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

    enum Secret: String, CaseIterable {
        case ntfyServer, ntfyTopic, ntfyToken, pushoverUser, pushoverToken, webhookURL
    }

    @Published private(set) var lastResult: String?

    private var throttle = RelayThrottle()
    /// Ephemeral: no cookies, no cache, no credentials stored. Short timeout and no retry
    /// queue — a ping that can't be delivered in 5s is stale anyway.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {}

    var provider: WebhookRelay.Provider {
        WebhookRelay.Provider(rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? "") ?? .off
    }

    var config: WebhookRelay.Config {
        WebhookRelay.Config(
            provider: provider,
            ntfyServer: Keychain.read(.ntfyServer) ?? "https://ntfy.sh",
            ntfyTopic: Keychain.read(.ntfyTopic) ?? "",
            ntfyToken: Keychain.read(.ntfyToken) ?? "",
            pushoverUser: Keychain.read(.pushoverUser) ?? "",
            pushoverToken: Keychain.read(.pushoverToken) ?? "",
            webhookURL: Keychain.read(.webhookURL) ?? "",
            includeProject: UserDefaults.standard.bool(forKey: Self.includeProjectKey)
        )
    }

    func secret(_ secret: Secret) -> String { Keychain.read(secret) ?? "" }

    func setSecret(_ secret: Secret, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(secret) } else { Keychain.write(secret, trimmed) }
    }

    /// A fresh unguessable topic the first time ntfy is chosen.
    func ensureNtfyTopic() {
        if secret(.ntfyTopic).isEmpty { setSecret(.ntfyTopic, WebhookRelay.randomTopic()) }
    }

    func lockSessionBegan() { throttle.reset() }

    /// Called alongside the notification, so it follows the same rule: only while locked.
    func relay(_ ping: AgentPing) {
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

/// Generic-password items under one service, one account per secret.
private enum Keychain {
    static let service = "com.eriknielsen.lockpaw.relay"

    private static func query(_ secret: WebhookRelayController.Secret) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: secret.rawValue]
    }

    static func read(_ secret: WebhookRelayController.Secret) -> String? {
        var query = query(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ secret: WebhookRelayController.Secret, _ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(secret) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(secret)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ secret: WebhookRelayController.Secret) {
        SecItemDelete(query(secret) as CFDictionary)
    }
}
