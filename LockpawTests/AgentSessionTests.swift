import Testing
import Foundation
@testable import Lockpaw

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func hook(
    _ name: String,
    session: String = "S1",
    cwd: String? = "/Users/me/projects/lockpaw",
    agent: String? = nil,
    agentTranscript: String? = nil,
    notification: String? = nil,
    source: String? = nil
) -> AgentHookEvent {
    AgentHookEvent(
        hookEventName: name, sessionID: session, cwd: cwd, agentID: agent,
        agentTranscriptPath: agentTranscript, notificationType: notification, source: source
    )
}

/// Folds events through the reducer, one second apart, the way the store would.
private func run(_ events: [AgentHookEvent], from start: AgentSession? = nil) -> AgentSession? {
    var session = start
    for (i, event) in events.enumerated() {
        switch AgentSessionReducer.apply(event, to: session, now: t0.addingTimeInterval(Double(i))) {
        case .write(let next): session = next
        case .remove: session = nil
        case .ignore: break
        }
    }
    return session
}

// MARK: - Hook payloads

@Suite struct HookEventDecoding {
    @Test func decodesTheFieldsClaudeSends() throws {
        let json = """
        {"session_id":"abc","transcript_path":"/t.jsonl","cwd":"/Users/me/p","hook_event_name":"SubagentStop",
         "agent_id":"a1","agent_type":"general-purpose","agent_transcript_path":"/x/abc/subagents/agent-a1.jsonl",
         "stop_hook_active":false,"permission_mode":"default"}
        """
        let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
        #expect(event.hookEventName == "SubagentStop")
        #expect(event.sessionID == "abc")
        #expect(event.cwd == "/Users/me/p")
        #expect(event.agentID == "a1")
        #expect(event.agentTranscriptPath == "/x/abc/subagents/agent-a1.jsonl")
    }

    @Test func subagentTranscriptPathPinsTheParentSession() {
        let event = hook("SubagentStop", session: "CHILD", agent: "a1",
                         agentTranscript: "/Users/me/.claude/projects/-p/PARENT/subagents/agent-a1.jsonl")
        #expect(event.owningSessionID == "PARENT")
    }

    @Test func withoutASubagentPathTheSessionIDOwnsTheEvent() {
        #expect(hook("Stop", session: "S9").owningSessionID == "S9")
        #expect(hook("SubagentStop", session: "S9", agentTranscript: "/odd/path.jsonl").owningSessionID == "S9")
    }
}

// MARK: - Status transitions

@Suite struct SessionStatusTransitions {
    @Test func aNewSessionIsIdleUntilItRunsAPrompt() {
        let s = run([hook("SessionStart", source: "startup")])
        #expect(s?.status == .idle)
        #expect(s?.folderName == "lockpaw")
    }

    @Test func promptMakesItWorkingAndStopMakesItDone() {
        #expect(run([hook("SessionStart"), hook("UserPromptSubmit")])?.status == .working)
        #expect(run([hook("SessionStart"), hook("UserPromptSubmit"), hook("Stop")])?.status == .done)
    }

    @Test func stopWithBackgroundSubagentsStillRunningIsNotDone() {
        let s = run([hook("UserPromptSubmit"), hook("SubagentStart", agent: "a1"), hook("Stop")])
        #expect(s?.status == .working)
        #expect(s?.runningAgents == ["a1"])
    }

    @Test func theLastSubagentFinishingAfterStopMakesItDone() {
        let s = run([hook("UserPromptSubmit"), hook("SubagentStart", agent: "a1"),
                     hook("Stop"), hook("SubagentStop", agent: "a1")])
        #expect(s?.status == .done)
    }

    @Test func parallelSubagentsAreCountedIndividually() {
        let s = run([hook("UserPromptSubmit"),
                     hook("SubagentStart", agent: "a1"), hook("SubagentStart", agent: "a2"),
                     hook("SubagentStart", agent: "a3"), hook("SubagentStop", agent: "a2"), hook("Stop")])
        #expect(s?.runningAgents == ["a1", "a3"])
        #expect(s?.status == .working)
    }

    @Test func aRepeatedSubagentStartCountsOnce() {
        let s = run([hook("SubagentStart", agent: "a1"), hook("SubagentStart", agent: "a1")])
        #expect(s?.runningAgents.count == 1)
    }

