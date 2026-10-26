import XCTest

/// A session's steps and to-do list, as the island's details show them.
final class AgentStepsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    private func tool(_ name: AgentEvent.Name, _ tool: String, _ input: [String: JSONValue]) -> AgentEvent {
        AgentEvent(agent: .claude, name: name, sessionID: "s1", toolName: tool, toolInput: .object(input))
    }

    func testToolCallsBecomeStepsTickedWhenDone() {
        var book = AgentSessionBook()
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "fix it"), at: now)
        book.apply(tool(.preToolUse, "Read", ["file_path": .string("/a/b/CartStore.swift")]), at: now)
        book.apply(tool(.postToolUse, "Read", ["file_path": .string("/a/b/CartStore.swift")]), at: now)
        let edit: [String: JSONValue] = ["file_path": .string("/a/Sync.swift"), "old_string": .string("a\nb"), "new_string": .string("a\nb\nc")]
        book.apply(tool(.preToolUse, "Edit", edit), at: now)
        let steps = book.sessions.first?.steps ?? []
        XCTAssertEqual(steps.map(\.title), ["Read CartStore.swift", "Edit Sync.swift"])
        XCTAssertEqual(steps.map(\.done), [true, false])
        XCTAssertEqual(steps.last?.edit, AgentEdit(file: "Sync.swift", added: 3, removed: 2))
        book.apply(AgentEvent(agent: .claude, name: .stop, sessionID: "s1"), at: now)
        XCTAssertEqual(book.sessions.first?.steps.map(\.done), [true, true])
    }

    func testNewPromptStartsAFreshListOfSteps() {
        var book = AgentSessionBook()
        book.apply(tool(.preToolUse, "Read", ["file_path": .string("/x.swift")]), at: now)
        book.apply(AgentEvent(agent: .claude, name: .userPromptSubmit, sessionID: "s1", prompt: "next"), at: now)
        XCTAssertEqual(book.sessions.first?.steps.count, 0)
    }

    func testTodoWriteSetsTheList() {
        var book = AgentSessionBook()
        let todos: JSONValue = .array([
            .object(["content": .string("Read the store"), "status": .string("completed")]),
            .object(["content": .string("Fix the total"), "status": .string("in_progress"), "activeForm": .string("Fixing the total")]),
            .object(["content": .string("Run the tests"), "status": .string("pending")]),
        ])
        book.apply(tool(.preToolUse, "TodoWrite", ["todos": todos]), at: now)
        let session = book.sessions.first
        XCTAssertEqual(session?.todos, [AgentTodo(title: "Read the store", status: .done),
                                        AgentTodo(title: "Fixing the total", status: .active),
                                        AgentTodo(title: "Run the tests", status: .pending)])
        XCTAssertEqual(session?.steps.count, 0)
    }
}
