import Foundation

/// The coding agents whose sessions show on the island.
nonisolated enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// A profile's name from its folder: `.claude-work` is "work", `.claude` none.
    /// Any other folder goes by its own name.
    func profile(fromFolderName name: String) -> String? {
        var rest = Substring(name)
        if rest.hasPrefix(".") { rest = rest.dropFirst() }
        if rest.lowercased().hasPrefix(rawValue) { rest = rest.dropFirst(rawValue.count) }
        while let first = rest.first, "-_. ".contains(first) { rest = rest.dropFirst() }
        if rest.isEmpty { return name.hasPrefix(".\(rawValue)") || name == rawValue ? nil : name }
        return String(rest)
    }
}

// MARK: - JSON

/// Any JSON value, kept whole so a tool's input can go back to the agent unchanged
/// (with the answers to its question added).
nonisolated enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// A command given as one string or as its arguments.
    var commandLine: String? {
        if let string { return string }
        if let parts = array?.compactMap(\.string), !parts.isEmpty { return parts.joined(separator: " ") }
        return nil
    }

    /// Compact JSON, for a tool input nothing better describes.
    var compact: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Events

/// One hook event, as the hook script forwards it: what the agent sent on stdin, and
/// what the script adds (which agent, the process that ran it, the terminal).
nonisolated struct AgentEvent: Sendable, Equatable {
    enum Name: String, Sendable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case notification = "Notification"
        case stop = "Stop"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case other
    }

    var agent: AgentKind
    var name: Name
    var sessionID: String
    var cwd: String?
    var toolName: String?
    var toolInput: JSONValue?
    /// Claude Code's own "don't ask again" offers for a permission request.
    var suggestions: JSONValue?
    var prompt: String?
    /// The last reply (Stop) or the notification's text.
    var message: String?
    var notificationType: String?
    /// The profile the hook was installed in ("work" for `~/.claude-work`).
    var profile: String?
    /// Set when a subagent did it (Claude Code tags its events with the subagent's id).
    var subagentID: String?
    var subagentType: String?
    /// What the session leaves running: Claude Code lists it on Stop and SubagentStop
    /// (`[{id, type: shell|subagent, status, description, command?}]`).
    var backgroundTasks: [JSONValue]?
    /// The hook script itself: while it runs, its question is still open.
    var hookPID: Int32 = 0
    /// The process that ran the hook (the agent, or a shell it started).
    var parentPID: Int32
    /// `TERM_PROGRAM` of the agent's terminal.
    var terminal: String?
    /// The terminal pane the agent runs in ("wezterm:3", "tmux:%1"), where the hook
    /// script can type an answer only the agent's own dialog takes.
    var pane: String?
    /// What started the agent (`CLAUDE_CODE_ENTRYPOINT`): "claude-desktop", "cli", …
    var entry: String?

    /// A session of the Claude desktop app: no terminal, and its own dialogs.
    var isDesktop: Bool { entry == "claude-desktop" }

    private struct Envelope: Decodable {
        struct Cue: Decodable {
            var agent: String
            var profile: String?
            var pid: Int32?
            var ppid: Int32?
            var term: String?
            var pane: String?
            var entry: String?
        }
        var cue: Cue
        var event: JSONValue
    }

    /// Parses one line from the hook script; nil for anything else.
    init?(line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
              let agent = AgentKind(rawValue: envelope.cue.agent),
              let sessionID = envelope.event["session_id"]?.string ?? envelope.event["thread-id"]?.string,
              let name = envelope.event["hook_event_name"]?.string
        else { return nil }
        let event = envelope.event
        self.agent = agent
        self.name = Name(rawValue: name) ?? .other
        self.sessionID = sessionID
        cwd = event["cwd"]?.string
        toolName = event["tool_name"]?.string
        toolInput = event["tool_input"]
        suggestions = event["permission_suggestions"]
        prompt = event["prompt"]?.string
        message = event["last_assistant_message"]?.string ?? event["message"]?.string
        notificationType = event["notification_type"]?.string
        subagentID = event["agent_id"]?.string
        subagentType = event["agent_type"]?.string
        backgroundTasks = event["background_tasks"]?.array
        profile = envelope.cue.profile.flatMap { agent.profile(fromFolderName: $0) }
        hookPID = envelope.cue.pid ?? 0
        parentPID = envelope.cue.ppid ?? 0
        let term = envelope.cue.term?.trimmingCharacters(in: .whitespaces)
        terminal = term?.isEmpty == false ? term : nil
        pane = envelope.cue.pane.flatMap { $0.isEmpty ? nil : $0 }
        entry = envelope.cue.entry.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(agent: AgentKind, name: Name, sessionID: String, cwd: String? = nil, toolName: String? = nil, toolInput: JSONValue? = nil,
         suggestions: JSONValue? = nil, prompt: String? = nil, message: String? = nil, notificationType: String? = nil,
         subagentID: String? = nil, subagentType: String? = nil, backgroundTasks: [JSONValue]? = nil,
         parentPID: Int32 = 0, terminal: String? = nil, pane: String? = nil) {
        self.subagentID = subagentID
        self.subagentType = subagentType
        self.backgroundTasks = backgroundTasks
        self.agent = agent
        self.name = name
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.suggestions = suggestions
        self.prompt = prompt
        self.message = message
        self.notificationType = notificationType
        self.parentPID = parentPID
        self.terminal = terminal
        self.pane = pane
    }

    /// Only a permission request waits for an answer; everything else is news.
    var wantsAnswer: Bool { name == .permissionRequest }
}

