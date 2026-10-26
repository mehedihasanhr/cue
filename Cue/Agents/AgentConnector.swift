import AppKit
import os
import Foundation

/// Links Cue to Claude Code and Codex. Cue is sandboxed, so the user picks each
/// agent folder (`~/.claude`, a second profile such as `~/.claude-work`, `~/.codex`)
/// once; Cue keeps a bookmark to it, writes its hook script and entries there,
/// and listens on one socket in its own container for all of them.
@MainActor
@Observable
final class AgentConnector {
    struct Link: Equatable, Identifiable {
        let id: String
        let agent: AgentKind
        var folder: URL
        /// Cue's entries are in the agent's settings.
        var installed = false
        /// The socket is open: events reach the island.
        var listening = false
        var problem: String?

        /// "work" for `~/.claude-work`; nil for the agent's default folder.
        var profile: String? { agent.profile(fromFolderName: folder.lastPathComponent) }
    }

    private(set) var links: [Link] = []
    let store: AgentStore

    @ObservationIgnored private var server: AgentServer?
    @ObservationIgnored private let defaults = UserDefaults.standard
    private var running = false
    /// Put Cue's relay in front of Claude Code's status line, for its usage limits
    /// (Settings › Agents › Usage limits); set by the app delegate.
    var relaysUsage = false {
        didSet { if oldValue != relaysUsage { applyStatusRelays() } }
    }

    private static let linksKey = "agents.links"

