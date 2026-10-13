import Foundation

/// What Klik adds to an agent's configuration: a small script in a `klik` folder
/// beside the settings, and hook entries that run it. The script forwards each
/// event to Klik over a socket in the same folder and prints Klik's answer; with
/// Klik not running it prints nothing, and the agent asks in the terminal as usual.
nonisolated enum AgentHooks {
    static let folderName = "klik"
    static let scriptName = "klik-agent-hook"
    static let socketName = "agents.sock"

    /// The file the hooks go in, inside the agent's folder.
    static func settingsFile(for agent: AgentKind) -> String {
        switch agent {
        case .claude: "settings.json"
        case .codex: "hooks.json"
        }
    }

    /// How long a permission request may wait for an answer from the island.
    /// Claude Code shows its own prompt meanwhile, and stops the hook once that is
    /// answered, so the wait can be long. Codex is given its default, in case its
    /// terminal waits for the hook.
    static func permissionTimeout(for agent: AgentKind) -> Int {
        switch agent {
        case .claude: 86_400
        case .codex: 600
        }
    }

    /// Events that are only news: they run in the background and never slow the agent.
    static func statusEvents(for agent: AgentKind) -> [String] {
        switch agent {
        case .claude: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop",
                       "SubagentStart", "SubagentStop"]
        case .codex: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
        }
    }

    /// The command the hook entries run. Quoted, since the folder is the user's.
    static func command(scriptPath: String, agent: AgentKind) -> String {
        "\"\(scriptPath)\" \(agent.rawValue)"
    }

    /// Whether a hook entry is one of Klik's.
    static func isKlik(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains("/\(folderName)/\(scriptName)") == true
    }

    // MARK: Settings

    /// `settings` with Klik's hook entries, replacing any it had before; everything
    /// else in the file is left as it was.
    static func install(into settings: [String: Any], command: String, agent: AgentKind) -> [String: Any] {
        var settings = remove(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        func add(_ event: String, _ hook: [String: Any]) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["matcher": "", "hooks": [hook]])
            hooks[event] = groups
        }
        for event in statusEvents(for: agent) {
            add(event, ["type": "command", "command": command, "async": true, "timeout": 10])
        }
        add("PermissionRequest", ["type": "command", "command": command, "timeout": permissionTimeout(for: agent)])
        settings["hooks"] = hooks
        return settings
    }

    /// `settings` without Klik's hook entries; a group or event left empty goes too.
    static func remove(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { !isKlik($0) }
                guard others.count != entries.count else { return group }
                guard !others.isEmpty else { return nil }
                var group = group
                group["hooks"] = others
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    /// Whether any Klik entry is there at all (an older build's set, say).
    static func hasAny(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in (group["hooks"] as? [[String: Any]] ?? []).contains(where: isKlik) }
        }
    }

    /// Whether every Klik entry is in place (the user may have edited them away).
    static func isInstalled(in settings: [String: Any], agent: AgentKind) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return (statusEvents(for: agent) + ["PermissionRequest"]).allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isKlik)
            }
        }
    }

    static func decode(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    static func encode(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    // MARK: Script

    /// What Klik replies when the answer has to be typed into the agent's terminal
    /// rather than returned: `KLIK-KEYS 1`. Claude Code takes a plan's approval only
    /// from its own dialog (a hook's "allow" for ExitPlanMode is ignored; its "deny"
    /// is honoured), so the script presses the dialog's key in the agent's own pane.
    static let keysReplyPrefix = "KLIK-KEYS "

    /// The hook script. It adds which agent ran it, the process that did, the terminal
    /// and its pane, then hands the event to Klik and prints the reply — or, for a
    /// reply of keys, types them into that pane. It never fails the agent: any trouble
    /// (Klik not running) exits quietly.
    static func script(socketPath: String) -> String {
        """
    #!/bin/sh
    # Klik: shows this agent's sessions on the Dynamic Island and answers its questions
    # from there. Installed by Klik (Settings › Island › Agent sessions), which also
    # removes it; with Klik not running it does nothing.
    sock='\(socketPath.replacingOccurrences(of: "'", with: "'\\''"))'
    agent=$(printf %s "${1:-claude}" | tr -cd 'a-z')
    profile=$(basename "$(dirname "$(dirname "$0")")" | tr -cd 'A-Za-z0-9._ -')
    term=$(printf %s "$TERM_PROGRAM" | tr -cd 'A-Za-z0-9._ -')
    # What started the agent: "claude-desktop" for the Claude app, "cli" in a terminal.
    entry=$(printf %s "$CLAUDE_CODE_ENTRYPOINT" | tr -cd 'a-z-')
    # The pane the agent runs in, so an answer can be typed there (see below).
    pane=''
    [ -n "$WEZTERM_PANE" ] && pane="wezterm:$(printf %s "$WEZTERM_PANE" | tr -cd '0-9')"
    [ -z "$pane" ] && [ -n "$TMUX_PANE" ] && pane="tmux:$(printf %s "$TMUX_PANE" | tr -cd '%0-9')"
    event=$(tr -d '\\r\\n')
    [ -n "$event" ] || exit 0
    reply=$(printf '{"klik":{"agent":"%s","profile":"%s","pid":%d,"ppid":%d,"term":"%s","pane":"%s","entry":"%s"},"event":%s}\\n' "$agent" "$profile" "$$" "$PPID" "$term" "$pane" "$entry" "$event" | /usr/bin/nc -U "$sock" 2>/dev/null)
    case "$reply" in
    '\(keysReplyPrefix)'*)
        # An answer only the agent's own dialog accepts: press its key in this pane.
        keys=$(printf %s "${reply#\(keysReplyPrefix)}" | tr -cd '0-9')
        [ -n "$keys" ] || exit 0
        # The dialog appears only once this hook has returned, so press the key a moment
        # later, from the background, with nothing left holding the agent's pipe open.
        (
            sleep 1
            case "$pane" in
            wezterm:*)
                wez=$(command -v wezterm || echo /opt/homebrew/bin/wezterm)
                [ -x "$wez" ] || wez=/Applications/WezTerm.app/Contents/MacOS/wezterm
                "$wez" cli send-text --no-paste --pane-id "${pane#wezterm:}" "$keys" ;;
            tmux:*)
                tmux send-keys -t "${pane#tmux:}" -l "$keys" ;;
            esac
        ) </dev/null >/dev/null 2>&1 &
        ;;
    *)
        printf %s "$reply" ;;
    esac
    exit 0

    """
    }
}
