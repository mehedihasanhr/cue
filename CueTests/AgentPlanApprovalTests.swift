import XCTest

/// Approving a plan from the island. Claude Code ignores a hook's "allow" for
/// ExitPlanMode (it honours "deny"), so approval is a reply of keys the hook script
/// presses in the agent's own pane, and the dialog takes them as if typed there.
final class AgentPlanApprovalTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    private func planRequest(pane: String?) throws -> AgentRequest {
        let event = AgentEvent(agent: .claude, name: .permissionRequest, sessionID: "s1", toolName: "ExitPlanMode",
                               toolInput: .object(["plan": .string("# Plan")]), pane: pane)
        return try XCTUnwrap(AgentRequest(event, at: now))
    }

    func testEnvelopeCarriesThePane() throws {
        let line = Data(#"{"cue":{"agent":"claude","profile":".claude","pid":5,"ppid":4,"term":"WezTerm","pane":"wezterm:3"},"event":{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"p"}}}"#.utf8)
        let event = try XCTUnwrap(AgentEvent(line: line))
        XCTAssertEqual(event.pane, "wezterm:3")
        XCTAssertEqual(try XCTUnwrap(AgentRequest(event, at: now)).pane, "wezterm:3")
    }

    func testEmptyPaneIsNone() throws {
        let line = Data(#"{"cue":{"agent":"claude","pid":5,"ppid":4,"term":"Apple_Terminal","pane":""},"event":{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{}}}"#.utf8)
        XCTAssertNil(try XCTUnwrap(AgentEvent(line: line)).pane)
    }

    func testPlanCanBeApprovedOnlyWithAPane() throws {
        XCTAssertTrue(try planRequest(pane: "wezterm:3").canApprovePlan)
        XCTAssertFalse(try planRequest(pane: nil).canApprovePlan)
    }

    func testApprovalRepliesWithTheDialogKeys() throws {
        let request = try planRequest(pane: "wezterm:3")
        XCTAssertEqual(String(decoding: AgentReply.json(for: request, .approvePlan(reviewEdits: false)), as: UTF8.self), "CUE-KEYS 1")
        XCTAssertEqual(String(decoding: AgentReply.json(for: request, .approvePlan(reviewEdits: true)), as: UTF8.self), "CUE-KEYS 2")
    }

    func testKeepPlanningStillDeniesThroughTheHook() throws {
        let reply = String(decoding: AgentReply.json(for: try planRequest(pane: "wezterm:3"), .deny), as: UTF8.self)
        XCTAssertTrue(reply.contains(#""behavior":"deny""#))
        XCTAssertTrue(reply.contains("keep planning"))
    }

    /// The generated script itself, against a fake Cue and a fake wezterm: a keys reply
    /// prints nothing for the agent and presses the key in the pane the event came from;
    /// any other reply is passed through.
    func testScriptPressesKeysInThePane() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pressed = dir.appendingPathComponent("pressed")
        let wezterm = dir.appendingPathComponent("wezterm")
        try "#!/bin/sh\necho \"$@\" > '\(pressed.path)'\n".write(to: wezterm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wezterm.path)

        func run(reply: String) throws -> String {
            let socket = dir.appendingPathComponent("s.sock").path
            try? FileManager.default.removeItem(atPath: socket)
            let script = dir.appendingPathComponent("hook")
            try AgentHooks.script(socketPath: socket).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            // A one-shot Cue: reads the line, answers with `reply`.
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-c", """
            import socket,sys
            s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); print('up', flush=True)
            c,_=s.accept(); b=b''
            while not b.endswith(b'\\n'): b+=c.recv(65536)
            c.sendall(sys.argv[2].encode()); c.close()
            """, socket, reply]
            let ready = Pipe()
            server.standardOutput = ready
            try server.run()
            _ = ready.fileHandleForReading.availableData
            let hook = Process()
            hook.executableURL = script
            hook.arguments = ["claude"]
            hook.environment = ["PATH": "\(dir.path):/usr/bin:/bin", "WEZTERM_PANE": "7", "TERM_PROGRAM": "WezTerm"]
            let input = Pipe(), output = Pipe()
            hook.standardInput = input
            hook.standardOutput = output
            try hook.run()
            input.fileHandleForWriting.write(Data(#"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode"}"#.utf8))
            try input.fileHandleForWriting.close()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            hook.waitUntilExit()
            server.waitUntilExit()
            return String(decoding: printed, as: UTF8.self)
        }

        XCTAssertEqual(try run(reply: #"{"hookSpecificOutput":{}}"#), #"{"hookSpecificOutput":{}}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pressed.path))

        // Returns at once (the agent's dialog comes up only then), presses a moment later.
        XCTAssertEqual(try run(reply: "CUE-KEYS 2"), "")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pressed.path), Date() < deadline { usleep(100_000) }
        usleep(100_000)
        XCTAssertEqual(try String(contentsOf: pressed, encoding: .utf8), "cli send-text --no-paste --pane-id 7 2\n")
    }
}
