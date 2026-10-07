import AppIntents
import Foundation

/// Shortcuts, Spotlight and Siri. Deliberately one-way: there is no unlock intent. Siri
/// works while the screen is covered, so "unlock Lockpaw" would open it for anyone in the
/// room, and anything a Shortcut can run, so can any local script. Unlocking stays with the
/// hotkey, Touch ID and the password.
struct LockScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Screen"
    static let description = IntentDescription("Cover the screen with Lockpaw. Your agents keep running.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // The same path as lockpaw://lock — observed in LockController.init, so it works
        // before the menu has ever been opened and with the menu bar icon hidden.
        NotificationCenter.default.post(name: .lockpawLock, object: nil)
        return .result()
    }
}

struct IsLockedIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Lockpaw Locked?"
    static let description = IntentDescription("Whether Lockpaw is covering the screen right now.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: LockStatus.shared.state != .unlocked)
    }
}

struct LockpawShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LockScreenIntent(),
            phrases: ["Lock with \(.applicationName)", "Lock my screen with \(.applicationName)"],
            shortTitle: "Lock Screen",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: IsLockedIntent(),
            phrases: ["Is \(.applicationName) locked"],
            shortTitle: "Is Locked?",
            systemImageName: "lock.circle"
        )
    }
}
