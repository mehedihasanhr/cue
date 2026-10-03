import XCTest

/// Subagent rows under a session: they leave when Claude Code stops listing them,
/// even if their own stop was never reported.
final class AgentSessionBookTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    private func event(_ name: AgentEvent.Name, subagentID: String? = nil, subagentType: String? = nil,
                       backgroundTasks: [JSONValue]? = nil) -> AgentEvent {
        AgentEvent(agent: .claude, name: name, sessionID: "s1", subagentID: subagentID, subagentType: subagentType,
                   backgroundTasks: backgroundTasks)
    }

    private func task(_ id: String, type: String = "subagent", status: String = "running") -> JSONValue {
        .object(["id": .string(id), "type": .string(type), "status": .string(status)])
    }

    private func workers(_ book: AgentSessionBook) -> [String] {
        book.sessions.first?.workers.map(\.id) ?? []
    }

    func testStopDropsBackgroundSubagentNoLongerListed() {
        var book = AgentSessionBook()
        book.apply(event(.userPromptSubmit, backgroundTasks: [task("a1")]), at: now)
        XCTAssertEqual(workers(book), ["a1"])
        book.apply(event(.stop, backgroundTasks: []), at: now)
        XCTAssertEqual(workers(book), [])
    }

    func testStopDropsBackgroundSubagentListedAsFinished() {
        var book = AgentSessionBook()
        book.apply(event(.userPromptSubmit, backgroundTasks: [task("a1")]), at: now)
        book.apply(event(.stop, backgroundTasks: [task("a1", status: "completed")]), at: now)
        XCTAssertEqual(workers(book), [])
    }

    func testBackgroundSubagentStillRunningStays() {
        var book = AgentSessionBook()
        book.apply(event(.userPromptSubmit, backgroundTasks: [task("a1")]), at: now)
        book.apply(event(.stop, backgroundTasks: [task("a1")]), at: now)
        XCTAssertEqual(workers(book), ["a1"])
    }

    func testStopDropsForegroundSubagents() {
        var book = AgentSessionBook()
        book.apply(event(.userPromptSubmit), at: now)
        book.apply(event(.subagentStart, subagentID: "f1", subagentType: "Explore"), at: now)
        XCTAssertEqual(workers(book), ["f1"])
        book.apply(event(.stop), at: now)
        XCTAssertEqual(workers(book), [])
    }

    func testStopIgnoresStructuredReplies() {
        var book = AgentSessionBook()
        book.apply(AgentEvent(agent: .codex, name: .stop, sessionID: "s1", message: "Fixed the **login** bug in `Auth.swift`."), at: now)
        XCTAssertEqual(book.sessions.first?.activity, "Fixed the login bug in Auth.swift.")
        book.apply(AgentEvent(agent: .codex, name: .stop, sessionID: "s1", message: #"{"suggestions":[]}"#), at: now)
        XCTAssertEqual(book.sessions.first?.activity, "Fixed the login bug in Auth.swift.")
    }

    func testReadableLineKeepsProseThatStartsWithABracket() {
        XCTAssertEqual(AgentSessionBook.readableLine("[WIP] tidy the tests"), "[WIP] tidy the tests")
        XCTAssertEqual(AgentSessionBook.readableLine("## Done\nAll good"), "Done")
    }

    func testTitleComesFromTheFirstMeaningfulPrompt() {
        var book = AgentSessionBook()
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "/caveman"), at: now)
        XCTAssertNil(book.sessions.first?.title)
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "remove [Image #1] island gradient\nmore"), at: now)
        XCTAssertEqual(book.sessions.first?.title, "remove island gradient")
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "something else"), at: now)
        XCTAssertEqual(book.sessions.first?.title, "remove island gradient")
    }

    func testActivityPrefersTheAgentsOwnDescription() {
        let described = AgentToolSummary(tool: "Bash", input: .object(["command": .string("python3 - <<'EOF'"),
                                                                       "description": .string("Clean up asking panel")]))
        XCTAssertEqual(described.line, "Clean up asking panel")
        let read = AgentToolSummary(tool: "Read", input: .object(["file_path": .string("/a/b/c/d/e.swift")]))
        XCTAssertEqual(read.line, "Reading …/c/d/e.swift")
        let bare = AgentToolSummary(tool: "Bash", input: .object(["command": .string("ls")]))
        XCTAssertEqual(bare.line, "Bash · ls")
    }

    func testTurnTimeAndThinkingUntilTheFirstTool() {
        var book = AgentSessionBook()
        let later = now.addingTimeInterval(30)
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "go"), at: now)
        XCTAssertEqual(book.sessions.first?.turnStartedAt, now)
        XCTAssertEqual(book.sessions.first?.usedTool, false)
        book.apply(AgentEvent(agent: .claude, name: .preToolUse, sessionID: "s1", toolName: "Bash"), at: later)
        XCTAssertEqual(book.sessions.first?.usedTool, true)
        XCTAssertEqual(book.sessions.first?.turnStartedAt, now)
    }

    private func finish(_ book: inout AgentSessionBook) {
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "go"), at: now)
        book.apply(AgentEvent(agent: .claude, name: .stop, sessionID: "s1"), at: now)
    }

    func testFinishedSessionLeavesAfterAMinute() {
        var book = AgentSessionBook()
        finish(&book)
        XCTAssertEqual(book.pruneFinished(at: now.addingTimeInterval(59)), [])
        XCTAssertEqual(book.sessions.count, 1)
        XCTAssertEqual(book.pruneFinished(at: now.addingTimeInterval(60)), ["claude:s1"])
        XCTAssertTrue(book.sessions.isEmpty)
    }

    func testIdleReminderDoesNotRestartTheClock() {
        var book = AgentSessionBook()
        finish(&book)
        book.apply(AgentEvent(agent: .claude, name: .notification, sessionID: "s1", notificationType: "idle_prompt"),
                   at: now.addingTimeInterval(50))
        XCTAssertEqual(book.pruneFinished(at: now.addingTimeInterval(60)), ["claude:s1"])
    }

    func testNewPromptKeepsTheSession() {
        var book = AgentSessionBook()
        finish(&book)
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "more"), at: now.addingTimeInterval(30))
        XCTAssertEqual(book.pruneFinished(at: now.addingTimeInterval(120)), [])
        XCTAssertEqual(book.sessions.count, 1)
    }

    func testFinishedSessionWithBackgroundWorkStays() {
        var book = AgentSessionBook()
        book.apply(event(.userPromptSubmit), at: now)
        book.apply(event(.stop, backgroundTasks: [task("a1")]), at: now)
        XCTAssertEqual(book.pruneFinished(at: now.addingTimeInterval(120)), [])
    }

    func testPlanApprovalWaitsOnTheUserWithoutARequest() {
        var book = AgentSessionBook()
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "go"), at: now)
        book.apply(AgentEvent(agent: .claude, name: .preToolUse, sessionID: "s1", toolName: "ExitPlanMode",
                              toolInput: .object(["plan": .string("# Plan")])), at: now)
        XCTAssertEqual(book.sessions.first?.state, .waiting)
        XCTAssertEqual(book.sessions.first?.activity, "Plan ready for review")
        book.apply(AgentEvent(agent: .claude, name: .postToolUse, sessionID: "s1", toolName: "ExitPlanMode"), at: now)
        XCTAssertEqual(book.sessions.first?.state, .running)
    }
}
