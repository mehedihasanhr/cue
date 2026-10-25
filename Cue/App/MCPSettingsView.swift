import AppKit
import SwiftUI

// MARK: - MCP

/// Settings › MCP: letting AI agents use the task list, from nothing to connected.
///
/// The switch, whether it is working (and which agents are connected right now — the
/// proof a setup took), the steps for each common app with its line to copy, what an
/// agent can and cannot do, and what to try when it does not connect.
struct MCPSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(TaskMCPController.self) private var mcp: TaskMCPController?
    @State private var app: AgentApp = .claudeCode

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.mcp, enabled: $preferences.tasksMCPEnabled) {
            status
            if preferences.tasksMCPEnabled {
                setup
                abilities
                examples
                troubleshooting
            }
        }
    }

    // MARK: Status

    private var status: some View {
        SettingsGroup("Status", footer: mcp?.problem) {
            SettingsRow(serverTitle, subtitle: serverSubtitle, symbol: serverSymbol, tint: serverTint)
            if preferences.tasksMCPEnabled, let mcp, mcp.isRunning {
                if mcp.clients.isEmpty {
                    SettingsRow("No agent connected", subtitle: "Set one up below, then start a new session in it: it shows here while it’s connected.",
                                symbol: "person.crop.circle.badge.questionmark", tint: .gray)
                } else {
                    ForEach(mcp.clients) { client in
                        SettingsRow(client.name, subtitle: connectedSubtitle(client), symbol: "checkmark.circle.fill", tint: .green)
                    }
                }
            }
            if preferences.tasksMCPEnabled, !TaskMCPController.isInApplications {
                SettingsRow("Move Cue to Applications first",
                            subtitle: "Cue is running from \(abbreviated(Bundle.main.bundlePath)). The setup line names this copy, so it stops working once this copy is moved or replaced.",
                            symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private var serverTitle: String {
        guard preferences.tasksMCPEnabled else { return "Off" }
        return mcp?.isRunning == true ? "On" : "Not running"
    }

    private var serverSubtitle: String {
        guard preferences.tasksMCPEnabled else { return "Agents can’t reach your tasks. Turn it on with the switch above." }
        return mcp?.isRunning == true
            ? "Agents you set up can read and update your tasks while Cue is running. Cue opens by itself when one connects."
            : "Cue couldn’t start its MCP server."
    }

    private var serverSymbol: String { preferences.tasksMCPEnabled && mcp?.isRunning == true ? "dot.radiowaves.left.and.right" : "power" }
    private var serverTint: Color { preferences.tasksMCPEnabled && mcp?.isRunning == true ? .green : .gray }

    private func connectedSubtitle(_ client: TaskMCPController.Client) -> String {
        let since = "Connected \(client.connectedAt.formatted(.relative(presentation: .named)))"
        return client.version.map { "Version \($0) · \(since)" } ?? since
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Set up your AI app")
                    .font(SettingsFont.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("App", selection: $app) {
                    ForEach(AgentApp.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.leading, 12)
            VStack(spacing: 0) {
                ForEach(Array(app.steps.enumerated()), id: \.offset) { index, step in
                    SetupStepRow(number: index + 1, step: step)
                }
            }
            .padding(.bottom, -1)
            .background(SettingsPalette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: What agents can do

    private var abilities: some View {
        SettingsGroup("What agents can do") {
            SettingsRow("Read your tasks", subtitle: "List and search open tasks, read one in full, and see your projects.",
                        symbol: "eye.fill", tint: .blue)
            SettingsRow("Add and update tasks", subtitle: "Create tasks; change status, priority, title or project; add notes, like what they did.",
                        symbol: "square.and.pencil", tint: .green)
            SettingsRow("Nothing is deleted", subtitle: "Agents can’t delete tasks or projects. What they change shows in Cue straight away, and syncs like your own edits.",
                        symbol: "lock.fill", tint: .gray)
        }
    }

    // MARK: Examples

    private var examples: some View {
        SettingsGroup("Try asking") {
            ForEach(TaskMCPController.examplePrompts, id: \.self) { prompt in
                SettingsRow("“\(prompt)”") { CopyButton(text: prompt) }
            }
        }
    }

    // MARK: Troubleshooting

    private var troubleshooting: some View {
        SettingsGroup("If it doesn’t connect") {
            SettingsRow("Check the switch", subtitle: "MCP has to be on (top right). Status says On when Cue is ready.",
                        symbol: "power", tint: .gray)
            SettingsRow("Restart the AI app", subtitle: "Most apps read their MCP servers only when they start, or when a new session begins.",
                        symbol: "arrow.clockwise", tint: .blue)
            SettingsRow("Moved or reinstalled Cue?", subtitle: "Run the setup line again: it points at where Cue was when you copied it.",
                        symbol: "folder.badge.questionmark", tint: .orange)
            SettingsRow("Still nothing", subtitle: "In Terminal, run the line below. It should print nothing and wait; press Control-C to stop it. An error there says what’s wrong.",
                        symbol: "terminal", tint: .purple)
            CommandCell(text: TaskMCPController.bridgePathForShell)
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory().components(separatedBy: "/Library/Containers/").first ?? NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - The apps

/// The apps the setup steps cover. Anything else that speaks MCP takes the JSON.
private enum AgentApp: String, CaseIterable, Identifiable {
    case claudeCode, codex, claudeDesktop, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .claudeDesktop: "Claude Desktop"
        case .other: "Cursor & others"
        }
    }

    var steps: [SetupStep] {
        switch self {
        case .claudeCode:
            [
                SetupStep("Add Cue to Claude Code", detail: "In Terminal, run this once. It adds Cue for all your projects.",
                          command: TaskMCPController.claudeCodeCommand),
                SetupStep("Check it’s connected", detail: "This should list cue with ✔ Connected.", command: "claude mcp list"),
                SetupStep("Use it", detail: "Start a new Claude Code session and ask about your tasks. The first time it uses one of Cue’s tools, Claude Code asks you to allow it."),
            ]
        case .codex:
            [
                SetupStep("Add Cue to Codex", detail: "In Terminal, run this once.", command: TaskMCPController.codexCommand),
                SetupStep("Check it’s there", detail: "This should list cue.", command: "codex mcp list"),
                SetupStep("Use it", detail: "Start a new Codex session and ask about your tasks."),
            ]
        case .claudeDesktop:
            [
                SetupStep("Open Claude’s config", detail: "In the Claude app: Claude › Settings… › Developer › Edit Config. It shows claude_desktop_config.json in Finder; open it in a text editor."),
                SetupStep("Add Cue", detail: "Paste this in. If the file already has an \"mcpServers\" section, add just the \"cue\" line inside it.",
                          command: TaskMCPController.jsonConfiguration),
                SetupStep("Restart Claude", detail: "Quit Claude (⌘Q) and open it again. Cue’s tools appear under the tools button in a new chat."),
            ]
        case .other:
            [
                SetupStep("Find the app’s MCP settings", detail: "Cursor: Settings › MCP › Add new global MCP server (it opens ~/.cursor/mcp.json). Other apps: look for MCP or tools in their settings, or their mcp.json."),
                SetupStep("Add Cue", detail: "Paste this in, or add the \"cue\" line to an existing \"mcpServers\" section.",
                          command: TaskMCPController.jsonConfiguration),
                SetupStep("Reload", detail: "Save, then restart the app or reload its MCP servers. Cue should show as connected above."),
            ]
        }
    }
}

private struct SetupStep {
    let title: String
    let detail: String
    var command: String?

    init(_ title: String, detail: String, command: String? = nil) {
        self.title = title
        self.detail = detail
        self.command = command
    }
}

/// One numbered step, with its line to copy under it when it has one.
private struct SetupStepRow: View {
    let number: Int
    let step: SetupStep

    var body: some View {
        SettingsCell(vertical: 10) {
            HStack(alignment: .top, spacing: 14) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.purple, in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(SettingsFont.item)
                    Text(step.detail)
                        .font(SettingsFont.sub)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command = step.command {
                        CommandBlock(text: command)
                    }
                }
            }
        }
    }
}

/// A line to copy, on its own row of a group.
private struct CommandCell: View {
    let text: String

    var body: some View {
        SettingsCell(vertical: 10) { CommandBlock(text: text) }
    }
}

/// A command or snippet: monospaced, selectable, and a Copy button beside it.
private struct CommandBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Copies `text`, and says so for a moment.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}
