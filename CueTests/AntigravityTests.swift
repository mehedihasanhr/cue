import XCTest

/// Antigravity's hooks read the way Claude Code's do: its conversation as a session,
/// its prompt and reply from the transcript, its tools as Claude's.
final class AntigravityTests: XCTestCase {
    private var folder: URL!
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A transcript with a prompt (wrapped as the app wraps it), a tool step and a reply.
    private func transcript() throws -> URL {
        let steps: [[String: Any]] = [
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT",
             "content": "<USER_REQUEST>\nfix the login bug\n</USER_REQUEST>\n<ADDITIONAL_METADATA>The current local time is: 10:00</ADDITIONAL_METADATA>"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "content": "", "tool_calls": [["name": "view_file"]]],
            ["step_index": 2, "source": "MODEL", "type": "PLANNER_RESPONSE", "content": "Fixed the **login** bug in `Auth.swift`."],
        ]
        let lines = try steps.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let url = folder.appendingPathComponent("transcript.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One event as the hook script forwards it.
    private func event(_ name: String, _ fields: [String: Any]) throws -> AgentEvent {
        var payload: [String: Any] = ["hook_event_name": name, "conversationId": "c1", "workspacePaths": ["/work/shop"]]
        payload.merge(fields) { $1 }
        let line: [String: Any] = ["cue": ["agent": "antigravity", "profile": ".gemini"], "event": payload]
        return try XCTUnwrap(AgentEvent(line: try JSONSerialization.data(withJSONObject: line)))
    }

    func testPromptAndReplyComeFromTheTranscript() throws {
        let path = try transcript().path
        let start = try event("PreInvocation", ["transcriptPath": path, "invocationNum": 0])
        XCTAssertEqual(start.name, .preInvocation)
        XCTAssertEqual(start.sessionID, "c1")
        XCTAssertEqual(start.cwd, "/work/shop")
        XCTAssertNil(start.profile)
        XCTAssertEqual(start.prompt, "fix the login bug")
        let stop = try event("Stop", ["transcriptPath": path, "fullyIdle": true])
        XCTAssertEqual(stop.message, "Fixed the **login** bug in `Auth.swift`.")
    }

    func testATurnReadsLikeClaudes() throws {
        let path = try transcript().path
        var book = AgentSessionBook()
        book.apply(try event("PreInvocation", ["transcriptPath": path]), at: now)
        book.apply(try event("PreToolUse", ["toolCall": ["name": "view_file", "args": ["AbsolutePath": "/work/shop/Auth.swift"]]]), at: now)
        // A second call to the model, mid-turn: still the same turn, its steps kept.
        book.apply(try event("PreInvocation", ["transcriptPath": path, "invocationNum": 1]), at: now)
        var session = try XCTUnwrap(book.sessions.first)
        XCTAssertEqual(session.agent, .antigravity)
        XCTAssertEqual(session.title, "fix the login bug")
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.steps.map(\.title), ["Read Auth.swift"])
        XCTAssertEqual(session.project, "shop")
        book.apply(try event("Stop", ["transcriptPath": path, "fullyIdle": true]), at: now)
        session = try XCTUnwrap(book.sessions.first)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.activity, "Fixed the login bug in Auth.swift.")
    }

    func testToolsReadAsClaudes() throws {
        let command = try XCTUnwrap(Antigravity.tool(.object(["name": .string("run_command"), "args": .object(["CommandLine": .string("npm test")])])))
        XCTAssertEqual(command.name, "Bash")
        XCTAssertEqual(AgentToolSummary(tool: command.name, input: command.input).line, "Bash · npm test")
        let edit = try XCTUnwrap(Antigravity.tool(.object(["name": .string("replace_file_content"), "args": .object([
            "TargetFile": .string("/a/Cart.swift"), "TargetContent": .string("a"), "ReplacementContent": .string("b\nc"),
        ])])))
        let step = AgentStep(id: 1, tool: edit.name, input: edit.input)
        XCTAssertEqual(step.title, "Edit Cart.swift")
        XCTAssertEqual(step.edit, AgentEdit(file: "Cart.swift", added: 2, removed: 1))
    }

    func testHooksGoInAndComeOutLeavingTheUsersOwn() throws {
        let theirs: [String: Any] = ["lint": ["PostToolUse": [["matcher": "run_command", "hooks": [["command": "./lint.sh"]]]]]]
        let command = AgentHooks.command(scriptPath: "/Users/me/.gemini/cue/cue-agent-hook", agent: .antigravity)
        let installed = AgentHooks.install(into: theirs, command: command, agent: .antigravity)
        XCTAssertTrue(AgentHooks.isInstalled(in: installed, agent: .antigravity))
        XCTAssertNotNil(installed["lint"])
        let definition = try XCTUnwrap(installed["cue"] as? [String: Any])
        let start = try XCTUnwrap((definition["SessionStart"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(start.hasSuffix(" antigravity SessionStart"))
        let removed = AgentHooks.remove(from: installed)
        XCTAssertNil(removed["cue"])
        XCTAssertNotNil(removed["lint"])
        XCTAssertFalse(AgentHooks.isInstalled(in: removed, agent: .antigravity))
    }
}
