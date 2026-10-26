import AppKit
import Observation
import os

/// Runs Cue's MCP server while Settings › MCP says agents may connect, and knows how an
/// agent is told where to find it.
@Observable
final class TaskMCPController {
    /// The socket is open.
    private(set) var isRunning = false
    /// Why it could not be opened, for Settings to show.
    private(set) var problem: String?
    /// Agents connected right now, oldest first.
    private(set) var clients: [Client] = []

    struct Client: Identifiable, Equatable {
        let id: UUID
        let name: String
        let version: String?
        let connectedAt: Date
    }

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let protocolHandler: TaskMCP
    @ObservationIgnored private var server: MCPServer?

    init(tasks: TaskStore, preferences: AppPreferences) {
        self.preferences = preferences
        protocolHandler = TaskMCP(store: tasks)
        protocolHandler.onClient = { [weak self] session, name, version in
            guard let self else { return }
            // An agent may initialise again on the same connection; keep its first moment.
            let since = clients.first { $0.id == session }?.connectedAt ?? .now
            clients.removeAll { $0.id == session }
            clients.append(Client(id: session, name: name, version: version, connectedAt: since))
        }
    }

    /// Starts or stops the server as the preference says, and again whenever it changes.
    func apply() {
        let enabled = withObservationTracking { preferences.tasksMCPEnabled } onChange: { [weak self] in
            Task { @MainActor in self?.apply() }
        }
        if enabled, server == nil {
            let handler = protocolHandler
            let server = MCPServer(handle: { handler.handle($1, session: $0) },
                                   sessionEnded: { [weak self] session in self?.clients.removeAll { $0.id == session } })
            do {
                try server.start()
                self.server = server
                problem = nil
            } catch {
                problem = "Cue couldn’t open its MCP socket: \(error.description)"
                Log.app.error("MCP: \(error.description, privacy: .public)")
            }
        } else if !enabled, let server {
            server.stop()
            self.server = nil
            clients.removeAll()
        }
        isRunning = server != nil
    }

    func tearDown() {
        server?.stop()
        server = nil
        clients.removeAll()
        isRunning = false
    }

    // MARK: - Connecting an agent

    /// The bridge an agent runs: `cue-mcp`, inside this copy of the app.
    static var bridgePath: String {
        Bundle.main.url(forResource: "cue-mcp", withExtension: nil)?.path
            ?? "/Applications/Cue.app/Contents/Resources/cue-mcp"
    }

    /// Whether this copy of Cue is in an Applications folder. The setup lines name the copy
    /// they were copied from; one run from Downloads or a build folder stops working when
    /// it is moved or rebuilt.
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory().components(separatedBy: "/Library/Containers/").first! + "/Applications/")
    }

    /// The bridge's path, ready to paste into a shell.
    static var bridgePathForShell: String { shellQuoted(bridgePath) }

    /// What to ask an agent first, on Settings › MCP.
    static let examplePrompts = [
        "What’s on my Cue task list?",
        "Pick the most urgent Cue task and work on it. When you’re done, set it to review and add a note saying what you did.",
        "Add a Cue task for each TODO comment in this project.",
    ]

    /// Adds Cue to Claude Code, for every project.
    static var claudeCodeCommand: String { "claude mcp add --scope user cue -- \(shellQuoted(bridgePath))" }

    /// Adds Cue to Codex.
    static var codexCommand: String { "codex mcp add cue -- \(shellQuoted(bridgePath))" }

    /// For any other client's JSON configuration (Claude Desktop, Cursor and the like).
    static var jsonConfiguration: String {
        """
        {
          "mcpServers": {
            "cue": { "command": "\(bridgePath)" }
          }
        }
        """
    }

    private static func shellQuoted(_ path: String) -> String {
        path.contains(where: { " '\"\\$`".contains($0) }) ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
    }
}
