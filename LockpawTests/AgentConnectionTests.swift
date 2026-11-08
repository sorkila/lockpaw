import XCTest
@testable import Lockpaw

final class AgentConnectionTests: XCTestCase {
    func testEveryAgentHasAConfigFile() {
        for agent in AgentConnection.agents {
            XCTAssertNotNil(AgentConnection.configURL(for: agent, environment: ["HOME": "/Users/test"]), agent)
        }
        XCTAssertNil(AgentConnection.configURL(for: "nope", environment: ["HOME": "/Users/test"]))
    }

    func testConfigPathsFollowTheAgentsOwnVariables() {
        let env = ["HOME": "/Users/test", "CLAUDE_CONFIG_DIR": "/Users/test/.claude-work", "CODEX_HOME": "/opt/codex"]
        XCTAssertEqual(AgentConnection.configURL(for: "claude", environment: env)?.path, "/Users/test/.claude-work/settings.json")
        XCTAssertEqual(AgentConnection.configURL(for: "codex", environment: env)?.path, "/opt/codex/config.toml")
        XCTAssertEqual(AgentConnection.configURL(for: "gemini", environment: env)?.path, "/Users/test/.gemini/settings.json")
        XCTAssertEqual(AgentConnection.configURL(for: "copilot", environment: ["HOME": "/Users/test"])?.path, "/Users/test/.copilot/hooks/lockpaw.json")
    }

    func testAConfigIsConnectedWhenALineRunsALockpawPing() {
        let claude = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/.local/bin/lockpaw\" ping --agent claude"}]}]}}"#
        XCTAssertTrue(AgentConnection.isConnected(configContents: claude))
        XCTAssertTrue(AgentConnection.isConnected(configContents: #"notify = ["/Users/test/.local/bin/lockpaw", "ping", "--agent", "codex"]"#))
        XCTAssertTrue(AgentConnection.isConnected(configContents: "notifications: true\nnotifications-command: /Users/test/.local/bin/lockpaw ping --done\n"))
    }

    func testOtherHooksAreNotAConnection() {
        XCTAssertFalse(AgentConnection.isConnected(configContents: #"{"hooks":{"Stop":[{"hooks":[{"command":"say done"}]}]}}"#))
        // "lockpaw" and "ping" on different lines are not one command.
        XCTAssertFalse(AgentConnection.isConnected(configContents: "# installed lockpaw once\nhost = ping.example.com\n"))
        XCTAssertFalse(AgentConnection.isConnected(configContents: ""))
    }

    // MARK: - Codex status

    func testCodexHomeIsWhereTheCLIWritesAndSettingsReads() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(CodexConfig.directory(environment: [:], home: home).path, "/Users/test/.codex")
        XCTAssertEqual(CodexConfig.directory(environment: ["CODEX_HOME": ""], home: home).path, "/Users/test/.codex")
        XCTAssertEqual(CodexConfig.directory(environment: ["CODEX_HOME": "/opt/codex"], home: home).path, "/opt/codex")
        XCTAssertEqual(CodexConfig.directory(environment: ["CODEX_HOME": "~/work-codex"], home: home).path,
                       (("~/work-codex" as NSString).expandingTildeInPath as String))
        XCTAssertEqual(AgentConnection.configURL(for: "codex", environment: ["HOME": "/Users/test"])?.path, "/Users/test/.codex/config.toml")
    }

    /// #45: another tool's notify means Codex never calls Lockpaw, so it isn't "connected".
    func testCodexWithAnotherToolsNotifyIsNotConnected() {
        let config = "notify = [\"terminal-notifier\", \"-title\", \"Codex\"]\n[tui]\n"
        XCTAssertEqual(AgentConnection.status("codex", configContents: config), .notifyUsedByAnotherTool)
        XCTAssertEqual(AgentConnection.status("codex", configContents: "notify = \"say\"\n"), .notifyUsedByAnotherTool)
    }

    func testCodexStatusReadsOnlyTheTopLevelNotify() {
        let lockpaw = #"notify = ["/Users/test/.local/bin/lockpaw", "ping", "--agent", "codex"]"#
        XCTAssertEqual(AgentConnection.status("codex", configContents: "# Codex\n\(lockpaw)\n\n[tui]\n"), .connected)
        // Chained: Lockpaw runs first, so it is connected.
        let chained = #"notify = ["/Users/test/.local/bin/lockpaw", "ping", "--agent", "codex", "--", "say", "done"]"#
        XCTAssertEqual(AgentConnection.status("codex", configContents: chained), .connected)
        // Under a table, Codex never reads it.
        XCTAssertEqual(AgentConnection.status("codex", configContents: "[profiles.work]\n\(lockpaw)\n"), .notConnected)
        XCTAssertEqual(AgentConnection.status("codex", configContents: "model = \"o3\"\n"), .notConnected)
        XCTAssertEqual(AgentConnection.status("codex", configContents: ""), .notConnected)
    }

    func testOtherAgentsKeepTheLineCheck() {
        let claude = #"{"hooks":{"Stop":[{"hooks":[{"command":"\"$HOME/.local/bin/lockpaw\" ping --agent claude"}]}]}}"#
        XCTAssertEqual(AgentConnection.status("claude", configContents: claude), .connected)
        XCTAssertEqual(AgentConnection.status("claude", configContents: "{}"), .notConnected)
    }
}
