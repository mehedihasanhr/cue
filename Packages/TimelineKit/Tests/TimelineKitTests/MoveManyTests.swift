import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Moving and resizing several things as one edit.
///
/// The reason this is a command rather than a loop over `MoveRegion` is the undo stack: a
/// drag with three chips selected is one thing the user did, and undoing it should be one
/// press of ⌘Z rather than three.
struct MoveManyTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline() -> Timeline {
        Timeline(sourceDuration: time(60),
                 zooms: [
                    ZoomRegion(id: first, start: time(2), duration: time(3)),
                    ZoomRegion(id: second, start: time(10), duration: time(4)),
                 ],
                 blurs: [BlurRegion(id: third, start: time(20), duration: time(5),
                                    rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))])
    }

    private let first = UUID()
    private let second = UUID()
    private let third = UUID()

    // MARK: -

    /// The thing a group drag has to get right: everything moves by the same amount, so
    /// the shape of the group survives.
    @Test func aGroupMovesWithoutChangingShape() {
        var edit = timeline()
        let gap = edit.zooms[1].start - edit.zooms[0].start

        #expect(Commands.MoveMany([
            .init(id: first, start: time(5)),
            .init(id: second, start: time(13)),
        ], name: "Move 2 Items").apply(to: &edit))

        #expect(edit.zooms[0].start == time(5))
        #expect(edit.zooms[1].start == time(13))
        #expect(edit.zooms[1].start - edit.zooms[0].start == gap)
        #expect(edit.zooms[0].duration == time(3), "a move keeps every length")
    }

    /// Across lanes, too: a zoom and a blur dragged together are one edit.
    @Test func aGroupCanSpanLanes() {
        var edit = timeline()
        #expect(Commands.MoveMany([
            .init(id: second, start: time(12)),
            .init(id: third, start: time(22)),
        ], name: "Move").apply(to: &edit))

        #expect(edit.zooms[1].start == time(12))
        #expect(edit.blurs[0].start == time(22))
    }

    @Test func aGroupResizeGivesEachItsOwnNewLength() {
        var edit = timeline()
        #expect(Commands.MoveMany([
            .init(id: first, start: time(2), duration: time(4)),
            .init(id: second, start: time(10), duration: time(5)),
        ], name: "Resize 2 Items").apply(to: &edit))

        #expect(edit.zooms[0].duration == time(4))
        #expect(edit.zooms[1].duration == time(5))
        #expect(edit.zooms[0].start == time(2), "resizing from the tail leaves the start alone")
    }

    /// A locked zoom refuses, exactly as it does on its own — the group does not get to
    /// override a lock by being a group.
    @Test func aLockedItemRefusesButItsNeighboursStillMove() {
        var edit = timeline()
        edit.zooms[0].isLocked = true

        #expect(Commands.MoveMany([
            .init(id: first, start: time(5)),
            .init(id: second, start: time(13)),
        ], name: "Move").apply(to: &edit))

        #expect(edit.zooms[0].start == time(2), "the locked one stayed")
        #expect(edit.zooms[1].start == time(13))
    }

    /// Nothing moved means nothing on the undo stack.
    @Test func aGroupOfNothingThatCanMoveReportsNoChange() {
        var edit = timeline()
        edit.zooms[0].isLocked = true
        #expect(!Commands.MoveMany([.init(id: first, start: time(5))], name: "Move").apply(to: &edit))
        #expect(!Commands.MoveMany([], name: "Move").apply(to: &edit))
        #expect(!Commands.MoveMany([.init(id: UUID(), start: time(5))], name: "Move").apply(to: &edit))
    }

    /// Clamped the same way a single move is, because it *is* a single move underneath.
    @Test func aGroupCannotBeDraggedOffTheEndOfTheEdit() {
        var edit = timeline()
        #expect(Commands.MoveMany([.init(id: first, start: time(-4))], name: "Move").apply(to: &edit))
        #expect(edit.zooms[0].start == .zero)
    }
}