    @Test func permissionPromptMeansNeedsYou() {
        let s = run([hook("UserPromptSubmit"), hook("Notification", notification: "permission_prompt")])
        #expect(s?.status == .needsYou)
    }

    @Test func everyBlockingNotificationTypeMeansNeedsYou() {
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            #expect(run([hook("UserPromptSubmit"), hook("Notification", notification: type)])?.status == .needsYou, "\(type)")
        }
    }

    @Test func idlePromptAndOtherNotificationsAreIgnored() {
        let done = run([hook("UserPromptSubmit"), hook("Stop")])!
        for type in ["idle_prompt", "auth_success", "agent_completed"] {
            #expect(AgentSessionReducer.apply(hook("Notification", notification: type), to: done, now: t0) == .ignore, "\(type)")
        }
    }

    @Test func anIgnorableNotificationNeverCreatesASession() {
        #expect(AgentSessionReducer.apply(hook("Notification", notification: "idle_prompt"), to: nil, now: t0) == .ignore)
    }

    @Test func workResumingClearsNeedsYou() {
        let blocked = [hook("UserPromptSubmit"), hook("Notification", notification: "permission_prompt")]
        #expect(run(blocked + [hook("SubagentStart", agent: "a1")])?.status == .working)
        #expect(run(blocked + [hook("Stop")])?.status == .done)
        #expect(run(blocked + [hook("UserPromptSubmit")])?.status == .working)
    }

    @Test func stopFailureMeansError() {
        #expect(run([hook("UserPromptSubmit"), hook("StopFailure")])?.status == .error)
    }

    @Test func aNewPromptClearsAnError() {
        #expect(run([hook("UserPromptSubmit"), hook("StopFailure"), hook("UserPromptSubmit")])?.status == .working)
    }

    @Test func sessionEndRemovesIt() {
        let live = run([hook("UserPromptSubmit")])
        #expect(AgentSessionReducer.apply(hook("SessionEnd"), to: live, now: t0) == .remove)
    }

    @Test func unknownEventsAreIgnored() {
        let live = run([hook("UserPromptSubmit")])
        #expect(AgentSessionReducer.apply(hook("PreCompact"), to: live, now: t0) == .ignore)
    }

    @Test func hooksInstalledMidSessionStillTrackIt() {
        // No SessionStart was ever seen — the first event creates the session.
        #expect(run([hook("SubagentStart", agent: "a1")])?.status == .working)
    }

    @Test func clearResetsButCompactKeepsRunningSubagents() {
        let busy = run([hook("UserPromptSubmit"), hook("SubagentStart", agent: "a1")])
        #expect(run([hook("SessionStart", source: "compact")], from: busy)?.runningAgents == ["a1"])
        let cleared = run([hook("SessionStart", source: "clear")], from: busy)
        #expect(cleared?.runningAgents.isEmpty == true)
        #expect(cleared?.status == .idle)
    }

    @Test func statusSinceMovesOnlyWhenTheStatusChanges() {
        let working = run([hook("UserPromptSubmit"), hook("SubagentStart", agent: "a1")])!
        #expect(working.statusSince == t0) // second event kept it .working
        let done = run([hook("Stop"), hook("SubagentStop", agent: "a1")], from: working)!
        #expect(done.statusSince == t0.addingTimeInterval(1))
    }
}

// MARK: - Store

private func makeStore() -> AgentSessionStore {
    AgentSessionStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("lockpaw-sessions-\(UUID().uuidString)", isDirectory: true))
}

@discardableResult
private func record(_ event: AgentHookEvent, in store: AgentSessionStore, at now: Date = t0) -> AgentSessionUpdate {
    store.update(sessionID: event.owningSessionID) { current in
        AgentSessionReducer.apply(event, to: current, now: now)
    }
}

@Suite struct SessionStore {
    @Test func sessionsGetStableSlotsInStartOrder() {
        let store = makeStore()
        defer { store.removeAll() }
        record(hook("SessionStart", session: "A"), in: store)
        record(hook("SessionStart", session: "B"), in: store)
        record(hook("UserPromptSubmit", session: "A"), in: store)
        #expect(store.loadAll().map(\.id) == ["A", "B"])
        #expect(store.loadAll().map(\.slot) == [1, 2])
    }

