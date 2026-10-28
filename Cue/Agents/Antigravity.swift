import Foundation

/// Google Antigravity's hooks, put in the shape Cue reads Claude Code's and Codex's.
///
/// Its events differ: a conversation (`conversationId`) for a session, the open
/// workspaces for a folder, `toolCall {name, args}` for a tool, and no event name
/// at all (the hook entry passes it to the script). Neither the prompt nor the reply
/// comes with an event; both are read from the conversation's transcript
/// (`transcriptPath`, one JSON step per line: `USER_INPUT` for a prompt,
/// `PLANNER_RESPONSE` for a reply, each with its text in `content`).
nonisolated enum Antigravity {
    /// Where the hooks go, inside `~/.gemini` (the folder the user connects).
    static let hooksFile = "config/hooks.json"
    /// The name Cue's hook definition has in that file.
    static let hookName = "cue"
    /// Events that run a tool; their entries take a matcher.
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
    static let events = ["SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"]

    // MARK: Questions

    /// The tools Cue asks about on the island before Antigravity runs them: commands,
    /// which is what Antigravity itself stops to ask about. Reading and editing files is
    /// left to its own rules, or every step of every turn would be a question.
    static let askedTools: Set<String> = ["Bash"]
    /// How long Antigravity waits on the `PreToolUse` hook, in seconds: long enough for
    /// somebody to look up and answer on the island.
    static let askTimeout = 120
    /// How long Cue holds a question before handing it back to Antigravity with "ask",
    /// comfortably inside `askTimeout` so the hook always answers before it is stopped.
    static let answerWithin: TimeInterval = 100
    /// The hook's reply when Cue does not decide: Antigravity's own approval rules do,
    /// and it asks in its own window if they say to. "allow" here would approve every
    /// command without asking anybody.
    static let undecided = #"{"decision":"ask"}"#

    // MARK: Tools

    /// A tool call as the Claude Code tool that does the same, so its step and its line
    /// on the island read the same way ("Reading Cart.swift", "Run npm test").
    static func tool(_ call: JSONValue) -> (name: String, input: JSONValue)? {
        guard let name = call["name"]?.string else { return nil }
        let args = call["args"] ?? .null
        func string(_ keys: String...) -> String? { keys.lazy.compactMap { args[$0]?.string }.first }
        func object(_ pairs: [(String, String?)]) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: pairs.compactMap { key, value in value.map { (key, JSONValue.string($0)) } }))
        }
        switch name {
        case "run_command":
            return ("Bash", object([("command", string("CommandLine", "Command")), ("cwd", string("Cwd"))]))
        case "view_file", "view_file_outline", "view_code_item":
            return ("Read", object([("file_path", string("AbsolutePath", "File", "TargetFile"))]))
        case "write_to_file":
            return ("Write", object([("file_path", string("TargetFile", "AbsolutePath")), ("content", string("CodeContent", "Content"))]))
        case "replace_file_content", "multi_replace_file_content":
            // One replacement, or several as chunks.
            var input: [String: JSONValue] = [:]
            if let file = string("TargetFile", "AbsolutePath") { input["file_path"] = .string(file) }
            let chunks = args["ReplacementChunks"]?.array ?? [args]
            input["edits"] = .array(chunks.map { chunk in
                .object(["old_string": chunk["TargetContent"] ?? .string(""), "new_string": chunk["ReplacementContent"] ?? .string("")])
            })
            return ("MultiEdit", .object(input))
        case "grep_search", "codebase_search":
            return ("Grep", object([("pattern", string("Query", "Pattern"))]))
        case "find_by_name":
            return ("Glob", object([("pattern", string("Pattern", "Query"))]))
        case "list_dir":
            return ("List", object([("path", string("DirectoryPath", "AbsolutePath", "SearchPath"))]))
        case "search_web":
            return ("WebSearch", object([("query", string("query", "Query"))]))
        case "read_url_content":
            return ("WebFetch", object([("url", string("Url", "URL", "url"))]))
        default:
            // Its own name, readable ("browser click"), with whatever says what it acts on.
            let path = string("AbsolutePath", "TargetFile", "DirectoryPath", "SearchPath")
            let readable = name.replacingOccurrences(of: "_", with: " ")
            return (readable, path.map { object([("path", $0)]) } ?? .null)
        }
    }

    // MARK: Transcript

    enum Kind: String {
        case prompt = "USER_INPUT"
        case reply = "PLANNER_RESPONSE"
    }

    /// The newest prompt or reply in a conversation's transcript, as plain text.
    static func latest(_ kind: Kind, in path: String?) -> String? {
        guard let path, let lines = tail(of: expand(path)) else { return nil }
        for line in lines.reversed() {
            // Cheap test first: most steps are tool calls.
            guard line.contains(kind.rawValue),
                  let step = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  step["type"] as? String == kind.rawValue
            else { continue }
            guard let content = step["content"] as? String else { return nil }
            let text = kind == .prompt ? request(in: content) : content
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// What the user typed: the app wraps it in `<USER_REQUEST>` with context around it.
    static func request(in content: String) -> String {
        guard let start = content.range(of: "<USER_REQUEST>"),
              let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex)
        else { return content }
        return String(content[start.upperBound..<end.lowerBound])
    }

    /// The last lines of the file: enough for the newest steps without reading a long
    /// conversation whole.
    private static func tail(of path: String, bytes: UInt64 = 1 << 20) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line
        return lines
    }

    /// `~/…` in the user's real home (inside the sandbox `~` is Cue's container).
    private static func expand(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + path.dropFirst()
    }

    // MARK: Settings

    /// `settings` with Cue's hook definition, replacing any it had; the user's own
    /// definitions are left as they were.
    static func install(into settings: [String: Any], command: String) -> [String: Any] {
        var settings = remove(from: settings)
        var definition: [String: Any] = ["enabled": true]
        for event in events {
            // The script learns which event ran it from its arguments: the event itself doesn't say.
            let timeout = event == "PreToolUse" ? askTimeout : 10
            let handler: [String: Any] = ["type": "command", "command": "\(command) \(event)", "timeout": timeout]
            definition[event] = toolEvents.contains(event) ? [["matcher": "*", "hooks": [handler]]] : [handler]
        }
        settings[hookName] = definition
        return settings
    }

    /// Whether Cue's definition is this build's: its `PreToolUse` waits long enough for an
    /// answer from the island. An older build's waited 10 seconds.
    static func isCurrent(in settings: [String: Any]) -> Bool {
        guard let definition = settings[hookName] as? [String: Any],
              let entries = definition["PreToolUse"] as? [[String: Any]],
              let hooks = entries.first?["hooks"] as? [[String: Any]],
              let timeout = hooks.first?["timeout"] as? Int else { return false }
        return timeout == askTimeout
    }

    /// `settings` without Cue's definition.
    static func remove(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        for (name, value) in settings where name == hookName || contains(value) { settings[name] = nil }
        return settings
    }

    /// Whether Cue's definition is there, on, with every event.
    static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let definition = settings[hookName] as? [String: Any], definition["enabled"] as? Bool != false else { return false }
        return events.allSatisfy { definition[$0].map(contains) ?? false }
    }

    /// Whether `value` (a definition, an event's list, an entry) runs Cue's script anywhere.
    private static func contains(_ value: Any) -> Bool {
        if let entry = value as? [String: Any] {
            if AgentHooks.isCue(entry) { return true }
            return entry.values.contains(where: contains)
        }
        if let list = value as? [Any] { return list.contains(where: contains) }
        return false
    }
}
