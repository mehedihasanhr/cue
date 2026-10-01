import Foundation
import Testing
@testable import RecordKit

/// The library's date headings.
struct RecordingSectionTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Noon on 1 October 2026.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))! }

    private func entry(_ name: String, daysAgo: Double) -> RecordingEntry {
        RecordingEntry(url: URL(fileURLWithPath: "/tmp/\(name).klikrec"), name: name,
                       createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                       duration: 10, byteCount: 1, kinds: [])
    }

    @Test func dateOrderGroupsByTodayYesterdayTheWeekAndTheMonth() {
        let entries = [entry("a", daysAgo: 0.1), entry("b", daysAgo: 1), entry("c", daysAgo: 3),
                       entry("d", daysAgo: 5), entry("e", daysAgo: 20), entry("f", daysAgo: 45)]
        let sections = RecordingSection.group(entries, by: .date, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "September 2026", "August 2026"])
        #expect(sections.map { $0.entries.map(\.name) } == [["a"], ["b"], ["c", "d"], ["e"], ["f"]])
    }

    /// Oldest first, the headings run the other way, and nothing is reordered.
    @Test func oldestFirstKeepsTheSortsOrder() {
        let entries = [entry("f", daysAgo: 45), entry("c", daysAgo: 3), entry("a", daysAgo: 0.1)]
        let sections = RecordingSection.group(entries, by: .date, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["August 2026", "Previous 7 Days", "Today"])
        #expect(sections.flatMap(\.entries).map(\.name) == ["f", "c", "a"])
    }

    /// Sorted by name or length, headings by date would scatter the sort: one plain run.
    @Test func otherOrdersAreOneRun() {
        let entries = [entry("a", daysAgo: 0.1), entry("b", daysAgo: 40)]
        for order in [RecordingOrder.name, .length] {
            let sections = RecordingSection.group(entries, by: order, now: now, calendar: calendar)
            #expect(sections.count == 1)
            #expect(sections.first?.title == nil)
            #expect(sections.first?.entries.count == 2)
        }
        #expect(RecordingSection.group([], by: .name, now: now, calendar: calendar).isEmpty)
        #expect(RecordingSection.group([], by: .date, now: now, calendar: calendar).isEmpty)
    }
}