    @Test func aFreedSlotIsReusedByTheNextSession() {
        let store = makeStore()
        defer { store.removeAll() }
        for id in ["A", "B", "C"] { record(hook("SessionStart", session: id), in: store) }
        record(hook("SessionEnd", session: "A"), in: store)
        record(hook("SessionStart", session: "D"), in: store)
        let slots = Dictionary(uniqueKeysWithValues: store.loadAll().map { ($0.id, $0.slot) })
        #expect(slots == ["D": 1, "B": 2, "C": 3])
    }

    @Test func anIgnoredEventWritesNothing() {
        let store = makeStore()
        defer { store.removeAll() }
        let update = record(hook("Notification", notification: "idle_prompt"), in: store)
        #expect(update.changed == false)
        #expect(store.loadAll().isEmpty)
    }

    @Test func updatesReportWhatChanged() {
        let store = makeStore()
        defer { store.removeAll() }
        let first = record(hook("UserPromptSubmit"), in: store)
        #expect(first.old == nil)
        #expect(first.new?.status == .working)
        let second = record(hook("Stop"), in: store, at: t0.addingTimeInterval(5))
        #expect(second.old?.status == .working)
        #expect(second.new?.status == .done)
    }

    @Test func sessionEndDeletesTheFile() {
        let store = makeStore()
        defer { store.removeAll() }
        record(hook("UserPromptSubmit"), in: store)
        record(hook("SessionEnd"), in: store)
        #expect(store.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: "S1").path))
    }

    @Test func hostileSessionIDsStayInsideTheStore() {
        let store = makeStore()
        defer { store.removeAll() }
        let url = store.fileURL(for: "../../outside/evil")
        #expect(url.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
        record(hook("UserPromptSubmit", session: "../../outside/evil"), in: store)
        #expect(store.loadAll().count == 1)
    }

    @Test func corruptFilesAreSkipped() throws {
        let store = makeStore()
        defer { store.removeAll() }
        record(hook("UserPromptSubmit", session: "good"), in: store)
        try Data("not json".utf8).write(to: store.fileURL(for: "broken"))
        #expect(store.loadAll().map(\.id) == ["good"])
    }

    @Test func parallelWritersNeverLoseAnEvent() {
        // Parallel subagents fire SubagentStart at the same instant; without the store
        // lock, read-modify-write races drop agents from the set.
        let store = makeStore()
        defer { store.removeAll() }
        record(hook("UserPromptSubmit"), in: store)
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            record(hook("SubagentStart", agent: "agent-\(i)"), in: store)
        }
        #expect(store.loadAll().first?.runningAgents.count == 24)
    }

    @Test func sessionsLeftOpenForDaysStayOnTheBoard() {
        // Sessions are kept open for days and picked back up — silence alone must never
        // remove one. Booted before the session's last event: nothing is pruned.
        let store = makeStore()
        defer { store.removeAll() }
        record(hook("UserPromptSubmit", session: "days-old"), in: store, at: t0)
        record(hook("Stop", session: "days-old"), in: store, at: t0.addingTimeInterval(60))
        let pruned = store.pruneSessions(lastEventBefore: t0.addingTimeInterval(-3600))
        #expect(pruned == 0)
        #expect(store.loadAll().map(\.id) == ["days-old"])
    }

    @Test func sessionsFromBeforeTheLastRebootArePruned() {
        // No process survives a reboot, so a session whose last event predates the boot is
        // gone even though no SessionEnd ever fired.
        let store = makeStore()
        defer { store.removeAll() }
        record(hook("UserPromptSubmit", session: "before-boot"), in: store, at: t0)
        record(hook("UserPromptSubmit", session: "after-boot"), in: store, at: t0.addingTimeInterval(7200))
        let pruned = store.pruneSessions(lastEventBefore: t0.addingTimeInterval(3600))
        #expect(pruned == 1)
        #expect(store.loadAll().map(\.id) == ["after-boot"])
    }

    @Test func theSystemBootTimeIsKnownAndInThePast() throws {
        let boot = try #require(AgentSessionStore.systemBootTime)
        #expect(boot < Date())
        #expect(boot > Date(timeIntervalSinceNow: -365 * 24 * 3600))
    }

    @Test func removeAllClearsTheBoard() {
        let store = makeStore()
        record(hook("UserPromptSubmit", session: "A"), in: store)
        record(hook("UserPromptSubmit", session: "B"), in: store)
        store.removeAll()
        #expect(store.loadAll().isEmpty)
    }
}

