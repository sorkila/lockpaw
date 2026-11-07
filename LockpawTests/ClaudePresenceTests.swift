import XCTest
@testable import Lockpaw

/// The presence marker Claude Code reads through `CLAUDE_CLIENT_PRESENCE_FILE`: present
/// only while someone is at the Mac, and the settings.json merge that points Claude at it.
@MainActor
final class ClaudePresenceTests: XCTestCase {
    private var directory: URL!
    private var marker: ClaudePresenceMarker!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudePresenceTests-\(UUID().uuidString)", isDirectory: true)
        marker = ClaudePresenceMarker(url: ClaudePresence.markerURL(applicationSupport: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var exists: Bool { FileManager.default.fileExists(atPath: marker.url.path) }

    // MARK: - Path

    func testMarkerLivesInLockpawsApplicationSupportFolder() {
        let url = ClaudePresence.markerURL(applicationSupport: URL(fileURLWithPath: "/Users/me/Library/Application Support"))
        XCTAssertEqual(url.path, "/Users/me/Library/Application Support/Lockpaw/present")
        XCTAssertTrue(ClaudePresence.isLockpawMarkerPath(url.path))
        XCTAssertTrue(ClaudePresence.markerURL.path.hasSuffix("/Library/Application Support/Lockpaw/present"))
    }

    // MARK: - State transitions (file on disk)

    func testLaunchUnlocked_createsTheMarkerAndItsFolder() {
        marker.handle(.launched(sessionLocked: false))
        XCTAssertTrue(exists)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: marker.url.path)[.size] as? Int, 0, "no content")
    }

    /// A crash while unlocked leaves the file. Launching while macOS is locked removes it.
    func testLaunchWhileLocked_removesAStaleMarker() throws {
        try FileManager.default.createDirectory(at: marker.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker.url)
        marker.handle(.launched(sessionLocked: true))
        XCTAssertFalse(exists)
    }

    func testLockpawLockRemoves_unlockRecreates() {
        marker.handle(.launched(sessionLocked: false))
        marker.lockStateChanged(.locking)
        XCTAssertFalse(exists, "away from the moment the lock starts")
        marker.lockStateChanged(.locked)
        XCTAssertFalse(exists)
        marker.lockStateChanged(.unlocking)
        XCTAssertFalse(exists, "auth may still fail")
        marker.lockStateChanged(.unlocked)
        XCTAssertTrue(exists)
    }

    func testMacOSLockRemoves_onlyAConfirmedUnlockRecreates() {
        marker.handle(.launched(sessionLocked: false))
        marker.handle(.macOSLockHint)
        XCTAssertFalse(exists)
        marker.handle(.macOSUnlockHint(sessionLocked: true))
        XCTAssertFalse(exists, "a forged unlock must not hide pushes")
        marker.handle(.macOSUnlockHint(sessionLocked: false))
        XCTAssertTrue(exists)
    }

    func testSleepRemoves_wakeRecreatesUnlessMacOSLocked() {
        marker.handle(.launched(sessionLocked: false))
        marker.handle(.willSleep)
        XCTAssertFalse(exists)
        marker.handle(.didWake(sessionLocked: true))
        XCTAssertFalse(exists, "woke to the macOS lock screen")
        marker.handle(.macOSUnlockHint(sessionLocked: false))
        XCTAssertTrue(exists)

        marker.handle(.willSleep)
        marker.handle(.didWake(sessionLocked: false))
        XCTAssertTrue(exists, "no password after a short sleep")
    }

    func testDisplaySleepRemoves_wakeRecreatesUnlessMacOSLocked() {
        marker.handle(.launched(sessionLocked: false))
        marker.handle(.displaysDidSleep)
        XCTAssertFalse(exists)
        marker.handle(.displaysDidWake(sessionLocked: true))
        XCTAssertFalse(exists)
        marker.handle(.displaysDidWake(sessionLocked: false))
        XCTAssertTrue(exists)
    }

    /// Unlocking macOS doesn't undo a Lockpaw lock, and the other way round.
    func testEverySignalMustSayPresent() {
        marker.handle(.launched(sessionLocked: false))
        marker.lockStateChanged(.locked)
        marker.handle(.macOSLockHint)
        marker.handle(.macOSUnlockHint(sessionLocked: false))
        XCTAssertFalse(exists, "Lockpaw is still locked")
        marker.handle(.macOSLockHint)
        marker.lockStateChanged(.unlocked)
        XCTAssertFalse(exists, "macOS is still locked")
        marker.handle(.macOSUnlockHint(sessionLocked: false))
        XCTAssertTrue(exists)
    }

    func testQuitRemovesForGood() {
        marker.handle(.launched(sessionLocked: false))
        marker.handle(.willQuit)
        XCTAssertFalse(exists)
        marker.handle(.displaysDidWake(sessionLocked: false))
        XCTAssertFalse(exists)
    }

    /// The disk is checked each time, so a marker deleted behind Lockpaw's back returns.
    func testAMarkerRemovedFromOutsideComesBackOnTheNextEvent() throws {
        marker.handle(.launched(sessionLocked: false))
        try FileManager.default.removeItem(at: marker.url)
        marker.handle(.macOSUnlockHint(sessionLocked: false))
        XCTAssertTrue(exists)
    }

