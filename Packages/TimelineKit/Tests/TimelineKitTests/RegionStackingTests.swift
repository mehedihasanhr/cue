import CoreGraphics
import CoreMedia
import Testing
@testable import TimelineKit

struct RegionStackingTests {
    private func note(_ start: Double, _ length: Double) -> AnnotationItem {
        AnnotationItem(start: CMTime(seconds: start, preferredTimescale: 600),
                       duration: CMTime(seconds: length, preferredTimescale: 600),
                       kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }

    @Test func regionsApartShareOneRow() {
        let notes = [note(0, 2), note(3, 2), note(6, 1)]
        let rows = RegionStacking.rows(of: notes)
        #expect(notes.allSatisfy { rows[$0.id] == 0 })
        #expect(RegionStacking.rowCount(of: notes) == 1)
    }

    @Test func overlappingRegionsStack() {
        let notes = [note(0, 3), note(1, 3), note(2, 3)]
        let rows = RegionStacking.rows(of: notes)
        #expect(notes.map { rows[$0.id] } == [0, 1, 2])
    }

    @Test func aRowIsReusedOnceItIsFree() {
        // The third starts after the first has ended, so it goes back up to the top.
        let notes = [note(0, 2), note(1, 3), note(2.5, 1)]
        let rows = RegionStacking.rows(of: notes)
        #expect(notes.map { rows[$0.id] } == [0, 1, 0])
        #expect(RegionStacking.rowCount(of: notes) == 2)
    }

    @Test func touchingIsNotOverlapping() {
        let notes = [note(0, 2), note(2, 2)]
        #expect(RegionStacking.rowCount(of: notes) == 1)
    }

    @Test func theAnswerDoesNotDependOnTheOrderGiven() {
        let a = note(4, 2), b = note(0, 5), c = note(1, 1)
        let one = RegionStacking.rows(of: [a, b, c]), other = RegionStacking.rows(of: [c, a, b])
        #expect(one == other)
        // The long one first, the short one under it, and the last into the row that is free by then.
        #expect(one[b.id] == 0 && one[c.id] == 1 && one[a.id] == 1)
    }

    @Test func anEmptyLaneIsOneRow() {
        #expect(RegionStacking.rowCount(of: [AnnotationItem]()) == 1)
    }
}