// MARK: - Sessions

nonisolated struct AgentSession: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Working on a prompt.
        case running
        /// Asking the user something (a permission, a question, a plan).
        case waiting
        /// Done with its turn; waiting for the next prompt.
        case idle
    }

    var id: String { "\(agent.rawValue):\(sessionID)" }
    let agent: AgentKind
    let sessionID: String
    /// The agent profile it runs under, when it is not the default one.
    var profile: String?
    var cwd: String?
    var state: State = .idle
    /// What it is doing ("Bash · npm test") or last said.
    var activity: String?
    /// What the session is about: the start of its first prompt ("fix the auth
    /// bug"). Tells apart two sessions in the same folder.
    var title: String?
    var startedAt: Date
    var updatedAt: Date
    /// When the current (or last) prompt was sent: how long it has been at work.
    var turnStartedAt: Date?
    /// It has used a tool since the prompt: "Working" rather than "Thinking".
    var usedTool = false
    /// When it last finished its turn (or started, never prompted); nil while at work.
    var finishedAt: Date?
    var parentPID: Int32
    var terminal: String?
    /// Work it has handed off and that is still going: subagents and background
    /// shell commands, in the order they started.
    var workers: [AgentWorker] = []

    /// The folder's name: what tells two sessions apart at a glance.
    var project: String {
        guard let cwd, !cwd.isEmpty else { return agent.shortName }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Something a session has set working beside it: a subagent, or a shell command
/// left running in the background.
nonisolated struct AgentWorker: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case subagent, shell }

    let id: String
    let kind: Kind
    /// What it was asked to do ("Run the tests"), or its type when nothing says.
    var title: String
    /// The subagent's type ("general-purpose"), or the shell command.
    var detail: String?
    /// What it is doing right now ("Bash · npm test").
    var activity: String?
    /// Runs on after the session's turn ends.
    var background: Bool
    let startedAt: Date
}