// MARK: - Subagent totals & session titles

@Suite struct SubagentTotals {
    @Test func finishedSubagentsAreCountedOnce() {
        let s = run([hook("UserPromptSubmit"),
                     hook("SubagentStart", agent: "a1"), hook("SubagentStart", agent: "a2"),
                     hook("SubagentStop", agent: "a1"), hook("SubagentStop", agent: "a1")])
        #expect(s?.runningAgents == ["a2"])
        #expect(s?.finishedAgents == ["a1"])
    }

    @Test func aStopForAnUnseenSubagentStillCountsAsFinished() {
        // Hooks installed mid-run: the start was never seen, the finish still happened.
        #expect(run([hook("SubagentStop", agent: "early")])?.finishedAgents == ["early"])
    }

    @Test func clearStartsTheCountsOver() {
        let busy = run([hook("SubagentStart", agent: "a1"), hook("SubagentStop", agent: "a1")])
        #expect(run([hook("SessionStart", source: "clear")], from: busy)?.finishedAgents.isEmpty == true)
    }

    @Test func sessionFilesFromBeforeTheseFieldsStillLoad() throws {
        // Sessions stay open for days — a file written by the previous build must decode,
        // or the session would silently drop and come back under a new number.
        let old = """
        {"id":"S1","slot":2,"cwd":"/p","startedAt":1800000000,"updatedAt":1800000000,"turnActive":false,
         "runningAgents":["a1"],"hasWorked":true,"statusSince":1800000000}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let s = try decoder.decode(AgentSession.self, from: Data(old.utf8))
        #expect(s.slot == 2)
        #expect(s.runningAgents == ["a1"])
        #expect(s.finishedAgents.isEmpty)
        #expect(s.displayTitle == nil)
    }
}

@Suite struct SessionTitles {
    @Test func titlesAreReadFromTheTranscriptTail() {
        // The tail starts mid-line; that fragment must be skipped, not mis-parsed.
        let tail = """
        Title","aiTitle":"Truncated junk"}
        {"type":"user","message":"hi"}
        {"type":"ai-title","aiTitle":"Old title","sessionId":"S1"}
        {"type":"assistant","message":"…"}
        {"type":"ai-title","aiTitle":"Lanes findings","sessionId":"S1"}
        """
        let titles = AgentSessionTitles.latest(in: Data(tail.utf8))
        #expect(titles.ai == "Lanes findings")
        #expect(titles.custom == nil)
    }

    @Test func aRenamedSessionKeepsItsCustomTitle() {
        let tail = """
        {"type":"custom-title","customTitle":"acme recon","sessionId":"S1"}
        {"type":"ai-title","aiTitle":"Lanes findings","sessionId":"S1"}
        """
        let titles = AgentSessionTitles.latest(in: Data(tail.utf8))
        #expect(titles.custom == "acme recon")
        let s = AgentSessionReducer.apply(hook("Stop"), to: run([hook("UserPromptSubmit")]), now: t0, titles: titles)
        guard case .write(let session) = s else { Issue.record("expected a write"); return }
        #expect(session.displayTitle == "acme recon")
    }

    @Test func titlesAreSingleLineAndCapped() {
        let long = String(repeating: "x", count: 200)
        let tail = "{\"type\":\"ai-title\",\"aiTitle\":\"line one\\nline two \(long)\"}\n"
        let title = AgentSessionTitles.latest(in: Data(tail.utf8)).ai
        #expect(title?.contains("\n") == false)
        #expect((title?.count ?? 0) <= AgentSessionTitles.maxLength)
    }

    @Test func noTitleInTheTailKeepsTheOneAlreadyKnown() {
        let known = AgentSessionReducer.apply(hook("Stop"), to: run([hook("UserPromptSubmit")]), now: t0,
                                              titles: AgentSessionTitles(ai: "Lanes findings", custom: nil))
        guard case .write(let session) = known else { Issue.record("expected a write"); return }
        let later = AgentSessionReducer.apply(hook("Stop"), to: session, now: t0,
                                              titles: AgentSessionTitles(ai: nil, custom: nil))
        guard case .write(let after) = later else { Issue.record("expected a write"); return }
        #expect(after.displayTitle == "Lanes findings")
    }
}

@Suite struct SubagentSummary {
    @Test func aSubagentThatStartsAgainCountsAsRunningNotFinished() {
        let s = run([hook("SubagentStart", agent: "a1"), hook("SubagentStop", agent: "a1"), hook("SubagentStart", agent: "a1")])
        #expect(s?.runningAgents == ["a1"])
        #expect(s?.finishedAgents.isEmpty == true)
    }

    @Test func summaryNamesRunningThenFinished() {
        let none = run([hook("UserPromptSubmit")])
        #expect(none?.subagentSummary == "none yet")

        let mixed = run([hook("SubagentStart", agent: "a1"), hook("SubagentStart", agent: "a2"), hook("SubagentStart", agent: "a3"),
                         hook("SubagentStop", agent: "a1"), hook("SubagentStop", agent: "a2")])
        #expect(mixed?.subagentSummary == "1 running · 2 finished")

        let onlyRunning = run([hook("SubagentStart", agent: "a1")])
        #expect(onlyRunning?.subagentSummary == "1 running")

        let onlyFinished = run([hook("SubagentStart", agent: "a1"), hook("SubagentStop", agent: "a1")])
        #expect(onlyFinished?.subagentSummary == "1 finished")
    }
}

// MARK: - Session hooks in Claude's settings

@Suite struct SessionHookMerge {
    private let session = "\"$HOME/.local/bin/lockpaw\" session"
    private let ping = "\"$HOME/.local/bin/lockpaw\" ping --agent claude"

    private func groups(_ root: [String: Any], _ event: String) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    private func entries(_ root: [String: Any], _ event: String) -> [[String: Any]] {
        groups(root, event).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    private func installed(_ root: [String: Any]) -> [String: Any] {
        let pinged = AgentHookConfig.mergingPingHook(
            into: root, events: ["Notification", "Stop", "StopFailure"], command: ping,
            matchers: ["Notification": AgentHookConfig.claudeNotificationMatcher]
        )
        return AgentHookConfig.mergingSessionHooks(into: pinged, command: session)
    }

    @Test func everyBoardEventGetsOneSessionHook_asyncExceptSessionEnd() {
        let root = installed([:])
        for event in AgentHookConfig.claudeSessionEvents {
            let ours = entries(root, event).filter { $0["command"] as? String == session }
            #expect(ours.count == 1, "\(event)")
            #expect((ours.first?["async"] as? Bool) == (event == "SessionEnd" ? nil : true), "\(event)")
        }
    }

    @Test func pingHooksAndForeignHooksSurvive() {
        let foreign: [String: Any] = ["hooks": [["type": "command", "command": "say done"]]]
        let root = installed(["model": "opus", "hooks": ["Stop": [foreign]]])
        #expect(root["model"] as? String == "opus")
        let stop = entries(root, "Stop").compactMap { $0["command"] as? String }
        #expect(stop == ["say done", ping, session])
        let notification = groups(root, "Notification")
        #expect(notification.first?["matcher"] as? String == AgentHookConfig.claudeNotificationMatcher)
        #expect(notification.last?["matcher"] == nil)
    }

    @Test func installingTwiceChangesNothing() {
        let once = installed([:])
        #expect(installed(once) as NSDictionary == once as NSDictionary)
    }

    @Test func anOlderSessionHookIsUpgradedInPlace() {
        let old: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": "lockpaw session"]]]]]]
        let prompt = entries(installed(old), "UserPromptSubmit")
        #expect(prompt.count == 1)
        #expect(prompt.first?["command"] as? String == session)
        #expect(prompt.first?["async"] as? Bool == true)
    }

    @Test func pingAndSessionCommandsNeverMatchEachOther() {
        #expect(!AgentHookConfig.isLockpawPingCommand(session))
        #expect(!AgentHookConfig.isLockpawSessionCommand(ping))
        #expect(AgentHookConfig.isLockpawSessionCommand("lockpaw session"))
    }
}
