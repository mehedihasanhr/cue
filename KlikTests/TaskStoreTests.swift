import XCTest

/// Projects nest; tasks roll up into their parents.
final class TaskStoreTests: XCTestCase {
    @MainActor
    func testNestedProjectsAndTaskRollUp() throws {
        let store = TaskStore()
        // A clean slate regardless of what is on this Mac.
        for project in store.projects { store.deleteProject(project) }
        for task in store.tasks { store.delete(task) }

        let work = try XCTUnwrap(store.addProject(named: "Work"))
        let klik = try XCTUnwrap(store.addProject(named: "Klik", in: work.id))
        let island = try XCTUnwrap(store.addProject(named: "Island", in: klik.id))
        XCTAssertEqual(store.subprojects(of: nil).map(\.name), ["Work"])
        XCTAssertEqual(store.subprojects(of: work.id).map(\.name), ["Klik"])
        XCTAssertEqual(store.path(to: island.id).map(\.name), ["Work", "Klik", "Island"])

        let a = try XCTUnwrap(store.addTask(titled: "Ship the notch", in: island.id))
        let b = try XCTUnwrap(store.addTask(titled: "Write tests", in: klik.id))
        _ = store.addTask(titled: "Loose task", in: nil)
        XCTAssertNil(store.addTask(titled: "   ", in: nil))
        XCTAssertEqual(store.tasks(in: work.id).count, 2)
        XCTAssertEqual(store.tasks(in: island.id).map(\.id), [a.id])
        XCTAssertEqual(store.tasks(in: nil).count, 3)

        store.setStatus(.complete, for: a)
        XCTAssertEqual(store.tasks.first { $0.id == a.id }?.status, .complete)
        XCTAssertEqual(TaskStatus.pending.next, .inProcess)
        XCTAssertEqual(TaskStatus.complete.next, .pending)

        store.move(b, to: island.id)
        XCTAssertEqual(store.tasks(in: island.id).count, 2)

        // Deleting a project takes its sub-projects with it; their tasks survive unfiled.
        store.deleteProject(klik)
        XCTAssertEqual(store.projects.map(\.name), ["Work"])
        XCTAssertEqual(store.tasks.count, 3)
        XCTAssertTrue(store.tasks.allSatisfy { $0.projectID == nil })

        for project in store.projects { store.deleteProject(project) }
        for task in store.tasks { store.delete(task) }
    }
}
