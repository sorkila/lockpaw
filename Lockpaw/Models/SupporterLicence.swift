import Foundation

/// The pay-what-you-want supporter licence, sold through Polar. It unlocks thank-yous only —
/// the supporter mascots, seasonal skins, a badge, and silence from the yearly ask. Nothing
/// that works today is gated, ever.
///
/// Protection is honour-level by design: the key is checked once, when the user enters it,
/// against Polar's public validate endpoint, then remembered. No background re-checks, no
/// phoning home — the "no network except the update check" promise only gains the one call
/// the user starts by pasting a key.
enum SupporterLicence {
    static let keychainService = "com.eriknielsen.lockpaw.supporter"
    static let keychainAccount = "licence"

    /// Polar organization that sells the licence. Set once the Polar storefront exists;
    /// while empty, entering a key reports that the store isn't open yet.
    static let polarOrganizationID = ""
    static let validateURL = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/validate")!
    /// Where "Support Lockpaw" goes: a page on the site that links the Polar checkout, so
    /// the store can move without an app update.
    static let supportPageURL = URL(string: "https://getlockpaw.com/support")!

    enum Outcome: Equatable {
        case valid
        case rejected(String)
        case unavailable(String)
    }

    static func validationRequest(key: String, organizationID: String) throws -> URLRequest {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organizationID.isEmpty else { throw SupporterError("The supporter store isn't open yet.") }
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw SupporterError("Paste the licence key from your receipt.") }
        var request = URLRequest(url: validateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["key": trimmed, "organization_id": organizationID])
        return request
    }

    /// Polar answers 200 with the key's status for a known key, 404 for an unknown one.
    static func outcome(status: Int?, body: Data?) -> Outcome {
        guard let status else { return .unavailable("Couldn't reach Polar. Check your connection and try again.") }
        switch status {
        case 200:
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            switch json?["status"] as? String {
            case "granted": return .valid
            case "revoked": return .rejected("This licence was revoked.")
            case "disabled": return .rejected("This licence is disabled.")
            default: return .rejected("Polar didn't recognise this licence.")
            }
        case 404, 422:
            return .rejected("That key wasn't found. Check it against your receipt.")
        default:
            return .unavailable("Polar returned an error (\(status)). Try again later.")
        }
    }
}

struct SupporterError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Supporter state, read app-wide. Cached in memory and in UserDefaults so view bodies (the
/// lock screen re-renders on every breath frame) never touch the Keychain.
@MainActor
final class Supporter: ObservableObject {
    static let shared = Supporter()
    private static let cacheKey = "isSupporter"

    @Published private(set) var isSupporter: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?

    private init() {
        isSupporter = UserDefaults.standard.bool(forKey: Self.cacheKey)
            && Keychain.read(service: SupporterLicence.keychainService, account: SupporterLicence.keychainAccount) != nil
    }

    func enter(key: String) {
        let request: URLRequest
        do {
            request = try SupporterLicence.validationRequest(key: key, organizationID: SupporterLicence.polarOrganizationID)
        } catch {
            message = error.localizedDescription
            return
        }
        isChecking = true
        message = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.Timing.licenceCheckTimeout
        URLSession(configuration: configuration).dataTask(with: request) { [weak self] data, response, _ in
            let outcome = SupporterLicence.outcome(status: (response as? HTTPURLResponse)?.statusCode, body: data)
            Task { @MainActor in self?.finish(outcome, key: key) }
        }.resume()
    }

    private func finish(_ outcome: SupporterLicence.Outcome, key: String) {
        isChecking = false
        switch outcome {
        case .valid:
            Keychain.write(service: SupporterLicence.keychainService, account: SupporterLicence.keychainAccount,
                           value: key.trimmingCharacters(in: .whitespacesAndNewlines))
            UserDefaults.standard.set(true, forKey: Self.cacheKey)
            isSupporter = true
            message = "Thank you for supporting Lockpaw."
        case .rejected(let text), .unavailable(let text):
            message = text
        }
    }

    func removeLicence() {
        Keychain.delete(service: SupporterLicence.keychainService, account: SupporterLicence.keychainAccount)
        UserDefaults.standard.set(false, forKey: Self.cacheKey)
        isSupporter = false
        message = nil
    }
}