/// The running sessions, kept up to date from hook events. Pure, so it is tested
/// without a socket or the island.
nonisolated struct AgentSessionBook: Equatable, Sendable {
    private(set) var sessions: [AgentSession] = []
    /// Agent calls made but whose subagent has not started yet, per session: their
    /// description and whether they run in the background, oldest first. A starting
    /// subagent takes the first one of its type.
    private var pendingSubagents: [String: [(type: String, title: String, background: Bool)]] = [:]

    static func == (a: AgentSessionBook, b: AgentSessionBook) -> Bool { a.sessions == b.sessions }

    /// Sessions that have not been heard from for this long are dropped, in case
    /// their end was never reported (a closed terminal tab).
    static let staleAfter: TimeInterval = 6 * 60 * 60

    mutating func apply(_ event: AgentEvent, at now: Date) {
        if event.name == .sessionEnd {
            sessions.removeAll { $0.agent == event.agent && $0.sessionID == event.sessionID }
            return
        }
        var session = sessions.first { $0.agent == event.agent && $0.sessionID == event.sessionID }
            ?? AgentSession(agent: event.agent, sessionID: event.sessionID, startedAt: now, updatedAt: now, parentPID: event.parentPID)
        session.updatedAt = now
        if let cwd = event.cwd { session.cwd = cwd }
        if let profile = event.profile { session.profile = profile }
        if event.parentPID > 0 { session.parentPID = event.parentPID }
        if let terminal = event.terminal { session.terminal = terminal }
        // What a subagent does is its own, not the session's: it updates its row only.
        if let subagentID = event.subagentID {
            applySubagent(event, id: subagentID, to: &session, at: now)
            store(session)
            return
        }
        if event.name == .preToolUse, event.toolName == "Agent" || event.toolName == "Task", let input = event.toolInput {
            let type = input["subagent_type"]?.string ?? "general-purpose"
            let title = input["description"]?.string ?? type
            pendingSubagents[session.id, default: []].append((type, title, input["run_in_background"]?.bool ?? false))
        }
        if event.name == .preToolUse, event.toolName == "Bash", event.toolInput?["run_in_background"]?.bool == true,
           let command = event.toolInput?["command"]?.commandLine {
            // Shown at once; its real id comes with the next list of background tasks.
            let title = event.toolInput?["description"]?.string ?? command
            session.workers.append(AgentWorker(id: "pending:\(command)", kind: .shell, title: title, detail: command, background: true, startedAt: now))
        }
        if let tasks = event.backgroundTasks { syncBackground(tasks, in: &session, at: now) }
        switch event.name {
        case .sessionStart:
            session.state = .idle
        case .userPromptSubmit:
            session.state = .running
            session.turnStartedAt = now
            session.usedTool = false
            session.activity = event.prompt.map(Self.oneLine)
            if session.title == nil, let prompt = event.prompt { session.title = Self.title(from: prompt) }
        case .preToolUse, .postToolUse:
            // A late status event must not hide a question that is still open.
            if session.state != .waiting || event.name == .postToolUse { session.state = .running }
            if let tool = event.toolName {
                session.activity = AgentToolSummary(tool: tool, input: event.toolInput).line
                session.usedTool = true
                // A plan to approve or a question to answer waits on the user even when
                // no permission request comes with it (bypass mode skips that hook).
                if event.name == .preToolUse, tool == "ExitPlanMode" || tool == "AskUserQuestion" { session.state = .waiting }
            }
        case .permissionRequest:
            session.state = .waiting
        case .notification:
            if event.notificationType == "idle_prompt" { session.state = .idle }
        case .stop:
            session.state = .idle
            // A subagent that does not run in the background ends with the turn, even
            // when its own stop was never reported.
            session.workers.removeAll { $0.kind == .subagent && !$0.background }
            if let message = event.message, let line = Self.readableLine(message) { session.activity = line }
        case .sessionEnd, .subagentStart, .subagentStop, .other:
            break
        }
        // The clock starts when the turn ends; a later idle reminder must not restart it.
        if session.state != .idle {
            session.finishedAt = nil
        } else if session.finishedAt == nil || event.name == .stop || event.name == .sessionStart {
            session.finishedAt = now
        }
        store(session)
    }

    private mutating func store(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    private mutating func applySubagent(_ event: AgentEvent, id: String, to session: inout AgentSession, at now: Date) {
        switch event.name {
        case .subagentStop:
            session.workers.removeAll { $0.id == id }
            if let tasks = event.backgroundTasks { syncBackground(tasks, in: &session, at: now) }
            return
        case .permissionRequest:
            session.state = .waiting
        default:
            break
        }
        if !session.workers.contains(where: { $0.id == id }) {
            let type = event.subagentType ?? "subagent"
            var pending = pendingSubagents[session.id] ?? []
            let match = pending.firstIndex { $0.type == type }.map { pending.remove(at: $0) }
            pendingSubagents[session.id] = pending
            session.workers.append(AgentWorker(id: id, kind: .subagent, title: match?.title ?? type, detail: type,
                                               background: match?.background ?? false, startedAt: now))
        }
        if event.name == .preToolUse, let tool = event.toolName, let index = session.workers.firstIndex(where: { $0.id == id }) {
            session.workers[index].activity = AgentToolSummary(tool: tool, input: event.toolInput).line
        }
    }

    /// Brings the background shell commands and subagents in line with Claude Code's
    /// own list, so one that ended without reporting its stop does not linger.
    private func syncBackground(_ tasks: [JSONValue], in session: inout AgentSession, at now: Date) {
        let running = tasks.filter { ($0["status"]?.string ?? "running") == "running" }
        let shells = running.filter { $0["type"]?.string == "shell" }
        let subagents = running.filter { $0["type"]?.string == "subagent" }
        session.workers.removeAll { worker in
            switch worker.kind {
            case .shell: !shells.contains { $0["id"]?.string == worker.id }
            case .subagent: worker.background && !subagents.contains { $0["id"]?.string == worker.id }
            }
        }
        for task in shells {
            guard let id = task["id"]?.string, !session.workers.contains(where: { $0.id == id }) else { continue }
            let command = task["command"]?.string
            session.workers.append(AgentWorker(id: id, kind: .shell, title: task["description"]?.string ?? command ?? "Background command",
                                               detail: command, background: true, startedAt: now))
        }
        // A background subagent listed here but never seen starting (Cue started later).
        for task in subagents {
            guard let id = task["id"]?.string, !session.workers.contains(where: { $0.id == id }) else { continue }
            session.workers.append(AgentWorker(id: id, kind: .subagent, title: task["description"]?.string ?? "Subagent",
                                               detail: task["agent_type"]?.string, background: true, startedAt: now))
        }
    }

    /// Back from waiting once its question is answered (or withdrawn).
    mutating func resume(_ sessionID: String, agent: AgentKind, stillWaiting: Bool) {
        guard let index = sessions.firstIndex(where: { $0.agent == agent && $0.sessionID == sessionID }),
              sessions[index].state == .waiting, !stillWaiting
        else { return }
        sessions[index].state = .running
    }

    mutating func remove(where shouldRemove: (AgentSession) -> Bool) {
        sessions.removeAll(where: shouldRemove)
    }

    /// How long a finished session stays on the list before it leaves on its own.
    static let finishedLinger: TimeInterval = 60

    /// Drops sessions that finished their turn a minute ago and have nothing left
    /// running in the background; a new prompt brings one back. Returns their ids.
    mutating func pruneFinished(at now: Date) -> [String] {
        let done = sessions.filter { session in
            guard session.state == .idle, session.workers.isEmpty, let finishedAt = session.finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) >= Self.finishedLinger
        }.map(\.id)
        if !done.isEmpty { sessions.removeAll { done.contains($0.id) } }
        return done
    }

    mutating func pruneStale(at now: Date) {
        sessions.removeAll { now.timeIntervalSince($0.updatedAt) > Self.staleAfter }
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: .whitespaces).prefix(160))
    }

    /// A short name for a session from one of its prompts, or nil for a prompt that
    /// says nothing about the work: a slash command, or text the app wrapped in tags.
    static func title(from prompt: String) -> String? {
        var line = oneLine(prompt)
        guard let first = line.first, first != "/", first != "<" else { return nil }
        // Pasted images show up as "[Image #1]"; they are not words.
        line = line.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
        line = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 48 ? String(line.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// The reply's first line as plain text, or nil when the reply is data rather than
    /// prose: Codex ends its own background turns (follow-up suggestions, titles) with
    /// raw JSON such as `{"suggestions":[]}`, which must not replace the real reply.
    static func readableLine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "{" || first == "[",
           (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
            return nil
        }
        // Markdown marks read as noise in one line of plain text.
        var line = oneLine(trimmed)
        while let hash = line.first, hash == "#" || hash == ">" { line = String(line.dropFirst()) }
        for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
}

// MARK: - Requests

/// One question from an agent: run this tool, pick from these options, approve this plan.
nonisolated struct AgentRequest: Identifiable, Equatable, Sendable {
    nonisolated struct Question: Equatable, Sendable, Identifiable {
        nonisolated struct Option: Equatable, Sendable, Identifiable {
            var id: String { label }
            let label: String
            let description: String?
        }

        var id: String { question }
        let question: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool
    }

    enum Kind: Equatable, Sendable {
        case permission(AgentToolSummary)
        /// AskUserQuestion: one or more multiple-choice questions.
        case questions([Question])
        /// ExitPlanMode: the plan to approve.
        case plan(String)
    }

    let id: UUID
    let agent: AgentKind
    let sessionID: String
    let kind: Kind
    let toolName: String
    let toolInput: JSONValue
    let suggestions: JSONValue?
    let receivedAt: Date
    /// The agent's own app when the session runs there (Codex's): the island asks
    /// first, and can hand the question back to the app to ask instead.
    var appName: String?
    /// The terminal pane the agent runs in, when the hook script can type there.
    let pane: String?

    var sessionKey: String { "\(agent.rawValue):\(sessionID)" }

    /// Whether `event` shows this question was answered somewhere else (the
    /// terminal): the very tool it asked about has run. A question or a plan is the
    /// only one of its kind open at a time, and its tool may come back with the
    /// answers added, so its name is enough; a permission matches on its input too,
    /// so a parallel tool finishing does not settle another's question.
    func isSettled(by event: AgentEvent) -> Bool {
        guard event.name == .postToolUse, event.agent == agent, event.sessionID == sessionID,
              event.toolName == toolName else { return false }
        switch kind {
        case .questions, .plan: return true
        case .permission: return event.toolInput == toolInput
        }
    }

    /// Whether "always" means anything: Claude Code offers its own rules, and Cue
    /// remembers Codex's for the rest of the session.
    var canAllowAlways: Bool {
        switch kind {
        case .questions: false
        case .plan: suggestions?.array?.isEmpty == false
        case .permission: agent == .codex || suggestions?.array?.isEmpty == false
        }
    }

    /// Whether a plan can be approved from here. Claude Code takes a plan's approval
    /// only from its own dialog, so Cue needs the pane to press the dialog's key in.
    var canApprovePlan: Bool {
        guard case .plan = kind else { return false }
        return agent == .claude && pane != nil
    }

    init?(_ event: AgentEvent, id: UUID = UUID(), at now: Date) {
        guard event.name == .permissionRequest, let toolName = event.toolName else { return nil }
        let input = event.toolInput ?? .object([:])
        self.id = id
        agent = event.agent
        sessionID = event.sessionID
        self.toolName = toolName
        toolInput = input
        suggestions = event.suggestions
        pane = event.pane
        receivedAt = now
        switch toolName {
        case "AskUserQuestion":
            let questions = (input["questions"]?.array ?? []).compactMap(Self.question)
            guard !questions.isEmpty else { return nil }
            kind = .questions(questions)
        case "ExitPlanMode":
            kind = .plan(input["plan"]?.string ?? "")
        default:
            kind = .permission(AgentToolSummary(tool: toolName, input: input))
        }
    }

    private static func question(_ value: JSONValue) -> Question? {
        guard let text = value["question"]?.string else { return nil }
        let options = (value["options"]?.array ?? []).compactMap { option -> Question.Option? in
            guard let label = option["label"]?.string else { return nil }
            return Question.Option(label: label, description: option["description"]?.string)
        }
        return Question(question: text, header: value["header"]?.string, options: options, multiSelect: value["multiSelect"]?.bool ?? false)
    }
}

/// What the user decided, from the island.
nonisolated enum AgentDecision: Equatable, Sendable {
    case allowOnce
    case allowAlways
    case deny
    /// Approves a plan through Claude Code's own dialog: its first option (switch to
    /// bypass permissions, or auto-accept edits — what Return picks there), or the
    /// second, approving with edits still asked about one by one.
    case approvePlan(reviewEdits: Bool)
    /// The chosen labels (or typed text) for each question, by its text.
    case answers([String: [String]])
}

nonisolated enum AgentReply {
    /// The hook's stdout for `decision`: the agent reads it as the user's answer.
    static func json(for request: AgentRequest, _ decision: AgentDecision) -> Data {
        if case .approvePlan(let reviewEdits) = decision {
            // Not JSON: the script reads this as keys to press in the agent's pane, and
            // gives the agent no answer, so its dialog stays up to take them.
            return Data((AgentHooks.keysReplyPrefix + (reviewEdits ? "2" : "1")).utf8)
        }
        var verdict: [String: JSONValue] = [:]
        switch decision {
        case .allowOnce:
            verdict["behavior"] = .string("allow")
        case .allowAlways:
            verdict["behavior"] = .string("allow")
            // Codex has no rules to hand back; Cue remembers the grant itself.
            if request.agent == .claude, let suggestions = request.suggestions { verdict["updatedPermissions"] = suggestions }
        case .deny:
            verdict["behavior"] = .string("deny")
            verdict["message"] = .string(request.toolName == "ExitPlanMode" ? "The user wants to keep planning." : "The user denied this from Cue.")
        case .approvePlan:
            break
        case .answers(let answers):
            verdict["behavior"] = .string("allow")
            var input: [String: JSONValue] = if case .object(let object) = request.toolInput { object } else { [:] }
            input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            verdict["updatedInput"] = .object(input)
        }
        let output: JSONValue = .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": .object(verdict),
        ])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(output)) ?? Data()
    }
}

