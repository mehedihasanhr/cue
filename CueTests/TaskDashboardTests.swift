import AppKit
import XCTest

/// The task dashboard's lists, search, ordering and link.
final class TaskDashboardTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var yesterday: Date { now.addingTimeInterval(-86_400) }
    private let project = UUID()

    private func task(_ text: String, status: TaskStatus = .pending, priority: TaskPriority = .medium,
                      project: UUID? = nil, created: Date? = nil, updated: Date? = nil) -> TaskItem {
        let created = created ?? yesterday
        return TaskItem(id: UUID(), text: text, projectID: project, status: status, priority: priority, createdAt: created, updatedAt: updated ?? created)
    }

    func testListsFilterAsNamed() {
        let urgentOpen = task("Ship", priority: .urgent)
        let urgentDone = task("Shipped", status: .complete, priority: .urgent)
        let inProject = task("Write docs", project: project)
        let madeToday = task("Today's", created: now)
        let changedToday = task("Touched", updated: now)
        let all = [urgentOpen, urgentDone, inProject, madeToday, changedToday]

        func titles(_ list: TaskDashboardList) -> Set<String> {
            Set(TaskDashboardQuery.filter(all, list: list, now: now, calendar: calendar).map(\.title))
        }
        XCTAssertEqual(titles(.all).count, 5)
        XCTAssertEqual(titles(.urgent), ["Ship"], "Urgent leaves out what is complete")
        XCTAssertEqual(titles(.completed), ["Shipped"])
        XCTAssertEqual(titles(.unassigned), ["Ship", "Shipped", "Today's", "Touched"])
        XCTAssertEqual(titles(.today), ["Today's", "Touched"], "Today is made or changed today")
    }

    func testCountsAreOpenTasksExceptOnCompleted() {
        let all = [task("A"), task("B", status: .inProcess), task("C", status: .complete), task("D", status: .complete)]
        XCTAssertEqual(TaskDashboardQuery.count(all, list: .all, now: now, calendar: calendar), 2)
        XCTAssertEqual(TaskDashboardQuery.count(all, list: .completed, now: now, calendar: calendar), 2)
    }

    func testSearchNeedsEveryWordInAnyOrderAndCase() {
        let item = task("Fix the login bug\n\nSafari only, after **OAuth** redirect")
        XCTAssertTrue(TaskDashboardQuery.matches(item, query: "login"))
        XCTAssertTrue(TaskDashboardQuery.matches(item, query: "safari LOGIN"), "words in any order and case, the description included")
        XCTAssertFalse(TaskDashboardQuery.matches(item, query: "login chrome"))
        XCTAssertTrue(TaskDashboardQuery.matches(item, query: "   "), "an empty search matches everything")
    }

    func testOrderIsPriorityThenNewest() {
        let oldUrgent = task("old urgent", priority: .urgent, created: yesterday)
        let newLow = task("new low", priority: .low, created: now)
        let oldMedium = task("old medium", created: yesterday)
        let newMedium = task("new medium", created: now)
        let sorted = TaskDashboardQuery.sorted([newLow, oldMedium, newMedium, oldUrgent]).map(\.title)
        XCTAssertEqual(sorted, ["old urgent", "new medium", "old medium", "new low"])
    }

    func testADraggedOrderWinsAndNewTasksComeFirst() {
        let a = task("a"), b = task("b"), c = task("c", priority: .urgent), fresh = task("fresh", created: now)
        let order = TaskDashboardQuery.reordered([a, b, c], order: [], moving: a.id, to: b.id, below: true)
        XCTAssertEqual(TaskDashboardQuery.sorted([a, b, c], order: order).map(\.title), ["c", "b", "a"])
        XCTAssertEqual(TaskDashboardQuery.sorted([a, b, c, fresh], order: order).first?.title, "fresh", "a task never placed goes on top")
        let back = TaskDashboardQuery.reordered([a, b, c], order: order, moving: a.id, to: c.id, below: false)
        XCTAssertEqual(TaskDashboardQuery.sorted([a, b, c], order: back).map(\.title), ["a", "c", "b"])
        XCTAssertEqual(TaskDashboardQuery.reordered([a, b], order: order, moving: a.id, to: a.id, below: true), order, "onto itself, nothing moves")
    }

    func testGroupsFollowStatusOrderAndSkipEmptyOnes() {
        let groups = TaskDashboardQuery.grouped([task("done", status: .complete), task("doing", status: .inProcess), task("todo")])
        XCTAssertEqual(groups.map(\.status), [.pending, .inProcess, .complete], "to do first, then in process; no Review group without review tasks")
    }

    func testSelectionRoundTripsThroughItsStoredForm() {
        for selection in [TaskDashboardSelection.list(.today), .list(.all), .project(project)] {
            XCTAssertEqual(TaskDashboardSelection(rawValue: selection.rawValue), selection)
        }
        XCTAssertNil(TaskDashboardSelection(rawValue: "list:nonsense"))
        XCTAssertNil(TaskDashboardSelection(rawValue: "project:not-a-uuid"))
        XCTAssertNil(TaskDashboardSelection(rawValue: ""))
    }

    // MARK: - Titles

    func testTitleIsTakenFromTheDescriptionUntilRenamed() {
        var item = task("Fix the login bug\n\nSafari only, after the redirect")
        XCTAssertEqual(item.title, "Fix the login bug")
        XCTAssertEqual(item.text, "Fix the login bug\n\nSafari only, after the redirect", "the description keeps every line")
        XCTAssertEqual(item.summary, "Safari only, after the redirect", "a card does not repeat the line the title came from")

        item.customTitle = "Login on Safari"
        XCTAssertEqual(item.title, "Login on Safari")
        XCTAssertEqual(item.text, "Fix the login bug\n\nSafari only, after the redirect", "renaming leaves the description alone")
        XCTAssertEqual(item.summary, "Fix the login bug Safari only, after the redirect", "with a title of its own, the whole description is the preview")
    }

    func testPreviewsSkipLinesThatAreOnlyAnImageOrFile() {
        let item = task("Ship it\n\n![image](cue://A.png)\n\nMake the page fast\n\n[spec.pdf](cue-file://1/spec.pdf)")
        XCTAssertEqual(item.summary, "Make the page fast")
        var renamed = item
        renamed.customTitle = "Release"
        XCTAssertEqual(renamed.summary, "Ship it Make the page fast")
        XCTAssertFalse(TaskText.isMediaLine("See [the spec](https://x.y) first"), "a link in a sentence is text")
    }

    func testLongTitlesAreCutAtAWord() {
        let long = String(repeating: "word ", count: 40)
        let title = TaskText.autoTitle(of: long)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, TaskText.autoTitleLength + 1)
        XCTAssertFalse(title.dropLast().hasSuffix(" "), "no space before the ellipsis")
        XCTAssertEqual(TaskText.autoTitle(of: "Short"), "Short")
    }

    func testATitleTheSameAsTheDescriptionsFollowsIt() {
        XCTAssertNil(TaskText.customTitle("Fix the login bug", for: "Fix the login bug\nmore"))
        XCTAssertEqual(TaskText.customTitle("Login", for: "Fix the login bug\nmore"), "Login")
    }

    func testTasksSavedBeforeCustomTitlesStillRead() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"Ship it\n\nnotes","title":"Ship it","status":"pending","priority":"high","createdAt":0,"updatedAt":0}"#
        let item = try JSONDecoder().decode(TaskItem.self, from: Data(old.utf8))
        XCTAssertNil(item.customTitle)
        XCTAssertEqual(item.title, "Ship it")

        var renamed = item
        renamed.customTitle = "Release"
        let again = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(renamed))
        XCTAssertEqual(again.customTitle, "Release")
        XCTAssertEqual(again.text, "Ship it\n\nnotes")
    }

    func testAServerTitleUnlikeTheDescriptionIsARename() throws {
        func remote(_ title: String, _ text: String) throws -> TaskItem {
            let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"\#(title)","text":"\#(text)"}"#
            return try TaskWire.decoder.decode(RemoteTask.self, from: Data(json.utf8)).item
        }
        XCTAssertNil(try remote("Ship it", "Ship it\\nnotes").customTitle, "the title the text gives is not a rename")
        XCTAssertEqual(try remote("Release", "Ship it\\nnotes").customTitle, "Release")
        let titleOnly = try remote("Just a title", "")
        XCTAssertEqual(titleOnly.text, "Just a title")
        XCTAssertNil(titleOnly.customTitle)
    }

    func testPageIconsRoundTripThroughTheirStoredForm() {
        for icon in [PageIcon.symbol("flame"), .emoji("🚀"), .emoji("⭐️"), .symbol("chevron.left.forwardslash.chevron.right")] {
            XCTAssertEqual(PageIcon(rawValue: icon.rawValue), icon)
        }
        XCTAssertNil(PageIcon(rawValue: "emoji:"))
        XCTAssertNil(PageIcon(rawValue: "image:cat"))
        XCTAssertEqual(Set(PageIcon.emoji).count, PageIcon.emoji.count, "no emoji offered twice")
        XCTAssertEqual(Set(PageIcon.symbols).count, PageIcon.symbols.count, "no symbol offered twice")
    }

    func testOfferedSymbolsExist() {
        let missing = PageIcon.symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [], "every symbol in the picker draws")
    }

    func testTasksLinkOpensTheDashboard() {
        XCTAssertEqual(URLCommand(URL(string: "cue://tasks")!), .tasks)
        XCTAssertEqual(URLCommand(URL(string: "cue://tasks/dashboard")!), .tasks)
        XCTAssertEqual(URLCommand(URL(string: "cue://task/new")!), .newTask(title: nil, notes: "", priority: .medium, project: nil), "cue://task still makes a task")
    }
}