    init(store: AgentStore) {
        self.store = store
        migrateSingleFolders()
        for saved in defaults.array(forKey: Self.linksKey) as? [[String: Any]] ?? [] {
            guard let id = saved["id"] as? String, let agent = (saved["agent"] as? String).flatMap(AgentKind.init(rawValue:)),
                  let data = saved["bookmark"] as? Data
            else { continue }
            var stale = false
            guard let folder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                links.append(Link(id: id, agent: agent, folder: URL(fileURLWithPath: saved["path"] as? String ?? "/"),
                                  problem: "Cue lost access to this folder. Disconnect it and connect again."))
                continue
            }
            _ = folder.startAccessingSecurityScopedResource() // for as long as Cue runs
            links.append(Link(id: id, agent: agent, folder: folder))
            if stale { save() }
            refresh(id)
        }
        #if DEBUG
        // A folder the sandbox can reach without a bookmark (under ~/Pictures), with the
        // hook script but no agent settings: for driving the island by hand.
        if let path = ProcessInfo.processInfo.environment["CUE_DEBUG_AGENT_FOLDER"] {
            links.append(Link(id: "debug", agent: .claude, folder: URL(fileURLWithPath: path), installed: true))
        }
        #endif
    }

    func links(for agent: AgentKind) -> [Link] { links.filter { $0.agent == agent } }

    private func isLinked(_ folder: URL) -> Bool {
        links.contains { $0.folder.standardizedFileURL.path == folder.standardizedFileURL.path }
    }

    /// The Claude desktop app is installed but its folder is not connected: its
    /// sessions run with `~/.claude`'s settings whatever profile the terminal uses,
    /// so without it they never reach the island.
    var needsDesktopFolder: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.desktopAppID) != nil
            && !isLinked(Self.defaultFolder(for: .claude))
    }

    static let desktopAppID = "com.anthropic.claudefordesktop"

    /// The first builds kept one folder per agent; those become the first links.
    private func migrateSingleFolders() {
        guard defaults.array(forKey: Self.linksKey) == nil else { return }
        var saved: [[String: Any]] = []
        for agent in AgentKind.allCases {
            let key = "agents.folder.\(agent.rawValue)"
            guard let data = defaults.data(forKey: key) else { continue }
            saved.append(["id": UUID().uuidString, "agent": agent.rawValue, "bookmark": data])
            defaults.removeObject(forKey: key)
        }
        if !saved.isEmpty { defaults.set(saved, forKey: Self.linksKey) }
    }

    private func save() {
        let saved = links.compactMap { link -> [String: Any]? in
            guard link.id != "debug", let bookmark = try? link.folder.bookmarkData(options: .withSecurityScope) else { return nil }
            return ["id": link.id, "agent": link.agent.rawValue, "bookmark": bookmark, "path": link.folder.path]
        }
        defaults.set(saved, forKey: Self.linksKey)
    }

    private func update(_ id: String, _ change: (inout Link) -> Void) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        change(&links[index])
    }

    /// The user's real home; inside the sandbox `NSHomeDirectory()` is the container.
    static var home: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static func defaultFolder(for agent: AgentKind) -> URL {
        switch agent {
        case .claude: home.appendingPathComponent(".claude")
        case .codex: home.appendingPathComponent(".codex")
        }
    }

    // MARK: Running

    /// The socket the hook script talks to. It lives in Cue's container: the sandbox
    /// lets Cue make a socket nowhere else, and connecting to it reads no data there.
    static var socketPath: String { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(AgentHooks.socketName).path }

    /// Opens (or closes) the socket, as Settings › Agents says.
    func setRunning(_ running: Bool) {
        self.running = running
        if running { listen() } else { stopListening() }
        if !running {
            store.reset()
            applyStatusRelays()
        }
    }

    /// The relay in each connected Claude folder, or the user's own status line back.
    private func applyStatusRelays() {
        for link in links where link.agent == .claude && link.installed {
            if relaysUsage && running { try? installStatusRelay(in: link.folder) } else { try? removeStatusRelay(in: link.folder) }
        }
    }

    private func listen() {
        defer { applyStatusRelays() }
        let installed = links.filter(\.installed).map(\.id)
        for id in installed {
            guard let folder = links.first(where: { $0.id == id })?.folder else { continue }
            do {
                try writeScript(in: folder.appendingPathComponent(AgentHooks.folderName)) // kept current with this build
            } catch {
                update(id) { $0.problem = "Couldn’t update Cue’s hook: \(error.localizedDescription)" }
            }
        }
        if server == nil, !installed.isEmpty {
            let store = store
            let server = AgentServer(path: Self.socketPath,
                                     onEvent: { event, connection in MainActor.assumeIsolated { store.receive(event, from: connection) } })
            do {
                try server.start()
                self.server = server
            } catch {
                Log.app.error("Agent sessions: socket failed: \(String(describing: error), privacy: .public)")
                for id in installed { update(id) { $0.problem = "Cue couldn’t listen for sessions: \(error)" } }
            }
        }
        for id in installed { update(id) { $0.listening = server != nil } }
    }

    private func stopListening() {
        server?.stop()
        server = nil
        for index in links.indices { links[index].listening = false }
    }

    func tearDown() {
        store.releaseAll()
        stopListening()
    }

    // MARK: Connecting

    /// Asks for an agent folder, then installs the hooks there. A folder that is
    /// already connected is connected again (its hooks put back).
    func connect(_ agent: AgentKind) {
        let panel = NSOpenPanel()
        let another = !links(for: agent).isEmpty
        panel.title = another ? "Connect another \(agent.name) profile" : "Connect \(agent.name)"
        panel.message = "Choose \(agent.name)’s folder (\(agent == .claude ? "~/.claude, or a profile’s, like ~/.claude-work" : "usually ~/.codex")). Cue adds its hooks to \(AgentHooks.settingsFile(for: agent)) there, so its sessions show on the island."
        panel.prompt = "Connect"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // The default folder until it is connected — the Claude desktop app's sessions
        // use it even when a terminal profile is linked already.
        let suggested = Self.defaultFolder(for: agent)
        panel.directoryURL = !isLinked(suggested) && FileManager.default.fileExists(atPath: suggested.path) ? suggested : Self.home
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL else { return }
        guard looksRight(folder, for: agent) || confirmUnusual(folder, for: agent) else { return }
        guard (try? folder.bookmarkData(options: .withSecurityScope)) != nil else {
            let alert = NSAlert()
            alert.messageText = "Cue couldn’t keep access to \(folder.lastPathComponent)"
            alert.runModal()
            return
        }
        _ = folder.startAccessingSecurityScopedResource()
        let id = links.first { $0.agent == agent && $0.folder.standardizedFileURL == folder }?.id ?? UUID().uuidString
        if !links.contains(where: { $0.id == id }) { links.append(Link(id: id, agent: agent, folder: folder)) }
        do {
            try install(agent, in: folder)
            update(id) {
                $0.installed = true
                $0.problem = nil
            }
        } catch {
            update(id) { $0.problem = "Couldn’t add the hooks: \(error.localizedDescription)" }
        }
        save()
        if running { listen() }
    }

    /// Removes Cue's hooks and script from that folder, and forgets it.
    func disconnect(_ id: String) {
        guard let link = links.first(where: { $0.id == id }) else { return }
        try? uninstall(link.agent, in: link.folder)
        link.folder.stopAccessingSecurityScopedResource()
        links.removeAll { $0.id == id }
        save()
        store.forget(link.agent, profile: link.profile)
        if !links.contains(where: \.installed) { stopListening() }
    }

    /// Re-reads whether the hooks are still in the agent's settings.
    func refresh(_ id: String) {
        guard let link = links.first(where: { $0.id == id }) else { return }
        let file = link.folder.appendingPathComponent(AgentHooks.settingsFile(for: link.agent))
        let settings = (try? AgentHooks.decode(try? Data(contentsOf: file))) ?? [:]
        var installed = AgentHooks.isInstalled(in: settings, agent: link.agent)
        // The script of an older build: put this one's in place, so a change to it
        // (what it tells Cue) needs no reconnecting.
        if installed { try? writeScript(in: link.folder.appendingPathComponent(AgentHooks.folderName)) }
        // An older build's entries, missing events added since: bring them up to date.
        // Not for Codex, which would ask the user to review every new entry again.
        if !installed, link.agent == .claude, AgentHooks.hasAny(in: settings), (try? install(link.agent, in: link.folder)) != nil {
            installed = true
        }
        update(id) {
            $0.installed = installed
            if !installed, $0.problem == nil { $0.problem = "Cue’s hooks are missing from \(file.lastPathComponent). Disconnect and connect again to add them." }
            if installed, $0.problem?.hasPrefix("Cue’s hooks are missing") == true { $0.problem = nil }
        }
    }

    private func looksRight(_ folder: URL, for agent: AgentKind) -> Bool {
        let names = agent == .claude ? ["settings.json", "projects", "CLAUDE.md"] : ["config.toml", "sessions", "auth.json"]
        return folder.lastPathComponent.hasPrefix(agent == .claude ? ".claude" : ".codex")
            || names.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    private func confirmUnusual(_ folder: URL, for agent: AgentKind) -> Bool {
        let alert = NSAlert()
        alert.messageText = "This doesn’t look like \(agent.name)’s folder"
        alert.informativeText = "\(folder.path) has none of \(agent.shortName)’s files. Cue will add \(AgentHooks.settingsFile(for: agent)) here anyway if you continue."
        alert.addButton(withTitle: "Use This Folder")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Files

    private func install(_ agent: AgentKind, in folder: URL) throws {
        let cueFolder = folder.appendingPathComponent(AgentHooks.folderName)
        try writeScript(in: cueFolder)
        let file = folder.appendingPathComponent(AgentHooks.settingsFile(for: agent))
        let existing = try? Data(contentsOf: file)
        let settings = try AgentHooks.decode(existing)
        // One copy of the settings as they were before Cue first touched them.
        let backup = cueFolder.appendingPathComponent("\(file.lastPathComponent).before-cue")
        if let existing, !FileManager.default.fileExists(atPath: backup.path) { try? existing.write(to: backup) }
        let command = AgentHooks.command(scriptPath: cueFolder.appendingPathComponent(AgentHooks.scriptName).path, agent: agent)
        try write(AgentHooks.encode(AgentHooks.install(into: settings, command: command, agent: agent)), to: file)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(AgentHooks.legacyFolderName))
    }

    private func installStatusRelay(in folder: URL) throws {
        let cueFolder = folder.appendingPathComponent(AgentHooks.folderName)
        try FileManager.default.createDirectory(at: cueFolder, withIntermediateDirectories: true)
        let script = cueFolder.appendingPathComponent(AgentHooks.statusScriptName)
        let data = Data(AgentHooks.statusScript(socketPath: Self.socketPath).utf8)
        if (try? Data(contentsOf: script)) != data { try data.write(to: script, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let file = folder.appendingPathComponent(AgentHooks.settingsFile(for: .claude))
        let settings = try AgentHooks.decode(try? Data(contentsOf: file))
        guard !AgentHooks.hasStatusRelay(in: settings) else { return }
        // The user's own command, kept for the relay to run and to be put back.
        let original = cueFolder.appendingPathComponent(AgentHooks.statusOriginalName)
        try Data((AgentHooks.statusCommand(in: settings) ?? "").utf8).write(to: original, options: .atomic)
        try write(AgentHooks.encode(AgentHooks.installStatusRelay(into: settings, scriptPath: script.path)), to: file)
    }

    private func removeStatusRelay(in folder: URL) throws {
        let file = folder.appendingPathComponent(AgentHooks.settingsFile(for: .claude))
        let settings = try AgentHooks.decode(try? Data(contentsOf: file))
        guard AgentHooks.hasStatusRelay(in: settings) else { return }
        let original = folder.appendingPathComponent(AgentHooks.folderName).appendingPathComponent(AgentHooks.statusOriginalName)
        let command = (try? String(contentsOf: original, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(AgentHooks.encode(AgentHooks.removeStatusRelay(from: settings, original: command)), to: file)
    }

    private func uninstall(_ agent: AgentKind, in folder: URL) throws {
        if agent == .claude { try? removeStatusRelay(in: folder) }
        let file = folder.appendingPathComponent(AgentHooks.settingsFile(for: agent))
        if let data = try? Data(contentsOf: file) {
            let settings = try AgentHooks.decode(data)
            try write(AgentHooks.encode(AgentHooks.remove(from: settings)), to: file)
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(AgentHooks.folderName))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(AgentHooks.legacyFolderName))
    }

    private func writeScript(in cueFolder: URL) throws {
        try FileManager.default.createDirectory(at: cueFolder, withIntermediateDirectories: true)
        let script = cueFolder.appendingPathComponent(AgentHooks.scriptName)
        let data = Data(AgentHooks.script(socketPath: Self.socketPath).utf8)
        if (try? Data(contentsOf: script)) != data { try data.write(to: script, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Atomically, unless the file is a link (a dotfiles manager's): then through it,
    /// so the link stays.
    private func write(_ data: Data, to file: URL) throws {
        let isLink = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        try data.write(to: file, options: isLink ? [] : .atomic)
    }
}