// MARK: - Tool summary

/// A tool call in a line: the tool and what it touches ("Bash", "npm test").
nonisolated struct AgentToolSummary: Equatable, Sendable {
    let tool: String
    let detail: String?
    /// The agent's own few words for the call ("Run the tests"), when it gave some.
    let purpose: String?
    /// An AskUserQuestion call's first question.
    let question: String?
    /// What a Codex "always" grant matches: the same tool with the same command.
    let grantKey: String

    init(tool: String, input: JSONValue?) {
        self.tool = Self.displayName(tool)
        let input = input ?? .null
        self.detail = Self.detail(of: input).map { String($0.prefix(600)) }
        let purpose = input["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.purpose = purpose?.isEmpty == false ? purpose : nil
        question = input["questions"]?.array?.first?["question"]?.string.map { String($0.prefix(120)) }
        grantKey = "\(tool)|\(input["command"]?.commandLine ?? (tool == "apply_patch" ? "" : input.compact))"
    }

    /// What the agent is doing, in words where it can: its own description of the
    /// call ("Clean up asking panel"), or the tool as a verb ("Reading …/a/b.swift"),
    /// and the raw command only when nothing better is known.
    var line: String {
        if let purpose { return String(purpose.prefix(120)) }
        switch tool {
        case "ExitPlanMode": return "Plan ready for review"
        case "AskUserQuestion": return question ?? "Has a question for you"
        default: break
        }
        guard let detail, !detail.isEmpty else { return tool }
        let first = String((detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? detail).prefix(120))
        switch tool {
        case "Read": return "Reading \(first)"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Edit files": return "Editing \(first)"
        case "Grep", "Glob": return "Searching for \(first)"
        case "WebFetch": return "Reading \(first)"
        case "WebSearch": return "Searching the web for \(first)"
        default: return "\(tool) · \(first)"
        }
    }

    /// The one thing that says what the call does: its command, file, address or query.
    private static func detail(of input: JSONValue) -> String? {
        if let command = input["command"]?.commandLine { return command }
        for key in ["file_path", "path", "notebook_path"] {
            if let path = input[key]?.string { return shortPath(path) }
        }
        for key in ["url", "pattern", "query", "description"] {
            if let text = input[key]?.string { return text }
        }
        if let patch = input["patch"]?.string ?? input["input"]?.string { return patchFiles(patch) }
        return input == .null || input == .object([:]) ? nil : input.compact
    }

    /// `mcp__server__tool` reads as "server · tool".
    private static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool == "apply_patch" ? "Edit files" : tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]) · \(parts[1...].joined(separator: " "))" : tool
    }

    private static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(3).joined(separator: "/") : path
    }

    /// The files an `apply_patch` touches, from its "*** Update File:" lines.
    private static func patchFiles(_ patch: String) -> String {
        let files = patch.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return shortPath(String(line.dropFirst(marker.count)))
            }
            return nil
        }
        return files.isEmpty ? String(patch.prefix(200)) : files.joined(separator: ", ")
    }
}
