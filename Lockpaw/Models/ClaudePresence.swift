import Foundation

/// "Claude's phone pushes only while you're away." Claude Code skips its Remote Control
/// mobile pushes while the file named by `CLAUDE_CLIENT_PRESENCE_FILE` exists, and sends
/// them as normal when it is absent or unreadable. It checks the file once per push, it
/// doesn't poll. Lockpaw keeps that file present while the Mac is unlocked and in use,
/// and removes it whenever you lock (Lockpaw or macOS), the Mac or its displays sleep,
/// or Lockpaw quits.
///
/// Pure, and compiled into the CLI too: the app owns the file, the CLI writes the env key
/// into Claude Code's settings.json, and both must agree on the path.
enum ClaudePresence {
    /// Claude Code's env var (v2.1.181 or later).
    static let environmentKey = "CLAUDE_CLIENT_PRESENCE_FILE"

    /// The marker inside Lockpaw's Application Support folder, the same folder the custom
    /// mascot lives in.
    static func markerURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Lockpaw", isDirectory: true)
            .appendingPathComponent("present", isDirectory: false)
    }

    /// `~/Library/Application Support/Lockpaw/present`. Resolved with FileManager in both
    /// the app and the CLI (not `$HOME`), so the path the CLI writes is the one the app
    /// creates.
    static var markerURL: URL {
        markerURL(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    // MARK: - When you're present

    /// Everything that says whether someone is at this Mac. Any one of them false means
    /// away, and away is the safe side: a missing file only means pushes are sent.
    struct Signals: Equatable {
        /// Lockpaw is fully unlocked. Locking, locked and unlocking all count as away.
        var lockpawUnlocked = true
        var macOSLocked = false
        var systemAsleep = false
        var displaysAsleep = false
        var quitting = false

        var isPresent: Bool {
            lockpawUnlocked && !macOSLocked && !systemAsleep && !displaysAsleep && !quitting
        }
    }

    enum Event: Equatable {
        /// Launch: start from a clean slate, reading the real macOS lock state. A marker a
        /// crashed run left behind is removed here when the screen is locked.
        case launched(sessionLocked: Bool)
        case lockpawState(unlocked: Bool)
        /// `com.apple.screenIsLocked`. Any process can post it, but acting on a forged one
        /// only sends pushes, so it is believed at once.
        case macOSLockHint
        /// `com.apple.screenIsUnlocked`, with the window server's answer. A forged unlock
        /// must not hide pushes, so only the confirmed state counts.
        case macOSUnlockHint(sessionLocked: Bool)
        case willSleep
        case didWake(sessionLocked: Bool)
        case displaysDidSleep
        case displaysDidWake(sessionLocked: Bool)
        case willQuit
    }

    static func reduce(_ signals: Signals, _ event: Event) -> Signals {
        var next = signals
        switch event {
        case .launched(let sessionLocked):
            next = Signals(macOSLocked: sessionLocked)
        case .lockpawState(let unlocked):
            next.lockpawUnlocked = unlocked
        case .macOSLockHint:
            next.macOSLocked = true
        case .macOSUnlockHint(let sessionLocked):
            next.macOSLocked = sessionLocked
        case .willSleep:
            next.systemAsleep = true
        case .didWake(let sessionLocked):
            next.systemAsleep = false
            next.macOSLocked = sessionLocked
        case .displaysDidSleep:
            next.displaysAsleep = true
        case .displaysDidWake(let sessionLocked):
            next.displaysAsleep = false
            next.macOSLocked = sessionLocked
        case .willQuit:
            next.quitting = true
        }
        return next
    }

    // MARK: - Claude Code settings.json

    enum EnvMerge: Equatable {
        case added
        /// An older Lockpaw path (another home folder, say) was replaced.
        case upgraded
        case unchanged
        /// Someone else's value is already set, or `env` isn't an object. Never clobbered.
        case foreign
    }

    /// A value Lockpaw wrote, wherever the home folder was at the time.
    static func isLockpawMarkerPath(_ value: String) -> Bool {
        value.hasSuffix("/Lockpaw/present")
    }

    /// Set `env.CLAUDE_CLIENT_PRESENCE_FILE` in a Claude Code settings object. Same rules as
    /// the hook merge: every other key, and every other env var, is left as it was, and a
    /// value that isn't Lockpaw's is never overwritten.
    static func mergingEnv(into root: [String: Any], path: String) -> (root: [String: Any], result: EnvMerge) {
        var root = root
        var env: [String: Any]
        switch root["env"] {
        case nil: env = [:]
        case let existing as [String: Any]: env = existing
        default: return (root, .foreign)
        }
        let result: EnvMerge
        switch env[environmentKey] {
        case nil:
            result = .added
        case let current as String where current == path:
            return (root, .unchanged)
        case let current as String where isLockpawMarkerPath(current):
            result = .upgraded
        default:
            return (root, .foreign)
        }
        env[environmentKey] = path
        root["env"] = env
        return (root, result)
    }

    /// The line to paste into settings.json by hand (Settings → Agents → Copy Setup).
    static func settingsSnippet(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"env\": { \"\(environmentKey)\": \"\(escaped)\" }"
    }

    /// Whether a settings.json already points Claude Code at a Lockpaw marker.
    static func isConfigured(settingsData: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any],
              let value = (root["env"] as? [String: Any])?[environmentKey] as? String else { return false }
        return isLockpawMarkerPath(value)
    }
}
