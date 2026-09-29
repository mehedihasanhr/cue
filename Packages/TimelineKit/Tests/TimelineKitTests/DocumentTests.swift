import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// The document: undo coalescing, what survives a bad project file, and selection.
@MainActor
struct DocumentTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A package on disk with a manifest and nothing else, in a folder that goes away
    /// with the test.
    private func makeDocument(projectJSON: String? = nil,
                              duration: Double = 30) throws -> (EditorDocument, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KlikStudioTests-\(UUID().uuidString)", isDirectory: true)
        let package = try RecordingPackage.create(named: "Take", in: folder)
        let manifest = RecordingManifest(name: "Take", duration: duration)
        try package.write(manifest)
        if let projectJSON {
            try Data(projectJSON.utf8)
                .write(to: package.url.appendingPathComponent(EditorDocument.projectFileName))
        }
        return (try EditorDocument(package: package), folder)
    }

    // MARK: - Undo coalescing

    @Test func aDragIsOneUndoEntryHoweverManyCommandsItApplies() throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(2), duration: time(4))))
        let id = try #require(document.timeline.zooms.first?.id)
        let settled = document.timeline

        // What a drag does: one begin, a command per mouse-move, one end.
        document.beginInteraction("Move Zoom")
        for step in 1...40 {
            document.apply(Commands.MoveRegion(id: id, start: time(2 + Double(step) * 0.1)))
        }
        document.endInteraction()

        #expect(document.timeline.zooms.first?.start != settled.zooms.first?.start)
        document.undo()
        #expect(document.timeline == settled, "one undo steps back over the whole drag")
        #expect(!document.canUndo == false, "the zoom that was added is still undoable")
    }

    @Test func theUndoEntryIsNamedForTheInteractionNotTheLastCommand() throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(2), duration: time(4))))
        let id = try #require(document.timeline.zooms.first?.id)

        document.beginInteraction("Resize Zoom")
        document.apply(Commands.MoveRegion(id: id, start: time(2), duration: time(6)))
        document.endInteraction()

        #expect(document.undoName == "Resize Zoom")
    }

    @Test func applyRecordsAgainOnceTheInteractionEnds() throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.beginInteraction("Drag")
        document.apply(Commands.AddZoom(ZoomRegion(start: time(1), duration: time(2))))
        document.endInteraction()
        document.apply(Commands.AddZoom(ZoomRegion(start: time(8), duration: time(2))))

        #expect(document.timeline.zooms.count == 2)
        document.undo()
        #expect(document.timeline.zooms.count == 1, "the second add undid on its own")
        document.undo()
        #expect(document.timeline.zooms.isEmpty, "the drag undid as one step")
    }

    @Test func aCommandThatChangesNothingNeverLandsOnTheStack() throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(document.apply(Commands.DeleteRegion(id: UUID())) == false)
        #expect(document.canUndo == false)
    }

    // MARK: - Reading a project back

    @Test func aProjectWrittenBeforeFormatVersionStillReads() throws {
        // No `formatVersion`, no `crop`, no `blurs` — a file from an older build.
        let json = """
        {
          "sourceDuration": {"value": 18000, "timescale": 600, "flags": 1, "epoch": 0},
          "clips": [{"id": "\(UUID().uuidString)",
                     "sourceStart": {"value": 0, "timescale": 600, "flags": 1, "epoch": 0},
                     "sourceDuration": {"value": 18000, "timescale": 600, "flags": 1, "epoch": 0},
                     "speed": 1}],
          "zooms": [], "annotations": [], "captions": [], "audio": []
        }
        """
        let (document, folder) = try makeDocument(projectJSON: json)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(document.timeline.formatVersion == Timeline.currentFormat)
        #expect(document.timeline.clips.count == 1)
        #expect(document.timeline.duration.seconds == 30)
        #expect(document.timeline.blurs.isEmpty)
    }

    @Test func oneUnreadableFieldDoesNotCostTheWholeEdit() throws {
        // A real project, with `style` replaced by a background case a newer build
        // wrote. Everything the user actually cut has to survive it.
        var original = Timeline(sourceDuration: time(30))
        original.zooms = [ZoomRegion(start: time(1), duration: time(4), scale: 2.5)]
        let encoded = try JSONEncoder().encode(original)
        var fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields["style"] = ["background": ["hologram": ["mood": "teal"]], "padding": 0.2]
        let json = try JSONSerialization.data(withJSONObject: fields)

        let (document, folder) = try makeDocument(projectJSON: String(decoding: json, as: UTF8.self))
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(document.timeline.zooms.count == 1, "the zoom survived the unreadable style")
        #expect(document.timeline.zooms.first?.scale == 2.5)
        // The style used to fall back whole. Now that it reads field by field, only the
        // background this build cannot draw is replaced, and the padding beside it stays.
        #expect(document.timeline.style.padding == 0.2, "the style kept what it could read")
        #expect(document.timeline.style.background == FrameStyle().background)
    }

    @Test func aProjectWithNoClipsGetsOneCoveringTheRecording() throws {
        let json = """
        {"sourceDuration": {"value": 18000, "timescale": 600, "flags": 1, "epoch": 0}, "clips": []}
        """
        let (document, folder) = try makeDocument(projectJSON: json)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(document.timeline.clips.count == 1)
        #expect(document.timeline.duration.seconds == 30)
    }

    @Test func aProjectRoundTripsThroughSave() throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(3), duration: time(5), scale: 3)))
        #expect(document.isDirty)
        try document.save()
        #expect(!document.isDirty)

        let reopened = try EditorDocument(package: document.package)
        #expect(reopened.timeline == document.timeline)
        #expect(reopened.hasBeenEdited)
    }

    // MARK: - Selection

    @Test func selectionSurvivesASplitOnTheLeftHalf() {
        var timeline = Timeline(sourceDuration: time(30))
        let id = timeline.clips[0].id
        ClipSequence.split(&timeline, at: time(10))

        #expect(Selection.clip(id).isValid(in: timeline))
        #expect(timeline.clips.first?.id == id)
        #expect(timeline.clips.count == 2)
    }

    @Test func selectionSurvivesASpeedChange() {
        var timeline = Timeline(sourceDuration: time(30))
        let id = timeline.clips[0].id
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, duration: time(30)), speed: 2)

        #expect(Selection.clip(id).isValid(in: timeline))
    }

    @Test func aRegionClampedAwayInvalidatesTheSelection() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [ZoomRegion(start: time(25), duration: time(4))]
        let id = timeline.zooms[0].id
        #expect(Selection.zoom(id).isValid(in: timeline))

        // Delete the stretch the zoom sat on.
        ClipSequence.delete(&timeline, range: CMTimeRange(start: time(20), end: time(30)))
        #expect(!Selection.zoom(id).isValid(in: timeline))
    }

    @Test func trimSelectionsOnlyExistWhenSomethingIsTrimmedAway() {
        var timeline = Timeline(sourceDuration: time(30))
        #expect(!Selection.headTrim.isValid(in: timeline))
        #expect(!Selection.tailTrim.isValid(in: timeline))

        let id = timeline.clips[0].id
        ClipSequence.trim(&timeline, clipID: id, head: time(5), tail: nil)
        #expect(Selection.headTrim.isValid(in: timeline))
    }

    @Test func aSelectedRegionReportsItsStretchOfTimeline() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [ZoomRegion(start: time(4), duration: time(6))]
        let range = Selection.zoom(timeline.zooms[0].id).range(in: timeline)
        #expect(range?.start.seconds == 4)
        #expect(range?.duration.seconds == 6)
    }

    // MARK: - Snapping

    @Test func snappingTightensAsTheTimelineZoomsIn() {
        let boundaries = [time(0), time(10)]
        let close = Snapping(pointsPerSecond: 200)
        #expect(close.snap(time(10.02), to: boundaries) == time(10), "40ms is within 8pt at 200pt/s")
        #expect(close.snap(time(10.2), to: boundaries) != time(10))
    }

    @Test func snappingStopsBeingSwallowedWhenZoomedAllTheWayOut() {
        // At half a point per second, eight points is sixteen seconds. Without the cap
        // every drag on a long recording lands on the nearest cut.
        let boundaries = [time(0), time(600)]
        let wide = Snapping(pointsPerSecond: 0.5)
        #expect(wide.snap(time(590), to: boundaries) == time(590))
        #expect(wide.snap(time(599.9), to: boundaries) == time(600), "still snaps up close")
    }

    @Test func snappingCanBeTurnedOff() {
        #expect(Snapping.disabled.snap(time(10.001), to: [time(10)]) == time(10.001))
    }
    // MARK: - The zoom verbs on the undo stack

    /// Split, aim, reset, merge: four edits, four entries, and the take is back where it
    /// started after four undos.
    ///
    /// Worth a document test rather than a timeline one because the thing that goes wrong
    /// here is not the arithmetic: a "reset" written as several commands would cost the user
    /// three ⌘Z to undo one button, and a verb that returns true when it changed nothing
    /// would leave an entry that undoes to the same picture.
    @Test func eachZoomVerbIsExactlyOneUndoStep() throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(2), duration: time(10),
                                                   scale: 4, easing: .linear,
                                                   transition: time(1.5))))
        let id = try #require(document.timeline.zooms.first?.id)
        let laid = document.timeline

        #expect(document.apply(Commands.SplitZoom(id: id, at: time(7))))
        #expect(document.timeline.zooms.count == 2)
        let secondID = try #require(document.timeline.zooms.last?.id)

        #expect(document.apply(Commands.RestyleZoom(id: secondID, name: "Aim Zoom") {
            $0.center = CGPoint(x: 0.2, y: 0.8)
            $0.followsCursor = false
        }))
        #expect(document.apply(Commands.RestyleZoom(id: secondID, name: "Reset Zoom") {
            $0 = ZoomLane.reset($0)
        }))
        #expect(document.timeline.zooms.last?.scale == ZoomRegion.defaultScale)
        #expect(document.apply(Commands.MergeZooms(id, secondID)))
        #expect(document.timeline.zooms.count == 1)

        for _ in 0..<4 { document.undo() }
        #expect(document.timeline == laid, "four verbs, four undos, and the zoom is as it was laid")
    }

    @Test func aVerbThatChangesNothingLeavesNothingToUndo() throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(2), duration: time(4))))
        let id = try #require(document.timeline.zooms.first?.id)
        let name = document.undoName

        // Too close to the end to cut, nothing to merge with, and a lock already unset.
        #expect(!document.apply(Commands.SplitZoom(id: id, at: time(2.01))))
        #expect(!document.apply(Commands.MergeZooms(id, id)))
        #expect(!document.apply(Commands.RestyleZoom(id: id, name: "Unlock Zoom") { $0.isLocked = false }))
        #expect(document.undoName == name, "none of them reached the stack")
    }

}
