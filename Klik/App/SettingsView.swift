import BackgroundKit
import SwiftUI

/// UserDefaults keys for user preferences read outside SwiftUI.
enum PreferenceKey {
    static let includeCursor = "capture.includeCursor"
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(CaptureLibrary.self) private var library
    @Environment(AppPreferences.self) private var preferences
    @Environment(SyncFolder.self) private var sync: SyncFolder?
    @AppStorage(PreferenceKey.includeCursor) private var includeCursor = false
    @State private var launchError: String?

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.general) {
            SettingsGroup {
                SettingsRow("Launch Klik at login") {
                    Toggle("Launch at login", isOn: launchAtLoginBinding).toggleStyle(.switch)
                }
                if model.launchAtLogin == .requiresApproval {
                    SettingsRow("Approval needed", subtitle: "System Settings › General › Login Items", symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Open Login Items") { PermissionManager.openLoginItemsSettings() }
                    }
                }
                if let launchError {
                    SettingsRow(launchError, symbol: "xmark.octagon.fill", tint: .red)
                }
            }

            if let sync {
                SettingsGroup("Sync") {
                    SettingsRow(sync.url?.lastPathComponent ?? "Not syncing",
                                subtitle: sync.url?.path(percentEncoded: false),
                                symbol: "arrow.triangle.2.circlepath", tint: .blue) {
                        HStack(spacing: 8) {
                            Button(sync.isOn ? "Change…" : "Choose Folder…") { sync.choose() }
                            if sync.isOn {
                                Button("Stop") { sync.turnOff() }
                            }
                        }
                    }
                }
            }

            SettingsGroup("Menu bar icon") {
                SettingsRow("Icon") {
                    MenuBarIconPicker()
                }
                SettingsRow("Show in Dock", subtitle: "Off, Klik lives in the menu bar alone.") {
                    Toggle("Show in Dock", isOn: $preferences.showInDock).toggleStyle(.switch)
                }
            }

            SettingsGroup("Storage") {
                SettingsRow(library.folderIsCustom ? library.folderURL.lastPathComponent : "Pictures › Klik",
                            subtitle: library.folderURL.path(percentEncoded: false), symbol: "folder", tint: .orange) {
                    HStack(spacing: 8) {
                        Button("Choose…") { library.chooseFolder() }
                        Button(action: { library.revealFolder() }) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Reveal in Finder")
                    }
                }
                if library.folderIsCustom {
                    SettingsRow("Default folder", subtitle: "Pictures › Klik") {
                        Button("Use Default Folder") { library.useDefaultFolder() }
                    }
                }
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin != .disabled },
            set: { enabled in
                do {
                    try LaunchAtLogin.setEnabled(enabled)
                    launchError = nil
                } catch {
                    launchError = error.localizedDescription
                }
                model.launchAtLogin = LaunchAtLogin.state
            }
        )
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.appearance) {
            SettingsGroup("Theme") {
                SettingsPreviewPicker(title: "Theme",
                                      selection: $preferences.appearance, options: AppPreferences.Appearance.allCases, label: \.title) { option in
                    AppearancePreview(appearance: option)
                }
            }
        }
    }
}

/// A desktop in the light, the dark, or half of each: wallpaper, menu bar and
/// a window with its sidebar — the way System Settings shows appearances.
private struct AppearancePreview: View {
    let appearance: AppPreferences.Appearance

    var body: some View {
        switch appearance {
        case .light: Desktop(dark: false)
        case .dark: Desktop(dark: true)
        case .system:
            ZStack {
                Desktop(dark: false)
                Desktop(dark: true).clipShape(HalfMask())
            }
        }
    }

    private struct Desktop: View {
        let dark: Bool

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: dark ? [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.05, green: 0.05, blue: 0.14)]
                                 : [Color(red: 0.55, green: 0.75, blue: 1), Color(red: 0.85, green: 0.7, blue: 0.98)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // The menu bar.
                Rectangle()
                    .fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 2.5) {
                            ForEach(0..<4, id: \.self) { _ in
                                Capsule().fill(dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45)).frame(width: 5, height: 1.5)
                            }
                        }
                        .padding(.leading, 5)
                    }
                // The window, with a sidebar and a few lines of content.
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle().fill(dark ? Color.white.opacity(0.35) : Color.black.opacity(0.2)).frame(width: 3, height: 3)
                            }
                        }
                        .padding(.bottom, 3)
                        ForEach([0.9, 0.7, 0.8], id: \.self) { width in
                            Capsule().fill(dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)).frame(width: 18 * width, height: 2)
                        }
                    }
                    .padding(5)
                    .frame(width: 30, alignment: .topLeading)
                    .background(dark ? Color(white: 0.17) : Color(white: 0.93))
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6)).frame(width: 22, height: 2.5)
                        ForEach([1.0, 0.75, 0.9, 0.6], id: \.self) { width in
                            Capsule().fill(dark ? Color.white.opacity(0.25) : Color.black.opacity(0.14)).frame(width: 34 * width, height: 2)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(dark ? Color(white: 0.12) : Color.white)
                }
                .frame(width: 74, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(dark ? 0.55 : 0.2), radius: 5, y: 3)
                .padding(.top, 14)
            }
        }
    }

    /// The lower-right half, split from the top-right corner to the bottom-left.
    nonisolated private struct HalfMask: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Island & panels

