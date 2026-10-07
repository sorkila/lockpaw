import Foundation
import Security

/// XPC interface of LockpawHelper, the root LaunchDaemon behind lid-closed mode.
/// Compiled into both the app and the helper — keep this file Foundation + Security only.
///
/// Single-purpose by design: a privileged helper inside a screen guard is a trust cost,
/// so it exposes exactly one lever (sleep on/off) and a read of its state.
@objc protocol SleepHelperProtocol {
    /// Block (true) or allow (false) system sleep, lid-closed sleep included. Idempotent.
    /// Replies with the resulting state and, on failure, an error message.
    func setSleepBlocked(_ blocked: Bool, reply: @escaping (Bool, String?) -> Void)

    /// Current state plus the helper's build, so the app can spot a stale helper.
    func status(reply: @escaping (Bool, String) -> Void)
}

enum SleepHelper {
    /// launchd label and Mach service name — one name for both.
    static let label = "com.eriknielsen.lockpaw.helper"
    /// File name of the LaunchDaemon plist in Contents/Library/LaunchDaemons.
    static let plistName = "\(label).plist"
    /// Code-signing identifier the helper is signed with (release script + project.yml).
    static let helperIdentifier = label
    /// The app identifiers allowed to drive the helper (release and debug builds).
    static let appIdentifiers = ["com.eriknielsen.lockpaw", "com.eriknielsen.lockpaw.debug"]
    /// How long the helper keeps sleep blocked once no app is connected. Long enough for
    /// an app crash + relaunch; short enough that a lid-closed Mac isn't pinned awake by a
    /// block nobody owns any more.
    static let deadManGrace: TimeInterval = 60

    /// Code-signing requirement for the *other* side of the connection. Anchored to our own
    /// team (read from this process at runtime, so a fork signed under another Developer ID
    /// works unchanged), plus the exact identifiers. With no team (an ad-hoc local build)
    /// there is nothing to anchor to, and a self-signed binary can claim any identifier —
    /// so that case gets a requirement nothing can satisfy, and lid-closed mode simply
    /// doesn't work on unsigned builds.
    static func requirement(team: String?, identifiers: [String]) -> String {
        guard let team, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return "never"
        }
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(ids))"
    }

    /// Team identifier this process is signed with, or nil for an ad-hoc/unsigned build.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
