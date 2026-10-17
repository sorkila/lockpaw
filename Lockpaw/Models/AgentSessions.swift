import Foundation

// Agent Sessions — the shared core behind the session board. Compiled into the app,
// the `lockpaw` CLI and the tests, so it depends on Foundation only. The CLI turns Claude
// Code hook events into per-session state; the app only reads and displays it.

/// What the board shows for one session.
enum AgentSessionStatus: String, Codable, Sendable {
    /// Started, but no prompt has run yet.
    case idle
    case working
    case needsYou
    case done
    case error
}

struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    enum Attention: String, Codable, Sendable {
        case needsInput, failed
    }

    let id: String
    /// Stable 1-based number shown as "Session N" — assigned by the store at creation.
    var slot: Int
    var cwd: String
    var startedAt: Date
    var updatedAt: Date
    /// The main thread is mid-turn (between a prompt and its Stop).
    var turnActive: Bool
    /// Subagent ids between SubagentStart and SubagentStop. A set, not a counter, so a
    /// repeated event can't drift it. Subagents run in the background by default, so this
    /// can be non-empty after the main turn has stopped.
    var runningAgents: Set<String>
    /// Subagent ids that have finished this session — a set for the same reason as
    /// `runningAgents`, so the card can say "2 running · 5 finished".
    var finishedAgents: Set<String> = []
    /// Claude's generated title and the one set with /rename — the name a terminal tab shows.
    var aiTitle: String? = nil
    var customTitle: String? = nil
    var attention: Attention?
    var hasWorked: Bool
    /// When `status` last changed — drives "done · 4m ago".
    var statusSince: Date

    var status: AgentSessionStatus {
        switch attention {
        case .failed: return .error
        case .needsInput: return .needsYou
        case nil:
            if turnActive || !runningAgents.isEmpty { return .working }
            return hasWorked ? .done : .idle
        }
    }

    var folderName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? cwd : name
    }

    /// A title set with /rename wins over the generated one.
    var displayTitle: String? { customTitle ?? aiTitle }

    /// "2 running · 5 finished" — the subagents this session has started, by outcome.
    var subagentSummary: String {
        var parts: [String] = []
        if !runningAgents.isEmpty { parts.append("\(runningAgents.count) running") }
        if !finishedAgents.isEmpty { parts.append("\(finishedAgents.count) finished") }
        return parts.isEmpty ? "none yet" : parts.joined(separator: " · ")
    }
}

extension AgentSession {
    /// Fields added after the first build decode as empty, so a session file written by an
    /// older build still loads — sessions stay open for days, and a file that failed to
    /// decode would drop off the board and come back under a new number.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slot = try c.decode(Int.self, forKey: .slot)
        cwd = try c.decode(String.self, forKey: .cwd)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        turnActive = try c.decode(Bool.self, forKey: .turnActive)
        runningAgents = try c.decode(Set<String>.self, forKey: .runningAgents)
        finishedAgents = try c.decodeIfPresent(Set<String>.self, forKey: .finishedAgents) ?? []
        aiTitle = try c.decodeIfPresent(String.self, forKey: .aiTitle)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        attention = try c.decodeIfPresent(Attention.self, forKey: .attention)
        hasWorked = try c.decode(Bool.self, forKey: .hasWorked)
        statusSince = try c.decode(Date.self, forKey: .statusSince)
    }
}

/// The session's name as Claude shows it — and as the terminal tab running it shows it.
/// Both kinds live in the transcript as `ai-title` / `custom-title` lines that Claude keeps
/// re-writing (measured: always within ~31KB of the end), so reading the tail once per turn
/// finds the current one without ever reading a multi-megabyte transcript whole.
struct AgentSessionTitles: Equatable, Sendable {
    var ai: String?
    var custom: String?

    static let maxLength = 80
    static let tailBytes = 128 * 1024

