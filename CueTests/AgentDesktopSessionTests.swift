import XCTest

/// Sessions of the Claude desktop app: the hook script says what started the agent,
/// so Cue can tell them from a terminal's and leave their questions to the app.
final class AgentDesktopSessionTests: XCTestCase {
    private func event(entry: String?) throws -> AgentEvent {
        let cue = entry.map { #","entry":"\#($0)""# } ?? ""
        let line = Data(#"{"cue":{"agent":"claude","pid":5,"ppid":4,"term":"","pane":""\#(cue)},"event":{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}}"#.utf8)
        return try XCTUnwrap(AgentEvent(line: line))
    }

    func testDesktopEntryMarksTheSession() throws {
        XCTAssertTrue(try event(entry: "claude-desktop").isDesktop)
    }

    func testTerminalAndOlderScriptsAreNotDesktop() throws {
        XCTAssertFalse(try event(entry: "cli").isDesktop)
        XCTAssertFalse(try event(entry: "").isDesktop)
        XCTAssertNil(try event(entry: "").entry)
        // A script from an older build sends no entry at all.
        XCTAssertFalse(try event(entry: nil).isDesktop)
    }

    func testScriptSendsTheEntryPoint() {
        let script = AgentHooks.script(socketPath: "/tmp/agents.sock")
        XCTAssertTrue(script.contains("$CLAUDE_CODE_ENTRYPOINT"))
        XCTAssertTrue(script.contains(#""entry":"%s""#))
    }

    /// The script's own printf, run: the line it hands Cue must still parse.
    func testScriptLineParses() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // `nc` is swapped for `cat`, so the script prints the line it would have sent.
        let script = AgentHooks.script(socketPath: "unused").replacingOccurrences(of: "/usr/bin/nc -U \"$sock\"", with: "cat")
        let file = folder.appendingPathComponent("hook")
        try Data(script.utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path, "claude"]
        process.environment = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let line = output.fileHandleForReading.readDataToEndOfFile()
        let event = try XCTUnwrap(AgentEvent(line: line), String(decoding: line, as: UTF8.self))
        XCTAssertTrue(event.isDesktop)
    }
}
