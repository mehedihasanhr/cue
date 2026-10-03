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
}