    /// Latest titles in a chunk of transcript. The chunk may start mid-line; that fragment
    /// fails to parse and is skipped. Only lines that mention a title are parsed at all.
    static func latest(in tail: Data) -> AgentSessionTitles {
        let marker = Data("-title\"".utf8)
        var result = AgentSessionTitles()
        for line in tail.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "ai-title": if let title = clean(object["aiTitle"]) { result.ai = title }
            case "custom-title": if let title = clean(object["customTitle"]) { result.custom = title }
            default: break
            }
        }
        return result
    }

    /// Titles from the end of a transcript. The path arrives on hook stdin, so only a
    /// `.jsonl` file is opened, and only its last `tailBytes` are read.
    static func read(transcriptAt path: String) -> AgentSessionTitles? {
        guard path.hasSuffix(".jsonl"), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return latest(in: data)
    }

    private static func clean(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return nil }
        return String(oneLine.prefix(maxLength))
    }
}

/// The subset of a Claude Code hook's stdin JSON the board needs.
struct AgentHookEvent: Decodable, Equatable, Sendable {
    let hookEventName: String
    let sessionID: String
    let cwd: String?
    let agentID: String?
    let agentTranscriptPath: String?
    let notificationType: String?
    let source: String?
    var transcriptPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case transcriptPath = "transcript_path"
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case agentID = "agent_id"
        case agentTranscriptPath = "agent_transcript_path"
        case notificationType = "notification_type"
        case source
    }

    /// The session this event belongs to. Subagent transcripts live at
    /// `<projects>/<parent session>/subagents/agent-<id>.jsonl`, which pins the parent
    /// even if a subagent event were ever to carry an id of its own.
    var owningSessionID: String {
        if let path = agentTranscriptPath {
            let parts = path.split(separator: "/")
            if let i = parts.lastIndex(of: "subagents"), i > parts.startIndex {
                return String(parts[parts.index(before: i)])
            }
        }
        return sessionID
    }
}

enum AgentSessionChange: Equatable, Sendable {
    case write(AgentSession)
    case remove
    /// Nothing to record — the store writes nothing and the app is not nudged.
    case ignore
}

/// Pure event → state rules, free of I/O so every branch is unit-tested directly.
enum AgentSessionReducer {
    /// Notification types that mean the session is blocked until you act.
    static let needsInputNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    /// `titles` — read from the transcript by the caller, once per turn — update the
    /// session's name when given; a nil field keeps the name already known.
    static func apply(_ event: AgentHookEvent, to current: AgentSession?, now: Date,
                      titles: AgentSessionTitles? = nil) -> AgentSessionChange {
        var session = current ?? AgentSession(
            id: event.owningSessionID, slot: 0, cwd: event.cwd ?? "",
            startedAt: now, updatedAt: now, turnActive: false, runningAgents: [],
            finishedAgents: [], aiTitle: nil, customTitle: nil,
            attention: nil, hasWorked: false, statusSince: now
        )
        let before = current?.status

        switch event.hookEventName {
        case "SessionStart":
            // compact / resume continue the same work; startup / clear begin afresh.
            if event.source != "compact" && event.source != "resume" {
                session.turnActive = false
                session.runningAgents = []
                session.finishedAgents = []
                session.attention = nil
                session.hasWorked = false
            }
        case "UserPromptSubmit":
            session.turnActive = true
            session.attention = nil
            session.hasWorked = true
        case "SubagentStart":
            if let agent = event.agentID {
                session.runningAgents.insert(agent)
                session.finishedAgents.remove(agent)  // resumed — running now, not both
            }
            if session.attention == .needsInput { session.attention = nil }
            session.hasWorked = true
        case "SubagentStop":
            if let agent = event.agentID {
                session.runningAgents.remove(agent)
                session.finishedAgents.insert(agent)
            }
            if session.attention == .needsInput { session.attention = nil }
        case "Notification":
            guard let type = event.notificationType, needsInputNotifications.contains(type) else { return .ignore }
            session.attention = .needsInput
        case "Stop":
            session.turnActive = false
            if session.attention == .needsInput { session.attention = nil }
        case "StopFailure":
            session.turnActive = false
            session.attention = .failed
        case "SessionEnd":
            return current == nil ? .ignore : .remove
        default:
            return .ignore
        }

        if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let ai = titles?.ai { session.aiTitle = ai }
        if let custom = titles?.custom { session.customTitle = custom }
        session.updatedAt = now
        if session.status != before { session.statusSince = now }
        return .write(session)
    }
}

