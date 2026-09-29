import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// A drag that edits on every step is one edit of where it began.
@Suite("Edits replayed from where a gesture began")
struct FromSnapshotTests {
    @Test("Dragging a trim past a zoom and back leaves the zoom")
    func tailOutAndBack() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.zooms = [ZoomRegion(start: time(55), duration: time(3))]
        let clip = timeline.clips[0].id
        let before = timeline
        // Out to 50 s, which drops the zoom, then back to 60 s.
        for tail in [58.0, 54.0, 50.0, 56.0, 60.0] {
            Commands.FromSnapshot(Commands.TrimClip(clipID: clip, tail: time(tail)), on: before).apply(to: &timeline)
        }
        #expect(timeline == before)
    }

    @Test("Dragging a head in and back puts the zoom where it was")
    func headInAndBack() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [Clip(sourceStart: .zero, sourceDuration: time(10)),
                          Clip(sourceStart: time(10), sourceDuration: time(50))]
        timeline.zooms = [ZoomRegion(start: time(12), duration: time(2))]
        let clip = timeline.clips[1].id
        let before = timeline
        for head in [11.0, 13.0, 10.0] {
            Commands.FromSnapshot(Commands.TrimClip(clipID: clip, head: time(head)), on: before).apply(to: &timeline)
        }
        #expect(timeline.zooms == before.zooms)
    }

    @Test("A step that changes nothing is not an edit")
    func unchanged() {
        var timeline = Timeline(sourceDuration: time(60))
        let before = timeline
        let command = Commands.FromSnapshot(Commands.TrimClip(clipID: timeline.clips[0].id, tail: time(60)), on: before)
        #expect(!command.apply(to: &timeline))
        #expect(command.name == "Trim")
    }
}

@Suite("Dragging a region's start")
struct HeadDragTests {
    @Test("Past the beginning of the edit, the end stays where it was")
    func pastZero() {
        let placed = DragGeometry.proposal(start: time(1), duration: time(2), grip: .head, offset: time(-2))
        #expect(placed.start == .zero)
        #expect(placed.duration == time(3), "still ends at 3 s")
    }
}
