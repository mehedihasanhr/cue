import AppKit
import os
import Foundation

/// The coding-agent sessions running on this Mac, and the questions they are
/// waiting on. Fed by the hook script through `AgentServer`; the island shows it
/// and answers from it.
@MainActor
@Observable
final class AgentStore {
    private(set) var book = AgentSessionBook()
    /// Questions waiting for an answer, oldest first.
    private(set) var requests: [AgentRequest] = []

    /// Sessions with the ones that need the user first, then the busiest.
    var sessions: [AgentSession] {
        book.sessions.sorted { a, b in
            let rank: (AgentSession) -> Int = { session in
                if self.requests.contains(where: { $0.sessionKey == session.id }) { return 0 }
                return switch session.state {
                case .waiting: 0
                case .running: 1
                case .idle: 2
                }
            }
            return (rank(a), a.startedAt) < (rank(b), b.startedAt)
        }
    }

    func requests(for session: AgentSession) -> [AgentRequest] {
        requests.filter { $0.sessionKey == session.id }
    }

    /// Whether there is anything to show on the closed island.
    var isActive: Bool { !book.sessions.isEmpty }

    /// Whether any agent is working, or waiting on the user, right now.
    var isBusy: Bool { !requests.isEmpty || book.sessions.contains { $0.state != .idle || !$0.workers.isEmpty } }

    /// Whether the island is there to answer from; when it is not, every question
    /// goes straight back to the terminal.
    @ObservationIgnored var canAsk: () -> Bool = { true }
    /// A new question arrived; the island opens for it.
    @ObservationIgnored var onRequest: (AgentRequest) -> Void = { _ in }
    /// The last open question was answered or withdrawn.
    @ObservationIgnored var onRequestsCleared: () -> Void = {}
    /// A session finished its turn: how long the turn took.
    @ObservationIgnored var onFinished: (AgentSession, Duration) -> Void = { _, _ in }
    /// When each session's current turn began, by session id.
    @ObservationIgnored private var turnStarts: [String: Date] = [:]

    @ObservationIgnored private var connections: [UUID: AgentConnection] = [:]
    /// The hook script each request came from: once it is gone, the agent took
    /// the answer in the terminal.
    @ObservationIgnored private var hookPIDs: [UUID: Int32] = [:]
    @ObservationIgnored private var hookTimer: Timer?
    /// Codex "always" grants, which Codex cannot keep itself: session key → tool and command.
    @ObservationIgnored private var codexGrants: [String: Set<String>] = [:]
    /// The agent process of each session, for noticing it has gone.
    @ObservationIgnored private var agentPIDs: [String: Int32] = [:]
    /// The app each session runs in (its terminal, or the agent's app), by session id.
    private(set) var hosts: [String: AgentHost] = [:]
    @ObservationIgnored private var pruneTimer: Timer?

    init() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    // MARK: Events

