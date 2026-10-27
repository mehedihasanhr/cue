import Foundation

/// What Cue adds to an agent's configuration: a small script in a `cue` folder
/// beside the settings, and hook entries that run it. The script forwards each
/// event to Cue over a socket in the same folder and prints Cue's answer; with
/// Cue not running it prints nothing, and the agent asks in the terminal as usual.
nonisolated enum AgentHooks {
    static let folderName = "cue"
    static let scriptName = "cue-agent-hook"
    static let socketName = "agents.sock"
    /// Claude Code's usage limits reach only its status line: this script, put in
    /// front of the user's own status-line command, passes them on to Cue and then
    /// runs that command as before (its words kept in `statusOriginalName`).
    static let statusScriptName = "cue-statusline"
    static let statusOriginalName = "statusline-original"
    /// Where the app put the script when it was called Klik: entries running it are
    /// Cue's too, so turning the hooks on replaces them and turning them off removes them.
    static let legacyFolderName = "klik"
    static let legacyScriptName = "klik-agent-hook"

    /// The file the hooks go in, inside the agent's folder.
    static func settingsFile(for agent: AgentKind) -> String {
        switch agent {
        case .claude: "settings.json"
        case .codex: "hooks.json"
        case .antigravity: Antigravity.hooksFile
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
        case .antigravity: 10
        }
    }

    /// Events that are only news: they run in the background and never slow the agent.
    static func statusEvents(for agent: AgentKind) -> [String] {
        switch agent {
        case .claude: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop",
                       "SubagentStart", "SubagentStop"]
        case .codex: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
        case .antigravity: Antigravity.events
        }
    }

    /// The command the hook entries run. Quoted, since the folder is the user's.
    static func command(scriptPath: String, agent: AgentKind) -> String {
        "\"\(scriptPath)\" \(agent.rawValue)"
    }

    /// Whether a hook entry is one of Cue's.
    static func isCue(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains("/\(folderName)/\(scriptName)") || command.contains("/\(legacyFolderName)/\(legacyScriptName)")
    }

    // MARK: Settings

    /// `settings` with Cue's hook entries, replacing any it had before; everything
    /// else in the file is left as it was.
    static func install(into settings: [String: Any], command: String, agent: AgentKind) -> [String: Any] {
        // Antigravity's file is a different shape: named definitions, each with its events.
        if agent == .antigravity { return Antigravity.install(into: settings, command: command) }
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

    /// `settings` without Cue's hook entries; a group or event left empty goes too.
    static func remove(from settings: [String: Any]) -> [String: Any] {
        var settings = Antigravity.remove(from: settings)
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { !isCue($0) }
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

    /// Whether any Cue entry is there at all (an older build's set, say).
    static func hasAny(in settings: [String: Any]) -> Bool {
        if settings[Antigravity.hookName] != nil { return true }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in (group["hooks"] as? [[String: Any]] ?? []).contains(where: isCue) }
        }
    }

    /// Whether every Cue entry is in place (the user may have edited them away).
    static func isInstalled(in settings: [String: Any], agent: AgentKind) -> Bool {
        if agent == .antigravity { return Antigravity.isInstalled(in: settings) }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return (statusEvents(for: agent) + ["PermissionRequest"]).allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isCue)
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

    /// What Cue replies when the answer has to be typed into the agent's terminal
    /// rather than returned: `CUE-KEYS 1`. Claude Code takes a plan's approval only
    /// from its own dialog (a hook's "allow" for ExitPlanMode is ignored; its "deny"
    /// is honoured), so the script presses the dialog's key in the agent's own pane.
    static let keysReplyPrefix = "CUE-KEYS "

    /// Whether `settings`' status line is Cue's relay.
    static func hasStatusRelay(in settings: [String: Any]) -> Bool {
        ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains("/\(folderName)/\(statusScriptName)") == true
    }

    /// The user's status-line command, if any (nil when it is Cue's relay already).
    static func statusCommand(in settings: [String: Any]) -> String? {
        guard !hasStatusRelay(in: settings) else { return nil }
        return (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// `settings` with the relay as the status line, its other keys (the refresh
    /// interval, the padding) kept.
    static func installStatusRelay(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        var line = settings["statusLine"] as? [String: Any] ?? ["type": "command"]
        line["type"] = "command"
        line["command"] = "sh '\(scriptPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        if line["refreshInterval"] == nil { line["refreshInterval"] = 30 }
        settings["statusLine"] = line
        return settings
    }

    /// `settings` with the user's own status line back (`original`), or none if they had none.
    static func removeStatusRelay(from settings: [String: Any], original: String?) -> [String: Any] {
        guard hasStatusRelay(in: settings) else { return settings }
        var settings = settings
        if let original, !original.isEmpty, var line = settings["statusLine"] as? [String: Any] {
            line["command"] = original
            settings["statusLine"] = line
        } else {
            settings["statusLine"] = nil
        }
        return settings
    }

    /// The status-line relay. It hands Claude Code's status (with its usage limits)
    /// to Cue in the background, never waiting on it, then runs the user's own status
    /// line with the same input, so what the terminal shows is unchanged.
    static func statusScript(socketPath: String) -> String {
        """
    #!/bin/sh
    # Cue: passes Claude Code's usage limits to Cue for the Dynamic Island, then runs
    # the status line it stands in front of (kept in \(statusOriginalName)). Installed by
    # Cue (Settings › Agents › Usage limits), which also puts the original back.
    sock='\(socketPath.replacingOccurrences(of: "'", with: "'\\''"))'
    here=$(dirname "$0")
    profile=$(basename "$(dirname "$here")" | tr -cd 'A-Za-z0-9._ -')
    input=$(cat)
    event=$(printf %s "$input" | tr -d '\\r\\n' | sed 's/^[[:space:]]*{/{"hook_event_name":"StatusLine",/')
    case "$event" in
    '{"hook_event_name"'*)
        ( printf '{"cue":{"agent":"claude","profile":"%s","pid":%d,"ppid":%d},"event":%s}\\n' "$profile" "$$" "$PPID" "$event" \\
            | /usr/bin/nc -U -w 1 "$sock" >/dev/null 2>&1 & ) ;;
    esac
    original=$(cat "$here/\(statusOriginalName)" 2>/dev/null)
    [ -n "$original" ] && printf %s "$input" | sh -c "$original"
    exit 0

    """
    }

    /// The hook script. It adds which agent ran it, the process that did, the terminal
    /// and its pane, then hands the event to Cue and prints the reply — or, for a
    /// reply of keys, types them into that pane. It never fails the agent: any trouble
    /// (Cue not running) exits quietly.
    static func script(socketPath: String) -> String {
        """
    #!/bin/sh
    # Cue: shows this agent's sessions on the Dynamic Island and answers its questions
    # from there. Installed by Cue (Settings › Island › Agent sessions), which also
    # removes it; with Cue not running it does nothing.
    sock='\(socketPath.replacingOccurrences(of: "'", with: "'\\''"))'
    agent=$(printf %s "${1:-claude}" | tr -cd 'a-z')
    none=''
    profile=$(basename "$(dirname "$(dirname "$0")")" | tr -cd 'A-Za-z0-9._ -')
    term=$(printf %s "$TERM_PROGRAM" | tr -cd 'A-Za-z0-9._ -')
    # What started the agent: "claude-desktop" for the Claude app, "cli" in a terminal.
    entry=$(printf %s "$CLAUDE_CODE_ENTRYPOINT" | tr -cd 'a-z-')
    # The pane the agent runs in, so an answer can be typed there (see below).
    pane=''
    [ -n "$WEZTERM_PANE" ] && pane="wezterm:$(printf %s "$WEZTERM_PANE" | tr -cd '0-9')"
    [ -z "$pane" ] && [ -n "$TMUX_PANE" ] && pane="tmux:$(printf %s "$TMUX_PANE" | tr -cd '%0-9')"
    event=$(tr -d '\\r\\n')
    # Antigravity names the event only in the hook's arguments, and wants an answer
    # whatever happens: "allow" (its default policy decides) before a tool, nothing after.
    if [ "$agent" = antigravity ]; then
        name=$(printf %s "${2:-}" | tr -cd 'A-Za-z')
        none='{}'
        [ "$name" = PreToolUse ] && none='{"decision":"allow"}'
        [ -n "$event" ] || { printf %s "$none"; exit 0; }
        event=$(printf %s "$event" | sed 's/^[[:space:]]*{/{"hook_event_name":"'"$name"'",/')
    fi
    [ -n "$event" ] || exit 0
    reply=$(printf '{"cue":{"agent":"%s","profile":"%s","pid":%d,"ppid":%d,"term":"%s","pane":"%s","entry":"%s"},"event":%s}\\n' "$agent" "$profile" "$$" "$PPID" "$term" "$pane" "$entry" "$event" | /usr/bin/nc -U "$sock" 2>/dev/null)
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
        if [ -n "$none" ] && [ -z "$reply" ]; then printf %s "$none"; else printf %s "$reply"; fi ;;
    esac
    exit 0

    """
    }
}
