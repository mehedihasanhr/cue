import XCTest

/// How a Sensory OS task and a Cue task name the same things, what counts as a change
/// to send, and the dates the website writes.
@MainActor
final class SensoryOSTests: XCTestCase {
    private func wire(title: String = "Call the roofer", description: String = "", status: String = "todo", priority: String? = nil) -> SOSTask {
        SOSTask(id: "95059c7a-c040-4e4e-ae33-dae6221d317f", boardId: "62964c4e-b4f0-4671-95c7-2c67f2c23ea1", sectionId: nil,
                title: title, description: description, status: status, priority: priority, dueAt: nil, dueHasTime: false,
                assignedToMe: true, createdAt: .now, updatedAt: .now, href: nil)
    }

    private func local(from wire: SOSTask) -> TaskItem {
        var task = TaskItem(id: SOSMap.taskID(wire.id), text: "", projectID: nil, status: .pending, priority: .medium, createdAt: .now, updatedAt: .now)
        SOSMap.apply(SOSMap.values(of: wire), to: &task)
        return task
    }

    func testStatusesMapBothWays() {
        for status in TaskStatus.allCases {
            XCTAssertEqual(SOSMap.status(SOSMap.wire(status)), status)
        }
        XCTAssertEqual(SOSMap.wire(.pending), "todo")
        XCTAssertEqual(SOSMap.wire(.inProcess), "in_progress")
        XCTAssertEqual(SOSMap.wire(.review), "in_review")
        XCTAssertEqual(SOSMap.wire(.complete), "done")
        XCTAssertEqual(SOSMap.status("something new"), .pending)
    }

    func testATaskWithoutADescriptionIsItsTitle() {
        let task = local(from: wire())
        XCTAssertEqual(task.text, "Call the roofer")
        XCTAssertNil(task.customTitle)
        XCTAssertEqual(SOSMap.values(of: task).description, "")
    }

    func testADescriptionRoundTripsEvenWhenItStartsWithTheTitle() {
        // the title kept as the task's own name, so the description's first line is not taken for it
        let from = wire(title: "Order shingles", description: "Order shingles\n\n- 30 bundles")
        let values = SOSMap.values(of: local(from: from))
        XCTAssertEqual(values.title, "Order shingles")
        XCTAssertEqual(values.description, "Order shingles\n\n- 30 bundles")
    }

    func testNothingTakenFromTheWebsiteCountsAsAChange() {
        let from = wire(description: "Ask about the quote", status: "in_review", priority: "high")
        XCTAssertNil(SOSMap.changes(SOSMap.values(of: local(from: from)), from: SOSMap.values(of: from)))
    }

    func testAMissingPriorityIsNotSentBackAsMedium() {
        let from = wire(priority: nil)
        var task = local(from: from)
        XCTAssertEqual(task.priority, .medium)
        XCTAssertNil(SOSMap.changes(SOSMap.values(of: task), from: SOSMap.values(of: from)))
        task.priority = .urgent
        XCTAssertNotNil(SOSMap.changes(SOSMap.values(of: task), from: SOSMap.values(of: from)))
    }

    func testAnEditHereIsAChange() {
        let from = wire()
        var task = local(from: from)
        task.status = .complete
        XCTAssertEqual(SOSMap.changes(SOSMap.values(of: task), from: SOSMap.values(of: from))?.status, .complete)
    }

    func testATaskMadeHereSendsItsBodyAsTheDescription() {
        let task = TaskItem(text: "Order shingles\n\nAsk for **GAF**", projectID: nil)
        let values = SOSMap.values(of: task)
        XCTAssertEqual(values.title, "Order shingles")
        XCTAssertEqual(values.description, "Ask for **GAF**")
    }

    func testProjectIdsAreStable() {
        XCTAssertEqual(SOSMap.uuid("root"), SOSMap.rootID)
        XCTAssertEqual(SOSMap.agencyID("a"), SOSMap.agencyID("a"))
        XCTAssertNotEqual(SOSMap.agencyID("a"), SOSMap.agencyID("b"))
        XCTAssertEqual(SOSMap.boardID("62964c4e-b4f0-4671-95c7-2c67f2c23ea1").uuidString.lowercased(), "62964c4e-b4f0-4671-95c7-2c67f2c23ea1")
    }

    func testDatesFromPostgresAndJavaScriptBothRead() {
        XCTAssertNotNil(SOSDates.date("2026-11-19T06:56:20.123456+00:00"))
        XCTAssertNotNil(SOSDates.date("2026-11-19T06:56:20.123Z"))
        XCTAssertNotNil(SOSDates.date("2026-11-19T06:56:20Z"))
        XCTAssertNil(SOSDates.date("yesterday"))
        let micro = SOSDates.date("2026-11-19T06:56:20.999999+00:00")!
        XCTAssertEqual(micro.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.999, accuracy: 0.001)
    }

    func testOnlyThisMachineMayUsePlainHTTP() {
        XCTAssertNotNil(SOSServer.origin(from: "https://os.sensory-creative.com/"))
        XCTAssertNotNil(SOSServer.origin(from: "http://localhost:3477"))
        XCTAssertNil(SOSServer.origin(from: "http://example.com"))
        XCTAssertNil(SOSServer.origin(from: "ftp://example.com"))
        XCTAssertEqual(SOSServer.origin(from: "https://os.sensory-creative.com/app/tasks")?.absoluteString, "https://os.sensory-creative.com")
    }
}