    func receive(_ event: AgentEvent, from connection: AgentConnection) {
        Log.app.debug("Agent sessions: \(event.agent.rawValue, privacy: .public) \(event.name.rawValue, privacy: .public)")
        let key = "\(event.agent.rawValue):\(event.sessionID)"
        let wasWorking = book.sessions.first { $0.id == key }.map { $0.state != .idle } ?? false
        book.apply(event, at: .now)
        if event.subagentID == nil {
            if event.name == .userPromptSubmit { turnStarts[key] = .now }
            if event.name == .stop, wasWorking, let session = book.sessions.first(where: { $0.id == key }) {
                let start = turnStarts.removeValue(forKey: key) ?? session.updatedAt
                onFinished(session, .seconds(Date.now.timeIntervalSince(start)))
            }
        }
        if agentPIDs[key] == nil, event.parentPID > 0, let pid = AgentProcess.agentPID(from: event.parentPID) {
            agentPIDs[key] = pid
        }
        if hosts[key] == nil, event.name != .sessionEnd, event.parentPID > 0, let app = AgentProcess.hostApp(of: event.parentPID) {
            hosts[key] = AgentHost(app: app)
        }
        if event.name == .stop, event.subagentID == nil {
            // A finished session leaves the list a minute later; check right on time
            // rather than at the next round of the timer.
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentSessionBook.finishedLinger + 0.5) { [weak self] in
                self?.prune()
            }
        }
        switch event.name {
        case .permissionRequest:
            ask(event, from: connection)
        case .userPromptSubmit, .stop, .sessionEnd:
            // The turn moved on: anything still open was answered in the terminal.
            withdraw { $0.sessionKey == key }
            if event.name == .sessionEnd {
                turnStarts[key] = nil
                codexGrants[key] = nil
                agentPIDs[key] = nil
                hosts[key] = nil
            }
        case .postToolUse:
            // Answered in the terminal: the tool it asked about has run. The hook is
            // still waiting (Claude Code no longer stops it), so let it go too.
            withdraw { $0.isSettled(by: event) }
        default:
            // An answer given in the terminal shows as the hook hanging up (see
            // `hungUp`): tools run side by side, so a tool finishing says nothing
            // about another one's question.
            break
        }
    }

    private func ask(_ event: AgentEvent, from connection: AgentConnection) {
        guard var request = AgentRequest(event, at: .now), canAsk() else {
            connection.reply()
            return
        }
        if request.agent == .codex, case .permission(let summary) = request.kind,
           codexGrants[request.sessionKey]?.contains(summary.grantKey) == true {
            connection.reply(AgentReply.json(for: request, .allowOnce))
            book.resume(request.sessionID, agent: request.agent, stillWaiting: false)
            return
        }
        // Asked on the island first. Codex's own app shows no approval while the hook
        // holds the question, so the card can hand it back to the app (with Klik
        // closed, the hook lets go at once and the app asks as usual).
        if request.agent == .codex, let host = hosts[request.sessionKey], Self.isAgentApp(host) {
            request.appName = host.name
        }
        connections[request.id] = connection
        if event.hookPID > 0 { hookPIDs[request.id] = event.hookPID }
        requests.append(request)
        Log.app.info("Agent sessions: \(request.agent.rawValue, privacy: .public) asks about \(request.toolName, privacy: .public)")
        watchHooks()
        onRequest(request)
    }

    /// Whether a session's host is the agent's own app rather than a terminal.
    private static func isAgentApp(_ host: AgentHost) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: host.pid)?.bundleIdentifier else { return false }
        return bundle.hasPrefix("com.openai.")
    }

    /// Checks every second whether the hooks behind open questions still run; the
    /// agent stops a hook once its question is answered in the terminal.
    private func watchHooks() {
        guard hookTimer == nil, AgentProcess.canSeeProcesses else { return }
        hookTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHooks() }
        }
    }

    private func checkHooks() {
        let gone = Set(hookPIDs.filter { !AgentProcess.isRunning($0.value) }.keys)
        if !gone.isEmpty { withdraw { gone.contains($0.id) } }
        if requests.isEmpty {
            hookTimer?.invalidate()
            hookTimer = nil
        }
    }

    // MARK: Answers

    func answer(_ request: AgentRequest, _ decision: AgentDecision) {
        guard let connection = connections[request.id] else { return }
        connection.reply(AgentReply.json(for: request, decision))
        if decision == .allowAlways, request.agent == .codex, case .permission(let summary) = request.kind {
            codexGrants[request.sessionKey, default: []].insert(summary.grantKey)
        }
        finish { $0.id == request.id }
    }

    /// Leaves the question to the terminal and brings it forward.
    func answerInTerminal(_ request: AgentRequest) {
        // Codex waits on the hook and shows nothing meanwhile: let it go, so the
        // agent asks in its own window. Claude Code's prompt is already showing.
        if request.agent == .codex { withdraw { $0.id == request.id } }
        if let session = book.sessions.first(where: { $0.id == request.sessionKey }) { focus(session) }
    }

    /// Brings `app` to the front. Klik is never the active app when the island is
    /// clicked, and macOS ignores `activate()` from an app in the background, so
    /// the running app is "opened" again, which always brings it forward.
    private static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Log.app.error("Agent sessions: couldn’t bring \(url.lastPathComponent, privacy: .public) forward: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Brings forward the app the session runs in.
    func focus(_ session: AgentSession) {
        if let host = hosts[session.id], let app = NSRunningApplication(processIdentifier: host.pid), !app.isTerminated {
            Self.bringForward(app)
            return
        }
        if let app = AgentProcess.hostApp(of: agentPIDs[session.id] ?? session.parentPID) {
            hosts[session.id] = AgentHost(app: app)
            Self.bringForward(app)
        } else if let terminal = session.terminal {
            let names = ["Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2", "vscode": "com.microsoft.VSCode",
                         "WarpTerminal": "dev.warp.Warp-Stable", "ghostty": "com.mitchellh.ghostty",
                         "WezTerm": "com.github.wez.wezterm"]
            if let id = names[terminal], let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                Self.bringForward(app)
            }
        }
    }

    /// Removes requests the user can no longer answer here, and lets their hooks go.
    private func withdraw(_ matches: (AgentRequest) -> Bool) {
        for request in requests where matches(request) {
            connections[request.id]?.reply()
        }
        finish(matches)
    }

    private func finish(_ matches: (AgentRequest) -> Bool) {
        let done = requests.filter(matches)
        guard !done.isEmpty else { return }
        for request in done {
            connections[request.id] = nil
            hookPIDs[request.id] = nil
        }
        requests.removeAll(where: matches)
        for request in done {
            book.resume(request.sessionID, agent: request.agent, stillWaiting: requests.contains { $0.sessionKey == request.sessionKey })
        }
        if requests.isEmpty { onRequestsCleared() }
    }

    // MARK: Housekeeping

    /// Drops sessions whose agent has exited without saying so (a closed tab).
    private func prune() {
        let gone = Set(agentPIDs.filter { !AgentProcess.isRunning($0.value) }.keys)
        if !gone.isEmpty {
            withdraw { gone.contains($0.sessionKey) }
            book.remove { gone.contains($0.id) }
            for key in gone {
                agentPIDs[key] = nil
                codexGrants[key] = nil
            }
        }
        forgetKeys(book.pruneFinished(at: .now))
        let before = book.sessions.map(\.id)
        book.pruneStale(at: .now)
        if book.sessions.count != before.count {
            let kept = Set(book.sessions.map(\.id))
            withdraw { !kept.contains($0.sessionKey) }
        }
    }

    /// Lets every waiting hook go (Klik is quitting, or the feature was turned off).
    func releaseAll() {
        withdraw { _ in true }
    }

    /// Drops one session the user closed by hand (its end was never reported). It
    /// comes back with the next event if the agent is still at work.
    func dismiss(_ session: AgentSession) {
        let key = session.id
        withdraw { $0.sessionKey == key }
        book.remove { $0.id == key }
        forgetKeys([key])
    }

    /// Forgets one agent profile's sessions (it was disconnected).
    func forget(_ agent: AgentKind, profile: String?) {
        let keys = Set(book.sessions.filter { $0.agent == agent && $0.profile == profile }.map(\.id))
        withdraw { keys.contains($0.sessionKey) }
        book.remove { keys.contains($0.id) }
        forgetKeys(keys)
    }

    /// What is kept about sessions beside the book, for ones that have left it.
    private func forgetKeys(_ keys: some Sequence<String>) {
        for key in keys {
            agentPIDs[key] = nil
            codexGrants[key] = nil
            hosts[key] = nil
            turnStarts[key] = nil
        }
    }

    /// Forgets everything (the feature was turned off).
    func reset() {
        releaseAll()
        book = AgentSessionBook()
        agentPIDs.removeAll()
        hosts.removeAll()
        codexGrants.removeAll()
    }
}

/// The app a session runs in, as the island shows it: its name and icon.
struct AgentHost: Equatable {
    let pid: Int32
    let name: String
    let icon: NSImage?

    init(app: NSRunningApplication) {
        pid = app.processIdentifier
        name = app.localizedName ?? "its app"
        icon = app.icon
    }

    static func == (a: AgentHost, b: AgentHost) -> Bool { a.pid == b.pid }
}
