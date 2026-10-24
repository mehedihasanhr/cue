import AppKit
import Observation
import os

/// Runs Cue's MCP server while Settings › Tasks says agents may connect, and knows how an
/// agent is told where to find it.
@Observable
final class TaskMCPController {
    /// The socket is open.
    private(set) var isRunning = false
    /// Why it could not be opened, for Settings to show.
    private(set) var problem: String?

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let protocolHandler: TaskMCP
    @ObservationIgnored private var server: MCPServer?

    init(tasks: TaskStore, preferences: AppPreferences) {
        self.preferences = preferences
        protocolHandler = TaskMCP(store: tasks)
    }

    /// Starts or stops the server as the preference says, and again whenever it changes.
    func apply() {
        let enabled = withObservationTracking { preferences.tasksMCPEnabled } onChange: { [weak self] in
            Task { @MainActor in self?.apply() }
        }
        if enabled, server == nil {
            let handler = protocolHandler
            let server = MCPServer { handler.handle($0) }
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
        }
        isRunning = server != nil
    }

    func tearDown() {
        server?.stop()
        server = nil
        isRunning = false
    }

    // MARK: - Connecting an agent

    /// The bridge an agent runs: `cue-mcp`, inside this copy of the app.
    static var bridgePath: String {
        Bundle.main.url(forResource: "cue-mcp", withExtension: nil)?.path
            ?? "/Applications/Cue.app/Contents/Resources/cue-mcp"
    }

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
