import Foundation

/// Optional relay of agent pings off the Mac — to a phone via ntfy or Pushover, or to any
/// webhook (Home Assistant, a smart-light bridge). Off by default; it is the one feature
/// that sends ping data over the network, so what it sends is spelled out here and pinned
/// by tests: agent, what happened, and the project name only if the user opted in. Never
/// a path, session id, transcript or message text.
enum WebhookRelay {
    enum Provider: String, CaseIterable, Identifiable {
        case off, ntfy, pushover, webhook

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .off: return "Off"
            case .ntfy: return "ntfy"
            case .pushover: return "Pushover"
            case .webhook: return "Webhook"
            }
        }
    }

    /// Everything a request needs. Secrets come from the Keychain, never UserDefaults.
    struct Config: Equatable {
        var provider: Provider
        /// ntfy server, default https://ntfy.sh. The topic is the secret on a public server.
        var ntfyServer: String = "https://ntfy.sh"
        var ntfyTopic: String = ""
        var ntfyToken: String = ""
        var pushoverUser: String = ""
        var pushoverToken: String = ""
        var webhookURL: String = ""
        var includeProject: Bool = false
    }

    /// The wire word for a kind, shared by every provider so automations can match on it.
    static func word(for kind: AgentPing.Kind) -> String {
        switch kind {
        case .finished: return "done"
        case .permission, .needsInput: return "waiting"
        case .rateLimited, .failed: return "error"
        case .attention: return "attention"
        }
    }

    enum BuildError: LocalizedError, Equatable {
        case notConfigured(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured(let what): return what
            }
        }
    }

    static func request(for ping: AgentPing, config: Config, now: Date = Date()) throws -> URLRequest {
        let message = ping.summary(includingProject: config.includeProject)
        switch config.provider {
        case .off:
            throw BuildError.notConfigured("Relay is off.")

        case .ntfy:
            let topic = config.ntfyTopic.trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty, topic.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  let server = URL(string: config.ntfyServer.trimmingCharacters(in: .whitespaces)),
                  server.scheme == "https" || server.scheme == "http" else {
                throw BuildError.notConfigured("Set an ntfy server and topic.")
            }
            var request = URLRequest(url: server.appendingPathComponent(topic))
            request.httpMethod = "POST"
            request.httpBody = Data(message.utf8)
            request.setValue("Lockpaw", forHTTPHeaderField: "Title")
            request.setValue(word(for: ping.kind), forHTTPHeaderField: "Tags")
            request.setValue(ping.kind == .finished ? "default" : "high", forHTTPHeaderField: "Priority")
            if !config.ntfyToken.isEmpty {
                request.setValue("Bearer \(config.ntfyToken)", forHTTPHeaderField: "Authorization")
            }
            return request

        case .pushover:
            guard !config.pushoverUser.isEmpty, !config.pushoverToken.isEmpty else {
                throw BuildError.notConfigured("Add your Pushover user key and app token.")
            }
            var request = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let fields = [
                ("token", config.pushoverToken),
                ("user", config.pushoverUser),
                ("title", "Lockpaw"),
                ("message", message),
                ("priority", ping.kind == .finished ? "0" : "1"),
            ]
            request.httpBody = Data(fields.map { "\($0)=\(formEncode($1))" }.joined(separator: "&").utf8)
            return request

        case .webhook:
            guard let url = URL(string: config.webhookURL.trimmingCharacters(in: .whitespaces)),
                  url.scheme == "https" || url.scheme == "http", url.host != nil else {
                throw BuildError.notConfigured("Enter a webhook URL (https://…).")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: String] = [
                "source": "lockpaw",
                "kind": word(for: ping.kind),
                "message": message,
                "timestamp": ISO8601DateFormatter().string(from: now),
            ]
            if let agent = ping.agent { body["agent"] = agent }
            if config.includeProject, let project = ping.project { body["project"] = project }
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return request
        }
    }

    /// application/x-www-form-urlencoded value: everything but unreserved characters is
    /// percent-encoded, so `&`, `=` and `+` in a project name can't split or alter a field.
    static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// A fresh, unguessable ntfy topic. On a public server the topic name is the only thing
    /// standing between your pings and anyone who guesses it.
    static func randomTopic() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return "lockpaw-" + String((0..<20).map { _ in alphabet.randomElement()! })
    }
}

/// Per-session rate limit for the relay: one send per session per window, except that a
/// change of kind (done → waiting) always goes through — that change is the news.
struct RelayThrottle {
    static let window: TimeInterval = 30
    private var last: [String: (kind: String, at: Date)] = [:]

    mutating func allows(_ ping: AgentPing, now: Date = Date()) -> Bool {
        let key = ping.sessionID ?? ping.agent ?? "-"
        let kind = WebhookRelay.word(for: ping.kind)
        if let previous = last[key], previous.kind == kind, now.timeIntervalSince(previous.at) < Self.window {
            return false
        }
        last[key] = (kind, now)
        return true
    }

    mutating func reset() { last.removeAll() }
}