    func testDefaultSignalsArePresent_andLaunchResetsEverything() {
        XCTAssertTrue(ClaudePresence.Signals().isPresent)
        let messy = ClaudePresence.Signals(lockpawUnlocked: false, macOSLocked: true, systemAsleep: true, displaysAsleep: true, quitting: false)
        XCTAssertEqual(ClaudePresence.reduce(messy, .launched(sessionLocked: false)), ClaudePresence.Signals())
    }

    // MARK: - settings.json env merge

    private let path = "/Users/me/Library/Application Support/Lockpaw/present"

    private func env(_ root: [String: Any]) -> [String: Any]? { root["env"] as? [String: Any] }

    func testEnvIsAddedToAnEmptyConfig() {
        let (root, result) = ClaudePresence.mergingEnv(into: [:], path: path)
        XCTAssertEqual(result, .added)
        XCTAssertEqual(env(root)?[ClaudePresence.environmentKey] as? String, path)
    }

    func testOtherEnvVarsAndSettingsSurvive() {
        let config: [String: Any] = ["model": "opus", "env": ["DISABLE_TELEMETRY": "1"], "hooks": ["Stop": []]]
        let (root, result) = ClaudePresence.mergingEnv(into: config, path: path)
        XCTAssertEqual(result, .added)
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(root["hooks"])
        XCTAssertEqual(env(root)?["DISABLE_TELEMETRY"] as? String, "1")
        XCTAssertEqual(env(root)?[ClaudePresence.environmentKey] as? String, path)
    }

    func testMergingTwice_changesNothing() {
        let once = ClaudePresence.mergingEnv(into: ["env": ["A": "b"]], path: path).root
        let (twice, result) = ClaudePresence.mergingEnv(into: once, path: path)
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(once as NSDictionary, twice as NSDictionary)
    }

    func testAnOlderLockpawPathIsUpgraded() {
        let old: [String: Any] = ["env": [ClaudePresence.environmentKey: "/Users/old/Library/Application Support/Lockpaw/present"]]
        let (root, result) = ClaudePresence.mergingEnv(into: old, path: path)
        XCTAssertEqual(result, .upgraded)
        XCTAssertEqual(env(root)?[ClaudePresence.environmentKey] as? String, path)
    }

    func testSomeoneElsesValueIsNeverClobbered() {
        let foreign: [String: Any] = ["env": [ClaudePresence.environmentKey: "/tmp/hammerspoon-present"]]
        let (root, result) = ClaudePresence.mergingEnv(into: foreign, path: path)
        XCTAssertEqual(result, .foreign)
        XCTAssertEqual(root as NSDictionary, foreign as NSDictionary)
    }

    func testAnEnvThatIsNotAnObjectIsLeftAlone() {
        let odd: [String: Any] = ["env": ["not", "an", "object"]]
        let (root, result) = ClaudePresence.mergingEnv(into: odd, path: path)
        XCTAssertEqual(result, .foreign)
        XCTAssertEqual(root as NSDictionary, odd as NSDictionary)
    }

    /// The hook merge and the env merge compose: neither touches what the other wrote.
    func testHookAndEnvMergesCompose() {
        let hooked = AgentHookConfig.mergingPingHook(into: ["model": "opus"], events: ["Stop"], command: "lockpaw ping")
        let (root, _) = ClaudePresence.mergingEnv(into: hooked, path: path)
        let rehooked = AgentHookConfig.mergingPingHook(into: root, events: ["Stop"], command: "lockpaw ping")
        XCTAssertEqual(rehooked as NSDictionary, root as NSDictionary)
        XCTAssertEqual(env(rehooked)?[ClaudePresence.environmentKey] as? String, path)
        XCTAssertEqual(rehooked["model"] as? String, "opus")
    }

    func testSnippetIsTheEnvLineAndParsesAsJSON() throws {
        let snippet = ClaudePresence.settingsSnippet(path: path)
        XCTAssertEqual(snippet, "\"env\": { \"CLAUDE_CLIENT_PRESENCE_FILE\": \"\(path)\" }")
        let parsed = try JSONSerialization.jsonObject(with: Data("{\(snippet)}".utf8)) as? [String: Any]
        XCTAssertEqual((parsed?["env"] as? [String: Any])?[ClaudePresence.environmentKey] as? String, path)
    }

    func testIsConfiguredReadsTheEnvKey() {
        func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        XCTAssertTrue(ClaudePresence.isConfigured(settingsData: data(["env": [ClaudePresence.environmentKey: path]])))
        XCTAssertFalse(ClaudePresence.isConfigured(settingsData: data(["env": [ClaudePresence.environmentKey: "/tmp/other"]])))
        XCTAssertFalse(ClaudePresence.isConfigured(settingsData: data(["hooks": [:]])))
        XCTAssertFalse(ClaudePresence.isConfigured(settingsData: Data("not json".utf8)))
    }
}