/// Settings › Agents: Claude Code and Codex sessions on the island.
struct AgentSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(AgentConnector.self) private var agents: AgentConnector?

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.agents) {
            SettingsGroup("Agent sessions") {
                SettingsRow("Show agent sessions", subtitle: "Claude Code and Codex sessions beside the notch. Hover to see them; allow, deny and answer their questions from the island.") {
                    Toggle("Agent sessions", isOn: $preferences.agentSessionsEnabled).toggleStyle(.switch)
                }
                SettingsRow("Open when an agent asks", subtitle: "Otherwise the closed island pulses until you hover it.") {
                    Toggle("Open when asked", isOn: $preferences.agentAutoOpen).toggleStyle(.switch)
                }
                .disabled(!preferences.agentSessionsEnabled)
                if let agents {
                    ForEach(AgentKind.allCases, id: \.self) { agent in
                        ForEach(agents.links(for: agent)) { link in
                            AgentLinkRow(link: link, connector: agents)
                        }
                        AgentConnectRow(agent: agent, connector: agents)
                    }
                    .disabled(!preferences.agentSessionsEnabled)
                }
            }
            .disabled(!preferences.dynamicIslandEnabled)
            if !preferences.dynamicIslandEnabled {
                Text("Turn on the Dynamic Island (Settings › Island) to see agent sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        }
    }
}

/// One connected agent folder: its profile, where its hooks are, and Disconnect.
private struct AgentLinkRow: View {
    let link: AgentConnector.Link
    let connector: AgentConnector

    var body: some View {
        SettingsRow(link.profile.map { "\(link.agent.name) · \($0)" } ?? link.agent.name, subtitle: subtitle,
                    symbol: link.agent == .claude ? "asterisk" : "terminal", tint: link.agent == .claude ? .orange : .blue) {
            Button("Disconnect") { connector.disconnect(link.id) }
        }
    }

    private var subtitle: String {
        if let problem = link.problem { return problem }
        let home = AgentConnector.home.path
        let folder = link.folder.path.hasPrefix(home) ? "~" + link.folder.path.dropFirst(home.count) : link.folder.path
        var text = "Connected through \(folder)/\(AgentHooks.settingsFile(for: link.agent))."
        // Codex skips any hook the user has not reviewed, silently: until then no
        // Codex session reaches the island.
        if link.agent == .codex { text += " Codex runs it only once you trust it: in a terminal, run codex, type /hooks, and trust Klik’s hooks (the Codex app uses the same setting)." }
        return text
    }
}

/// Connects an agent's folder: the first one, or another profile.
private struct AgentConnectRow: View {
    let agent: AgentKind
    let connector: AgentConnector

    var body: some View {
        let another = !connector.links(for: agent).isEmpty
        SettingsRow(another ? "Another \(agent.name) profile" : agent.name,
                    subtitle: another ? "Each profile has its own folder (like ~/.\(agent.rawValue)-work); connect each one whose sessions should show."
                                      : "Not connected. Choose its folder (\(agent == .claude ? "~/.claude" : "~/.codex")) to add Klik’s hook.",
                    symbol: agent == .claude ? "asterisk" : "terminal", tint: agent == .claude ? .orange : .blue) {
            Button(another ? "Add…" : "Connect…") { connector.connect(agent) }
        }
    }
}

struct IslandSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.island) {
            SettingsGroup("Dynamic Island") {
                SettingsRow("Show the Dynamic Island") {
                    Toggle("Show the island", isOn: $preferences.dynamicIslandEnabled).toggleStyle(.switch)
                }
                SettingsRow("Also show a pill on displays without a notch") {
                    Toggle("Pill on plain displays", isOn: $preferences.dynamicIslandOnPlainDisplays).toggleStyle(.switch)
                }
                .disabled(!preferences.dynamicIslandEnabled)
                SettingsRow("Notch background", subtitle: "Black beside the notch while closed.") {
                    Toggle("Notch background", isOn: $preferences.islandNotchBackground).toggleStyle(.switch)
                }
                .disabled(!preferences.dynamicIslandEnabled)
            }