// MARK: - Store

struct AgentSessionUpdate: Equatable, Sendable {
    let old: AgentSession?
    let new: AgentSession?
    var changed: Bool { old != new }
}

/// One small JSON file per session. Every write holds a single lock on the directory:
/// parallel subagents fire their hooks at the same instant, and slot numbers are assigned
/// by looking at every live session, so both need the writes serialized.
struct AgentSessionStore: Sendable {
    let directory: URL

    /// When this Mac last booted. No process survives a reboot, so a session whose last
    /// event predates it is gone even though no SessionEnd ever fired.
    static var systemBootTime: Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    static var standard: AgentSessionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AgentSessionStore(directory: support.appendingPathComponent("Lockpaw/Sessions", isDirectory: true))
    }

    /// Session ids come from hook stdin; anything outside a safe file-name alphabet is
    /// replaced so an id can never point outside the store.
    func fileURL(for sessionID: String) -> URL {
        let safe = String(sessionID.map { Self.fileNameAlphabet.contains($0) ? $0 : "_" })
        return directory.appendingPathComponent(safe.isEmpty ? "_" : safe).appendingPathExtension("json")
    }

    /// Live sessions in slot order.
    func loadAll() -> [AgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.makeDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AgentSession.self, from: $0) } }
            .sorted { ($0.slot, $0.startedAt.timeIntervalSince1970) < ($1.slot, $1.startedAt.timeIntervalSince1970) }
    }

    /// Read-modify-write one session under the store lock.
    @discardableResult
    func update(sessionID: String, _ transform: (AgentSession?) -> AgentSessionChange) -> AgentSessionUpdate {
        withLock {
            let url = fileURL(for: sessionID)
            let old = (try? Data(contentsOf: url)).flatMap { try? Self.makeDecoder().decode(AgentSession.self, from: $0) }
            switch transform(old) {
            case .ignore:
                return AgentSessionUpdate(old: old, new: old)
            case .remove:
                try? FileManager.default.removeItem(at: url)
                return AgentSessionUpdate(old: old, new: nil)
            case .write(var session):
                if old == nil { session.slot = nextFreeSlot() }
                try? Self.makeEncoder().encode(session).write(to: url, options: .atomic)
                return AgentSessionUpdate(old: old, new: session)
            }
        }
    }

    func remove(sessionID: String) {
        withLock { try? FileManager.default.removeItem(at: fileURL(for: sessionID)) }
    }

    /// Clear the board. Live sessions reappear on their next hook event.
    func removeAll() {
        withLock {
            for session in loadAll() { try? FileManager.default.removeItem(at: fileURL(for: session.id)) }
        }
    }

    /// Drop sessions whose last event came before `cutoff` — the last boot. Silence alone
    /// never removes a session: they are kept open for days and picked back up, so only
    /// SessionEnd, a reboot, or clearing the board takes one off. Returns how many went.
    @discardableResult
    func pruneSessions(lastEventBefore cutoff: Date) -> Int {
        withLock {
            let ended = loadAll().filter { $0.updatedAt < cutoff }
            for session in ended { try? FileManager.default.removeItem(at: fileURL(for: session.id)) }
            return ended.count
        }
    }

    // MARK: Private

    private static let fileNameAlphabet = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// Smallest positive slot no live session holds — called under the lock.
    private func nextFreeSlot() -> Int {
        let used = Set(loadAll().map(\.slot))
        var slot = 1
        while used.contains(slot) { slot += 1 }
        return slot
    }

    private func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
