import XCTest

/// Claude Code's usage limits, through the relay put in front of its status line.
final class AgentUsageTests: XCTestCase {
    private let status = #"{"session_id":"s1","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":6.4,"resets_at":1793000000},"seven_day":{"used_percentage":41,"resets_at":1793500000}}}"#

    func testReadsBothWindowsFromTheStatusLine() throws {
        let line = Data(#"{"cue":{"agent":"claude","profile":".claude","pid":1,"ppid":2},"event":"#.utf8)
            + Data(status.replacingOccurrences(of: "{\"session_id\"", with: "{\"hook_event_name\":\"StatusLine\",\"session_id\"").utf8) + Data("}".utf8)
        let event = try XCTUnwrap(AgentEvent(line: line))
        XCTAssertEqual(event.name, .statusLine)
        let usage = try XCTUnwrap(AgentUsage(rateLimits: event.rateLimits, at: .now))
        XCTAssertEqual(usage.fiveHour?.percent ?? 0, 6.4, accuracy: 0.001)
        XCTAssertEqual(usage.sevenDay?.percent, 41)
        XCTAssertEqual(usage.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1793000000))
    }

    func testNoLimitsNoUsage() {
        XCTAssertNil(AgentUsage(rateLimits: nil, at: .now))
    }

    func testRelayKeepsTheUsersStatusLineAndPutsItBack() {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "bash ~/.claude/statusline.sh", "refreshInterval": 10], "model": "opus"]
        XCTAssertEqual(AgentHooks.statusCommand(in: settings), "bash ~/.claude/statusline.sh")
        let relayed = AgentHooks.installStatusRelay(into: settings, scriptPath: "/Users/me/.claude/cue/cue-statusline")
        XCTAssertTrue(AgentHooks.hasStatusRelay(in: relayed))
        XCTAssertNil(AgentHooks.statusCommand(in: relayed))
        XCTAssertEqual((relayed["statusLine"] as? [String: Any])?["refreshInterval"] as? Int, 10)
        XCTAssertEqual(relayed["model"] as? String, "opus")
        let back = AgentHooks.removeStatusRelay(from: relayed, original: "bash ~/.claude/statusline.sh")
        XCTAssertEqual((back["statusLine"] as? [String: Any])?["command"] as? String, "bash ~/.claude/statusline.sh")
        XCTAssertNil(AgentHooks.removeStatusRelay(from: AgentHooks.installStatusRelay(into: [:], scriptPath: "/x/cue/cue-statusline"), original: "")["statusLine"])
    }

    /// The script itself: the user's status line prints just as before, with nobody listening.
    func testScriptRunsTheOriginalWithTheSameInput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cue")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent(AgentHooks.statusScriptName)
        try AgentHooks.statusScript(socketPath: folder.appendingPathComponent("nobody.sock").path).write(to: script, atomically: true, encoding: .utf8)
        try #"printf 'line:%s' "$(cat | tr -d '\n' | wc -c | tr -d ' ')""#.write(to: folder.appendingPathComponent(AgentHooks.statusOriginalName), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(status.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let printed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(printed, "line:\(status.utf8.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