            SettingsGroup("Opening and closing") {
                SettingsRow("Open on") {
                    Picker("Open on", selection: $preferences.islandOpenMode) {
                        ForEach(AppPreferences.IslandOpenMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if preferences.islandOpenMode == .hover {
                    SettingsRow("Hover delay") {
                        SecondsSlider(value: $preferences.islandHoverDelay, range: 0...1.5, step: 0.05, zero: "At once")
                    }
                }
                SettingsRow("Close when the pointer leaves") {
                    Toggle("Close on leave", isOn: $preferences.islandCloseOnLeave).toggleStyle(.switch)
                }
                if preferences.islandCloseOnLeave {
                    SettingsRow("Close delay") {
                        SecondsSlider(value: $preferences.islandCloseDelay, range: 0.1...3, step: 0.05, zero: "At once")
                    }
                }
                SettingsRow("Opens on") {
                    Picker("Opens on", selection: $preferences.islandOpensOn) {
                        Text("Last used").tag(IslandTab?.none)
                        Divider()
                        ForEach(IslandTab.allCases, id: \.self) { Text($0.title).tag(IslandTab?.some($0)) }
                    }
                    .fixedSize()
                }
            }
            .disabled(!preferences.dynamicIslandEnabled)

            SettingsGroup("What it shows") {
                SettingsRow("Flash new captures") {
                    Toggle("Flash captures", isOn: $preferences.islandFlashCaptures).toggleStyle(.switch)
                }
                if preferences.islandFlashCaptures {
                    SettingsRow("For") {
                        SecondsSlider(value: $preferences.islandFlashDuration, range: 0.5...5, step: 0.1, zero: nil)
                    }
                }
                SettingsRow("Statuses", subtitle: "Pastes, uploads, focus sessions and saved snippets.") {
                    Toggle("Statuses", isOn: $preferences.islandStatuses).toggleStyle(.switch)
                }
                SettingsRow("Preview opens", subtitle: "A card's eye: in the cards' place, or in a pane under the island with the cards still there. ← → move between cards.") {
                    Picker("Preview", selection: $preferences.islandPreview) {
                        ForEach(AppPreferences.IslandPreview.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if preferences.islandPreview == .pane {
                    SettingsRow("Open the preview on hover") {
                        Toggle("Preview on hover", isOn: $preferences.islandPreviewOnHover).toggleStyle(.switch)
                    }
                    if preferences.islandPreviewOnHover {
                        SettingsRow("Hover delay") {
                            SecondsSlider(value: $preferences.islandPreviewHoverDelay, range: 0...2, step: 0.05, zero: "At once")
                        }
                    }
                }
                SettingsRow("Animation") {
                    Picker("Animation", selection: $preferences.islandAnimation) {
                        ForEach(AppPreferences.IslandAnimation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .disabled(!preferences.dynamicIslandEnabled)

            SettingsGroup("Panels") {
                SettingsPreviewPicker(title: "Open panels at", subtitle: "The library panel and the quick task.",
                                      selection: $preferences.panelPosition, options: PanelPosition.allCases, label: { $0 == .pointer ? "Pointer" : $0.title }, columns: 4, tileWidth: 92, inPopover: true) { position in
                    PanelPositionPreview(position: position)
                }
                SettingsRow("Grid columns", subtitle: "Cards per row in the library panel's grid.") {
                    Stepper(value: $preferences.panelColumns, in: AppPreferences.panelColumnRange) {
                        Text("\(preferences.panelColumns)").monospacedDigit().frame(width: 20, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// A slider of seconds with its value beside it ("0.25 s", or a word for zero).
private struct SecondsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// What to show at the low end instead of "0 s".
    let zero: String?

    private var snapped: Binding<Double> {
        Binding {
            value
        } set: { proposed in
            let steps = ((proposed - range.lowerBound) / step).rounded()
            value = min(range.upperBound, max(range.lowerBound, range.lowerBound + steps * step))
        }
    }

    private var caption: String {
        if let zero, value <= range.lowerBound { return zero }
        return String(format: "%.2g s", value)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Continuous, and snapped here: the system's stepped slider draws a tick mark
            // per step, a dotted line under the track.
            Slider(value: snapped, in: range).frame(width: 150)
            Text(caption)
                .font(SettingsFont.sub)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Snippets

struct SnippetSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.snippets, enabled: $preferences.snippetsEnabled) {
            SettingsGroup("Snippets") {
                SettingsRow("Keyword trigger") {
                    TextField("", text: $preferences.snippetPrefix, prompt: Text(";"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                }
                if !PermissionManager.hasAccessibilityAccess {
                    SettingsRow("Needs Accessibility access", symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Grant…") {
                            PermissionManager.requestAccessibilityAccess()
                            PermissionManager.revealAppInFinder()
                        }
                    }
                }
            }
            .disabled(!preferences.snippetsEnabled)
        }
    }
}

// MARK: - Notes

struct NotesSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(NoteStore.self) private var notes: NoteStore?
    @State private var notionCheck: String?
    @State private var checking = false

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.notes, enabled: $preferences.notesEnabled) {
            SettingsGroup("Floating note") {
                SettingsRow("Glass", subtitle: "Frosted keeps the text easy to read; clear shows what is behind the note.") {
                    HStack(spacing: 8) {
                        Text("Frosted").font(SettingsFont.sub).foregroundStyle(.secondary)
                        Slider(value: $preferences.notesPanelClarity, in: 0...1).frame(width: 150)
                        Text("Clear").font(SettingsFont.sub).foregroundStyle(.secondary)
                    }
                }
                if preferences.notesPanelSize != nil {
                    SettingsRow("Size", subtitle: "Opens at the size it was last dragged to.") {
                        Button("Use Default Size") { preferences.notesPanelSize = nil }
                    }
                }
            }
            .disabled(!preferences.notesEnabled)

            SettingsGroup("Where notes live") {
                if let notes {
                    SettingsRow(notes.folderIsCustom ? notes.folderURL.lastPathComponent : "Klik's own folder",
                                subtitle: notes.folderURL.path(percentEncoded: false), symbol: "folder", tint: .yellow) {
                        HStack(spacing: 8) {
                            Button("Choose…") { notes.chooseFolder() }
                            Button(action: { notes.revealFolder() }) {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Reveal in Finder")
                        }
                    }
                    if notes.folderIsCustom {
                        SettingsRow("Default folder") {
                            Button("Use Default Folder") { notes.useDefaultFolder() }
                        }
                    }
                }
            }
            .disabled(!preferences.notesEnabled)

            SettingsGroup("Obsidian") {
                sendRow(.obsidian)
                SettingsRow("Vault name") {
                    TextField("Vault", text: $preferences.notesObsidianVault, prompt: Text("Last opened"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }
            .disabled(!preferences.notesEnabled)

            SettingsGroup("Apple Notes") {
                sendRow(.appleNotes)
                SettingsRow("Folder") {
                    TextField("Folder", text: $preferences.notesAppleNotesFolder, prompt: Text("Notes"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }
            .disabled(!preferences.notesEnabled)

            SettingsGroup("Notion") {
                sendRow(.notion)
                SettingsRow("Integration secret") {
                    SecureField("Secret", text: $preferences.notesNotionToken, prompt: Text("ntn_…"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                SettingsRow("Page or database", subtitle: "Its link, or its id.") {
                    TextField("Parent", text: $preferences.notesNotionParent, prompt: Text("https://www.notion.so/…"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                SettingsRow("Connection", subtitle: notionCheck) {
                    Button(checking ? "Checking…" : "Check") { checkNotion() }
                        .disabled(checking || preferences.notesNotionToken.isEmpty)
                }
            }
            .disabled(!preferences.notesEnabled)
        }
    }

    /// "Send new notes here": on once the destination is set up.
    private func sendRow(_ destination: NoteDestination) -> some View {
        let setUp = NoteSharing.isSetUp(destination, preferences: preferences)
        let binding = Binding(
            get: { preferences.notesSendTo.contains(destination.rawValue) },
            set: { on in if on { preferences.notesSendTo.insert(destination.rawValue) } else { preferences.notesSendTo.remove(destination.rawValue) } }
        )
        return SettingsRow("Send new notes to \(destination.title)", subtitle: setUp ? nil : "Fill in the rows below first.") {
            Toggle("Send", isOn: binding).toggleStyle(.switch)
        }
        .disabled(!setUp)
    }

    private func checkNotion() {
        checking = true
        notionCheck = nil
        let token = preferences.notesNotionToken
        Task { @MainActor in
            do {
                let name = try await NoteSharing.notionCheck(token: token)
                notionCheck = "Connected as \(name)"
            } catch {
                notionCheck = error.localizedDescription
            }
            checking = false
        }
    }
}

// MARK: - Tasks

struct TasksSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(TaskSync.self) private var sync: TaskSync?
    @State private var serverCheck: String?
    @State private var checking = false
    @State private var testing = false

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.tasks) {
            SettingsGroup("Remote server") {
                SettingsRow("Server URL") {
                    TextField("URL", text: $preferences.tasksServerURL, prompt: Text("https://example.com/klik/sync"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                SettingsRow("Token", subtitle: "Sent as Authorization: Bearer. Kept in your Keychain.") {
                    SecureField("Token", text: $preferences.tasksServerToken, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                SettingsRow("Connection", subtitle: serverCheck) {
                    Button(checking ? "Checking…" : "Check") { checkServer() }
                        .disabled(checking || sync?.serverURL == nil)
                }
            }

            SettingsGroup("Sync") {
                SettingsRow("Keep tasks in step with the server") {
                    Toggle("Sync", isOn: $preferences.tasksSyncEnabled).toggleStyle(.switch)
                }
                .disabled(sync?.serverURL == nil)
                SettingsRow("Also every") {
                    Picker("Interval", selection: $preferences.tasksSyncInterval) {
                        Text("Only after changes").tag(0)
                        Text("Minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("Hour").tag(60)
                    }
                    .frame(width: 180)
                }
                .disabled(!preferences.tasksSyncEnabled)
                if let sync {
                    SettingsRow(syncTitle(sync), subtitle: sync.lastError, symbol: sync.lastError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill",
                                tint: sync.lastError == nil ? .green : .orange) {
                        Button(sync.syncing ? "Syncing…" : "Sync Now") { Task { await sync.sync() } }
                            .disabled(sync.syncing || sync.serverURL == nil)
                    }
                }
            }

            SettingsGroup("Webhook") {
                SettingsRow("Webhook URL") {
                    TextField("URL", text: $preferences.tasksWebhookURL, prompt: Text("https://example.com/hooks/klik"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                SettingsRow("Secret", subtitle: "Kept in your Keychain.") {
                    SecureField("Secret", text: $preferences.tasksWebhookSecret, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                SettingsRow("Send events") {
                    Toggle("Send", isOn: $preferences.tasksWebhookEnabled).toggleStyle(.switch)
                }
                .disabled(sync?.webhookURL == nil)
                SettingsRow("Events") {
                    HStack(spacing: 14) {
                        ForEach(AppPreferences.taskWebhookEventKinds, id: \.kind) { entry in
                            Toggle(entry.title, isOn: Binding(
                                get: { preferences.tasksWebhookEvents.contains(entry.kind) },
                                set: { on in if on { preferences.tasksWebhookEvents.insert(entry.kind) } else { preferences.tasksWebhookEvents.remove(entry.kind) } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .disabled(!preferences.tasksWebhookEnabled)
                if let sync {
                    SettingsRow("Last event", subtitle: sync.lastWebhook ?? "None sent yet") {
                        Button(testing ? "Sending…" : "Send Test") { sendTest(sync) }
                            .disabled(testing || sync.webhookURL == nil)
                    }
                }
            }
        }
    }

    private func syncTitle(_ sync: TaskSync) -> String {
        guard let last = sync.lastSync else { return "Never synced" }
        let taken = sync.lastTaken == 0 ? "" : " · took \(sync.lastTaken) from the server"
        return "Last sync \(last.formatted(.relative(presentation: .named)))\(taken)"
    }

    private func checkServer() {
        guard let sync else { return }
        checking = true
        serverCheck = nil
        Task { @MainActor in
            do { serverCheck = try await sync.check() } catch { serverCheck = error.localizedDescription }
            checking = false
        }
    }

    private func sendTest(_ sync: TaskSync) {
        testing = true
        Task { @MainActor in
            do { try await sync.sendTest() } catch { FeedbackHUD.show("Webhook failed", symbol: "exclamationmark.triangle", subtitle: error.localizedDescription) }
            testing = false
        }
    }
}

// MARK: - Colors

struct ColorSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.colors, enabled: $preferences.colorPickerEnabled) {
            SettingsGroup("Color picker") {
                SettingsRow("Copy picked colors as") {
                    Picker("Color format", selection: $preferences.colorFormat) {
                        ForEach(ColorFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
            }
            .disabled(!preferences.colorPickerEnabled)
        }
    }
}

/// A desktop with Klik's panel where the position puts it: the same little
/// wallpaper and menu bar as the theme pictures, and the panel as a pane of dark
/// glass with its search line and a few rows.
struct PanelPositionPreview: View {
    let position: PanelPosition

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.22, blue: 0.4), Color(red: 0.08, green: 0.08, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(height: 5)
            GeometryReader { proxy in
                let panel = CGSize(width: proxy.size.width * 0.36, height: proxy.size.height * 0.46)
                let center = point(in: proxy.size, panel: panel)
                pane(size: panel)
                    .position(center)
                if position == .pointer {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                        .position(x: center.x + panel.width * 0.42, y: center.y + panel.height * 0.42)
                }
            }
        }
    }

    /// The panel: dark glass, a search line, rows.
    private func pane(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Capsule().fill(Color.white.opacity(0.28)).frame(height: 3.5)
            ForEach([0.9, 0.65, 0.8], id: \.self) { width in
                Capsule().fill(Color.white.opacity(0.14)).frame(width: (size.width - 8) * width, height: 2)
            }
        }
        .padding(4)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(white: 0.1).opacity(0.92), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    private func point(in size: CGSize, panel: CGSize) -> CGPoint {
        let inset: CGFloat = 5
        let left = inset + panel.width / 2, right = size.width - inset - panel.width / 2
        let top = inset + 5 + panel.height / 2, bottom = size.height - inset - panel.height / 2
        let midX = size.width / 2, midY = size.height / 2 + 2
        switch position {
        case .pointer, .center: return CGPoint(x: midX, y: midY)
        case .top: return CGPoint(x: midX, y: top)
        case .bottom: return CGPoint(x: midX, y: bottom)
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }
}

// MARK: - Capture

struct CaptureSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(OCREngines.self) private var engines: OCREngines?
    @AppStorage(PreferenceKey.includeCursor) private var includeCursor = false
    @State private var checkingCloud = false
    @State private var cloudCheck: String?

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.capture) {
            SettingsGroup {
                SettingsRow("After a capture", subtitle: "Either way it is on the clipboard and in the island.") {
                    Picker("After a capture", selection: $preferences.afterCapture) {
                        ForEach(AppPreferences.AfterCapture.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            captureText

            SettingsGroup("Full screen") {
                SettingsRow("Include mouse pointer") {
                    Toggle("Include pointer", isOn: $includeCursor).toggleStyle(.switch)
                }
            }

            SettingsGroup("Sound") {
                SettingsRow("Play a sound after each capture") {
                    Toggle("Play a sound", isOn: $preferences.soundEnabled).toggleStyle(.switch)
                }
                SettingsRow("Sound", symbol: "speaker.wave.2.fill", tint: .orange) {
                    HStack(spacing: 8) {
                        Picker("Sound", selection: $preferences.sound) {
                            Text(AppPreferences.Sound.shutter.title).tag(AppPreferences.Sound.shutter)
                            Divider()
                            ForEach(AppPreferences.Sound.systemNames, id: \.self) { name in
                                Text(name).tag(AppPreferences.Sound.system(name))
                            }
                            if let url = preferences.customSoundURL {
                                Divider()
                                Text(url.lastPathComponent).tag(AppPreferences.Sound.custom)
                            }
                        }
                        .frame(width: 180)
                        .onChange(of: preferences.sound) { _, new in preferences.play(new) }
                        Button {
                            preferences.play(preferences.sound)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .help("Preview")
                        Button("Choose File…") { preferences.chooseCustomSound() }
                    }
                }
                .disabled(!preferences.soundEnabled)
            }
        }
    }

    // MARK: Capture text

    @ViewBuilder
    private var captureText: some View {
        @Bindable var preferences = preferences
        SettingsGroup("Capture text") {
            SettingsRow("Language", subtitle: engineNote, symbol: "text.viewfinder", tint: .green) {
                SettingsLanguagePicker(tags: $preferences.ocrLanguages, availability: availability)
                    .onChange(of: preferences.ocrLanguages) { _, new in engines?.prepare(for: new) }
            }
            if let pack = pendingPack, let engines {
                SettingsRow(pack.displayName, subtitle: packNote(for: pack), symbol: "arrow.down.circle.fill", tint: .blue) {
                    switch engines.packs.state(of: pack.code) {
                    case .missing, .failed:
                        Button("Download") { engines.packs.download(pack.code) }
                    case .downloading:
                        ProgressView().controlSize(.small)
                    case .ready:
                        Button("Remove") { engines.packs.remove(pack.code) }
                    }
                }
            }
            SettingsRow("Also recognise English", subtitle: "For screens that mix the two.") {
                Toggle("Also English", isOn: alsoEnglish).toggleStyle(.switch)
            }
            .disabled(preferences.ocrLanguages.isEmpty)
            SettingsRow("Say so when the text isn't in that language",
                        subtitle: "Klik copies nothing rather than the wrong alphabet.") {
                Toggle("Check the script", isOn: $preferences.ocrChecksScript).toggleStyle(.switch)
            }
            .disabled(preferences.ocrLanguages.isEmpty)
        }

        cloudEngine
    }

    @ViewBuilder
    private var cloudEngine: some View {
        @Bindable var preferences = preferences
        SettingsGroup("Cloud engine") {
            SettingsRow("Use a cloud service",
                        subtitle: "For languages this Mac can't read, or when you want the best accuracy.") {
                Toggle("Use a cloud service", isOn: $preferences.ocrCloudEnabled).toggleStyle(.switch)
            }
            SettingsRow("Service") {
                Picker("Service", selection: $preferences.ocrCloudProvider) {
                    ForEach(CloudOCRConfiguration.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 220)
            }
            .disabled(!preferences.ocrCloudEnabled)
            SettingsRow("API key", subtitle: "Kept in your keychain.") {
                SecureField("API key", text: $preferences.ocrCloudSecret,
                            prompt: Text(preferences.ocrCloudProvider.keyPrompt))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }
            .disabled(!preferences.ocrCloudEnabled)
            if preferences.ocrCloudProvider == .model {
                SettingsRow("Endpoint") {
                    TextField("Endpoint", text: $preferences.ocrCloudEndpoint,
                              prompt: Text("https://…/v1/chat/completions"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                .disabled(!preferences.ocrCloudEnabled)
                SettingsRow("Model") {
                    TextField("Model", text: $preferences.ocrCloudModel, prompt: Text("claude-… · gpt-…"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                .disabled(!preferences.ocrCloudEnabled)
            }
            SettingsRow("Use it even for languages this Mac can read",
                        subtitle: "Otherwise it is only asked when nothing here can read the language.") {
                Toggle("Prefer the cloud", isOn: $preferences.ocrPreferCloud).toggleStyle(.switch)
            }
            .disabled(!preferences.ocrCloudEnabled)
            SettingsRow("Connection", subtitle: cloudCheck) {
                Button(checkingCloud ? "Checking…" : "Check") { checkCloud() }
                    .disabled(checkingCloud || preferences.ocrCloudSecret.isEmpty)
            }
            .disabled(!preferences.ocrCloudEnabled)
        }
    }

    private func checkCloud() {
        guard let engines else { return }
        checkingCloud = true
        cloudCheck = nil
        Task {
            let result = await engines.checkCloud()
            checkingCloud = false
            cloudCheck = result
        }
    }

    /// Named from the routing decision itself, so what this says and what actually
    /// happens cannot drift apart.
    private var engineNote: String {
        switch OCRRouter.route(preferences.ocrSettings, availability: availability) {
        case .success(let route) where route.detectsLanguage:
            return "Apple Vision picks the language for you."
        case .success(let route):
            switch route.engine {
            case .vision, .tesseract: return "Read here on the Mac by \(route.engine.title)."
            case .cloud: return "Sent to \(preferences.ocrSettings.cloud?.provider.title ?? "a cloud service")."
            }
        case .failure(let reason):
            return reason.errorDescription ?? "Klik can't read this one yet."
        }
    }

    /// The pack the chosen language needs, when it needs one.
    private var pendingPack: (code: String, displayName: String)? {
        guard let language = preferences.ocrLanguages.first.flatMap(OCRLanguageCatalog.language(for:)),
              !OCRLanguageCatalog.isVisionSupported(language),
              let code = language.tesseractCode
        else { return nil }
        return (code, language.displayName)
    }

    private func packNote(for pack: (code: String, displayName: String)) -> String {
        guard let engines else { return "" }
        switch engines.packs.state(of: pack.code) {
        case .ready: return "Installed. Read here on the Mac."
        case .downloading: return "Downloading…"
        case .failed(_, let offline):
            return offline ? "Klik is offline." : "The download failed."
        case .missing:
            return TesseractLanguagePacks.sizeDescription(for: pack.code).map { "\($0), downloaded once." } ?? "Downloaded once."
        }
    }

    private func availability(_ id: OCREngineID, _ language: OCRLanguage) -> OCREngineAvailability {
        if let engines { return engines.availability(id, language) }
        return id == .vision && OCRLanguageCatalog.isVisionSupported(language) ? .ready : .unsupported
    }

    /// English alongside the chosen language, for a screen that mixes them.
    private var alsoEnglish: Binding<Bool> {
        Binding(
            get: { preferences.ocrLanguages.contains { OCRLanguage($0).base == "en" } },
            set: { on in
                var tags = preferences.ocrLanguages
                guard let primary = tags.first, OCRLanguage(primary).base != "en" else { return }
                tags.removeAll { OCRLanguage($0).base == "en" }
                if on { tags.append("en-US") }
                preferences.ocrLanguages = tags
            }
        )
    }
}

// MARK: - Menu bar icon

/// A button showing the icon in use; it opens a popover of every icon to pick from.
private struct MenuBarIconPicker: View {
    @Environment(AppPreferences.self) private var preferences
    @State private var open = false

    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 6), count: 6)

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                current
                    .frame(width: 20, height: 20)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .frame(height: 28)
            .background(SettingsPalette.pill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsPalette.edge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose the menu bar icon")
        .accessibilityLabel("Menu bar icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                iconCell(selected: preferences.icon == .mark) {
                    KlikMarkView().frame(width: 15, height: 15)
                } action: {
                    preferences.icon = .mark
                    open = false
                }
                .help("Klik")
                ForEach(AppPreferences.Icon.symbols, id: \.self) { name in
                    iconCell(selected: preferences.icon == .symbol(name)) {
                        Image(systemName: name).font(.system(size: 15, weight: .medium))
                    } action: {
                        preferences.icon = .symbol(name)
                        open = false
                    }
                    .help(name)
                }
            }
            .padding(12)
        }
    }

    /// The icon in use, as the menu bar shows it.
    @ViewBuilder
    private var current: some View {
        switch preferences.icon {
        case .mark:
            KlikMarkView()
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 14, weight: .medium))
        case .custom:
            if let url = preferences.customIconURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").font(.system(size: 14, weight: .medium))
            }
        }
    }

    private func iconCell(selected: Bool, @ViewBuilder content: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 40, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : SettingsPalette.edge)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Time & prayer

struct TimeSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(PrayerClock.self) private var clock: PrayerClock?
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.time, enabled: $preferences.timeEnabled) {
            SettingsGroup("Time on the island") {
                SettingsRow("Show the time every") {
                    Picker("Interval", selection: $preferences.timeStatusInterval) {
                        ForEach(AppPreferences.timeIntervals, id: \.self) { minutes in
                            Text(Self.intervalTitle(minutes)).tag(minutes)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Preview") {
                    Button("Show on the Island") { clock?.preview() }
                }
            }
            .disabled(!preferences.timeEnabled)

            SettingsGroup("Prayer times") {
                SettingsRow("Prayer times", subtitle: "Computed on this Mac from your location.") {
                    Toggle("Prayer times", isOn: $preferences.prayerTimesEnabled).toggleStyle(.switch)
                }
                SettingsRow("Calculation method") {
                    Picker("Method", selection: $preferences.prayerMethod) {
                        ForEach(CalculationMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(!preferences.prayerTimesEnabled)
                SettingsRow("Asr") {
                    Picker("Asr", selection: $preferences.prayerMadhab) {
                        ForEach(Madhab.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(!preferences.prayerTimesEnabled)
                SettingsRow("Announce prayers on the island", subtitle: "Each prayer as it begins, and the forbidden times.") {
                    Toggle("Announce prayers", isOn: $preferences.prayerAnnouncements).toggleStyle(.switch)
                }
                .disabled(!preferences.prayerTimesEnabled)
            }
            .disabled(!preferences.timeEnabled)

            SettingsGroup("Where") {
                SettingsRow("Location") {
                    Picker("Location", selection: $preferences.prayerLocationMode) {
                        ForEach(AppPreferences.PrayerLocationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                if preferences.prayerLocationMode == .manual {
                    SettingsRow("Coordinates") {
                        HStack(spacing: 8) {
                            TextField("Latitude", text: $latitude, prompt: Text("Latitude (−90…90)")).frame(width: 140)
                            TextField("Longitude", text: $longitude, prompt: Text("Longitude (−180…180)")).frame(width: 150)
                            Button("Use") { applyManual() }
                                .disabled(Double(latitude) == nil || Double(longitude) == nil)
                        }
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyManual)
                    }
                } else {
                    SettingsRow(clock?.placeDescription ?? "—", symbol: "location.fill", tint: .blue) {
                        Button("Locate Now") { clock?.locate() }
                    }
                }
            }
            .disabled(!preferences.timeEnabled || !preferences.prayerTimesEnabled)

            if preferences.timeEnabled, preferences.prayerTimesEnabled, let clock, let today = clock.today {
                SettingsGroup("Today") {
                    ForEach(today.ordered, id: \.prayer) { entry in
                        adjustmentRow(entry.prayer, time: entry.time)
                    }
                    if preferences.prayerAdjustments.values.contains(where: { $0 != 0 }) {
                        SettingsRow("Adjustments") {
                            Button("Reset") { preferences.prayerAdjustments = [:] }
                        }
                    }
                }
            }
        }
        .onAppear {
            latitude = preferences.prayerManualPlace.latitude == 0 ? "" : String(preferences.prayerManualPlace.latitude)
            longitude = preferences.prayerManualPlace.longitude == 0 ? "" : String(preferences.prayerManualPlace.longitude)
            // The status this tab configures, on the island, while it is being chosen.
            if preferences.timeEnabled { clock?.preview() }
        }
    }

    /// A prayer's time with a ± minutes stepper.
    private func adjustmentRow(_ prayer: Prayer, time: Date) -> some View {
        let offset = Binding(
            get: { preferences.prayerAdjustments[prayer] ?? 0 },
            set: { preferences.prayerAdjustments[prayer] = $0 }
        )
        return SettingsRow(prayer.title, symbol: prayer.symbol, tint: .cyan) {
            HStack(spacing: 12) {
                Text(PrayerClock.clock(time)).monospacedDigit()
                Stepper(value: offset, in: -60...60) {
                    Text(offset.wrappedValue == 0 ? "±0" : String(format: "%+d min", offset.wrappedValue))
                        .monospacedDigit()
                        .foregroundStyle(offset.wrappedValue == 0 ? .secondary : .primary)
                        .frame(width: 56, alignment: .trailing)
                }
                .controlSize(.small)
            }
        }
    }

    private func applyManual() {
        guard let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) else { return }
        preferences.prayerManualPlace = Coordinates(latitude: lat, longitude: lon)
    }

    private static func intervalTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case 60: "Hour"
        case let m where m < 60: "\(m) minutes"
        default: "\(minutes / 60) hours"
        }
    }
}

// MARK: - Clipboard

struct ClipboardSettingsView: View {
    @Environment(ClipboardHistory.self) private var clipboard
    @Environment(AppPreferences.self) private var preferences
    @State private var confirmClear = false

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.clipboard) {
            SettingsGroup("History") {
                SettingsRow("Keep a clipboard history") {
                    Toggle("Keep history", isOn: $preferences.clipboardHistoryEnabled).toggleStyle(.switch)
                }
                SettingsRow("Keep the last") {
                    Picker("Limit", selection: $preferences.clipboardHistoryLimit) {
                        ForEach(AppPreferences.clipboardLimits, id: \.self) { Text("\($0) items").tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(!preferences.clipboardHistoryEnabled)
            }

            SettingsGroup {
                SettingsRow("\(clipboard.items.count) item\(clipboard.items.count == 1 ? "" : "s") stored") {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(clipboard.items.allSatisfy(\.pinned))
                }
            }
        }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { clipboard.clear() }
        } message: {
            Text("Pinned items stay. This cannot be undone.")
        }
    }
}

// MARK: - Permissions

struct PermissionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPane(.permissions) {
            SettingsGroup {
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record", tint: .blue,
                    title: "Screen Recording",
                    detail: "For every capture. Relaunch Klik after granting.",
                    granted: model.hasScreenCaptureAccess,
                    request: { PermissionManager.requestScreenCaptureAccess() },
                    openSettings: PermissionManager.openScreenRecordingSettings
                )
                PermissionRow(
                    symbol: "accessibility", tint: .purple,
                    title: "Accessibility",
                    detail: "Snippets, paste and the front field.",
                    granted: model.hasAccessibilityAccess,
                    request: {
                        PermissionManager.requestAccessibilityAccess()
                        PermissionManager.revealAppInFinder()
                    },
                    openSettings: PermissionManager.openAccessibilitySettings
                )
            }
        }
        .onAppear { model.refreshPermissionState() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissionState()
            }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        SettingsRow(title, subtitle: detail, symbol: symbol, tint: tint) {
            HStack(spacing: 10) {
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11, weight: .medium))
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Grant Access…") {
                        request()
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: openSettings) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open in System Settings")
            }
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size / 2, weight: size >= 48 ? .semibold : .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    }
}

// MARK: - Editor defaults

struct EditorSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        let d = $preferences.editorDefaults
        SettingsPane(.editor) {
            SettingsGroup {
                SettingsRow("Start each editor with the options last used") {
                    Toggle("Remember last used", isOn: d.rememberLastUsed).toggleStyle(.switch)
                }
            }

            SettingsGroup("Colors") {
                SettingsRow("Annotations") { SwatchRow(color: d.color) }
                SettingsRow("Highlight box") { SwatchRow(color: d.highlightColor) }
            }

            SettingsGroup("Shapes, lines & arrows") {
                SliderRow("Stroke width", value: d.strokeWidth, range: EditorDefaults.strokeRange, unit: "px")
                SettingsRow("Shape") {
                    Picker("Shape", selection: d.shapeKind) {
                        Label("Rectangle", systemImage: "rectangle").tag(ShapeKind.rectangle)
                        Label("Ellipse", systemImage: "oval").tag(ShapeKind.ellipse)
                        Label("Line", systemImage: "line.diagonal").tag(ShapeKind.line)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Fill") {
                    Picker("Fill", selection: d.fillMode) {
                        Text("None").tag(FillMode.none)
                        Text("Solid").tag(FillMode.solid)
                        Text("Translucent").tag(FillMode.translucent)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Arrow head") {
                    Picker("Arrow head", selection: d.arrowStyle) {
                        Label("One end", systemImage: "arrow.right").tag(ArrowStyle.single)
                        Label("Both ends", systemImage: "arrow.left.and.right").tag(ArrowStyle.double)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            SettingsGroup("Text") {
                SliderRow("Font size", value: d.fontSize, range: EditorDefaults.fontSizeRange, unit: "pt")
                SettingsRow("Weight") {
                    HStack(spacing: 10) {
                        Slider(value: d.fontWeight, in: TextStyle.weightRange).frame(width: 160)
                        Text(TextStyle(color: .black, fontSize: 12, background: .none, weight: preferences.editorDefaults.fontWeight).weightName)
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
                SettingsRow("Background") {
                    Picker("Background", selection: d.textBackground) {
                        Text("None").tag(TextBackground.none)
                        Text("Solid").tag(TextBackground.solid)
                        Text("Translucent").tag(TextBackground.translucent)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            SettingsGroup("Marker, blur & counter") {
                SliderRow("Marker width", value: d.highlighterWidth, range: EditorDefaults.highlighterRange, unit: "px")
                SettingsRow("Blur style") {
                    Picker("Blur style", selection: d.blurKind) {
                        Text("Blur").tag(BlurKind.blur)
                        Text("Pixelate").tag(BlurKind.pixelate)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SliderRow("Blur strength", value: d.blurIntensity, range: EditorDefaults.blurRange, unit: "")
                SliderRow("Counter size", value: d.counterSize, range: EditorDefaults.counterRange, unit: "px")
            }

            SettingsGroup {
                SettingsRow("Defaults") {
                    Button("Restore Defaults") {
                        let remember = preferences.editorDefaults.rememberLastUsed
                        preferences.editorDefaults = EditorDefaults()
                        preferences.editorDefaults.rememberLastUsed = remember
                    }
                }
            }
        }
    }
}

/// The editor's palette plus a color well, bound to one color.
private struct SwatchRow: View {
    @Binding var color: RGBA

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RGBA.palette, id: \.self) { swatch in
                Button { color = swatch } label: {
                    Circle()
                        .fill(Color(nsColor: swatch.nsColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.primary.opacity(color == swatch ? 0.95 : 0.3), lineWidth: color == swatch ? 2 : 1))
                        .padding(2)
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: color.nsColor) },
                set: { color = RGBA(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24)
        }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let unit: String

    init(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String) {
        self.label = label
        _value = value
        self.range = range
        self.unit = unit
    }

    var body: some View {
        SettingsRow(label) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range).frame(width: 160)
                Text("\(Int(value))\(unit.isEmpty ? "" : " \(unit)")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .trailing)
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettingsView: View {
    @Environment(ShortcutController.self) private var shortcuts

    private var hasReservedBinding: Bool {
        shortcuts.entries.values.contains { $0.status == .reservedByMacOS }
    }

    var body: some View {
        SettingsPane(.shortcuts) {
            if hasReservedBinding {
                SettingsGroup {
                    SettingsRow("A binding matches a macOS screenshot shortcut",
                                subtitle: "Turn it off in System Settings › Keyboard › Shortcuts › Screenshots.",
                                symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Keyboard Settings…") { PermissionManager.openKeyboardShortcutSettings() }
                    }
                }
            }

            SettingsGroup("Global shortcuts") {
                ForEach(HotkeyID.configurable, id: \.self) { id in
                    let entry = shortcuts.entries[id]
                    SettingsRow(id.title, symbol: symbol(for: id), tint: tint(for: id)) {
                        HStack(spacing: 10) {
                            ShortcutRecorderView(
                                hotkey: entry?.hotkey,
                                onChange: { shortcuts.set($0, for: id) },
                                onRecordingChanged: { shortcuts.isRecording = $0 }
                            )
                            statusIcon(entry?.status ?? .unassigned)
                                .frame(width: 18)
                        }
                    }
                }
            }

            SettingsGroup {
                SettingsRow("Defaults") {
                    Button("Restore Defaults") { shortcuts.restoreDefaults() }
                }
            }
        }
    }

    private func symbol(for id: HotkeyID) -> String {
        switch id {
        case .fullScreen: "display"
        case .region: "viewfinder"
        case .scrolling: "rectangle.expand.vertical"
        case .showPanel: "cursorarrow.rays"
        case .captureText: "text.viewfinder"
        case .pickColor: "eyedropper"
        case .quickTask: "checklist"
        case .quickNote: "note.text"
        case .clipboardPanel: "doc.on.clipboard"
        case .commandPalette: "command"
        case .pasteNext: "square.stack.3d.down.right"
        case .window: "macwindow"
        case .confirmCapture, .cancelCapture: "xmark"
        }
    }

    private func tint(for id: HotkeyID) -> Color {
        switch id {
        case .fullScreen: .blue
        case .region: .teal
        case .scrolling: .indigo
        case .showPanel: .orange
        case .captureText: .green
        case .pickColor: .red
        case .quickTask: .mint
        case .quickNote: .yellow
        case .clipboardPanel: .purple
        case .commandPalette: .brand
        case .pasteNext: .teal
        case .window: .cyan
        case .confirmCapture, .cancelCapture: .gray
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ShortcutController.Status) -> some View {
        switch status {
        case .active:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .help("Active")
        case .reservedByMacOS:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help("macOS uses this shortcut for its own screenshots")
        case .conflict:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                .help("Another app already uses this shortcut")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                .help("Could not register")
        case .unassigned:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                .help("No shortcut assigned")
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(CaptureLibrary.self) private var library
    @State private var copied = false

    private var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        SettingsPane(.about) {
            SettingsGroup {
                SettingsCell(vertical: 16) {
                    HStack(spacing: 16) {
                        AppIconTile(size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Klik").font(.system(size: 14, weight: .semibold))
                            Text("Screenshots you can annotate, blur and share — built natively for macOS.")
                                .font(SettingsFont.sub)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Text("Version \(short) (\(build))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(SettingsFont.sub)
                    }
                }
                SettingsRow("Version") {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Klik \(short) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
                SettingsRow("macOS") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString).foregroundStyle(.secondary)
                }
            }

            SettingsGroup("On this Mac") {
                SettingsRow("Klik", subtitle: Bundle.main.bundleURL.path(percentEncoded: false)) {
                    Button("Show in Finder") { PermissionManager.revealAppInFinder() }
                }
                SettingsRow("Captures", subtitle: library.folderURL.path(percentEncoded: false)) {
                    Button("Show in Finder") { library.revealFolder() }
                }
            }

            SettingsGroup {
                SettingsRow("© \(String(Calendar.current.component(.year, from: .now))) Stackrover")
            }
        }
    }
}

#Preview("Settings") {
    SettingsRootView(buttons: WindowButtons(close: {}, minimize: {}, zoom: {}))
        .environment(SettingsNavigation()).environment(AppModel()).environment(CaptureLibrary()).environment(AppPreferences())
        .environment(ShortcutController()).environment(ClipboardHistory()).environment(AddOnRegistry()).environment(StudioPreferences())
        .frame(width: 920, height: 640)
}
