import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func region(_ start: Double, _ duration: Double, _ layout: CameraLayout) -> CameraLayoutRegion {
    CameraLayoutRegion(start: time(start), duration: time(duration), layout: layout)
}

private func timeline(_ regions: [CameraLayoutRegion] = [], length: Double = 60) -> Timeline {
    var timeline = Timeline(sourceDuration: time(length))
    timeline.cameraLayouts = regions
    return timeline
}

/// Which camera layout is in force, and how one becomes the next.
@Suite("Camera layouts over time")
struct CameraLayoutTimingTests {
    @Test("With no lane the bubble is everywhere")
    func noLane() {
        let plain = timeline()
        for moment in [0.0, 3.3, 59.9] {
            #expect(plain.cameraLayout(at: time(moment)) == .steady(.bubble))
        }
    }

    @Test("A region is fully in force between its two changes, and the bubble either side")
    func steadyInside() {
        let edit = timeline([region(2, 4, .cameraOnly)])
        #expect(edit.cameraLayout(at: time(1.9)) == .steady(.bubble))
        #expect(edit.cameraLayout(at: time(2.5)) == .steady(.cameraOnly))
        #expect(edit.cameraLayout(at: time(5.5)) == .steady(.cameraOnly))
        #expect(edit.cameraLayout(at: time(6)) == .steady(.bubble))
    }

    /// Both changes happen inside the chip, so nothing a region does leaks onto the stretch
    /// beside it: it arrives over its first third of a second and leaves over its last.
    @Test("Arriving and leaving both happen inside the region")
    func transitionsInside() {
        let edit = timeline([region(2, 4, .sideBySide)])
        let arriving = edit.cameraLayout(at: time(2 + Timeline.cameraLayoutTransition / 2))
        #expect(arriving.from == .bubble && arriving.to == .sideBySide)
        #expect(abs(arriving.progress - 0.5) < 0.001, "half-way through the ramp, half-way there")

        let starting = edit.cameraLayout(at: time(2))
        #expect(starting.from == .bubble && starting.progress == 0, "at its first frame it has not moved yet")

        let leaving = edit.cameraLayout(at: time(6 - Timeline.cameraLayoutTransition / 2))
        #expect(leaving.from == .sideBySide && leaving.to == .bubble)
        #expect(abs(leaving.progress - 0.5) < 0.001)
        #expect(!leaving.isSteady)
    }

    /// Eased, and continuous: the value on each side of a boundary is the same.
    @Test("A change never jumps")
    func continuous() {
        let edit = timeline([region(2, 4, .hidden), region(6, 3, .cameraOnly)])
        var last: Double?
        var moment = 1.5
        while moment < 9.5 {
            let state = edit.cameraLayout(at: time(moment))
            // How much of the camera is showing the full frame, as a number that has to
            // move smoothly through every change.
            let value = state.share(of: .cameraOnly) * 2 + state.share(of: .hidden)
            if let last { #expect(abs(value - last) < 0.2, "jumped at \(moment)") }
            last = value
            moment += 1.0 / 60
        }
    }

    /// Two stretches side by side change straight from one to the other, rather than
    /// stopping at the bubble in between.
    @Test("Neighbouring regions change straight from one to the other")
    func neighbours() {
        let edit = timeline([region(2, 3, .cameraOnly), region(5, 3, .sideBySide)])
        #expect(edit.cameraLayout(at: time(4.9)) == .steady(.cameraOnly), "the first does not leave for the bubble")
        let changing = edit.cameraLayout(at: time(5.1))
        #expect(changing.from == .cameraOnly && changing.to == .sideBySide)
    }

    @Test("A region saying Bubble next to plain bubble changes nothing")
    func bubbleIsNotAChange() {
        let edit = timeline([region(2, 3, .bubble)])
        for moment in [1.9, 2.0, 2.1, 4.9, 5.0] {
            #expect(edit.cameraLayout(at: time(moment)) == .steady(.bubble))
        }
    }

    @Test("A region at the very start has nothing to arrive from")
    func atTheStart() {
        let edit = timeline([region(0, 3, .cameraOnly)])
        #expect(edit.cameraLayout(at: .zero) == .steady(.cameraOnly))
        #expect(edit.cameraLayout(at: time(0.1)) == .steady(.cameraOnly))
    }

    /// A short region never spends more than half of itself arriving, or it would still be
    /// arriving when it started to leave.
    @Test("A short region shares itself between its two changes")
    func shortRegion() {
        let edit = timeline([region(2, 0.4, .hidden)])
        let middle = edit.cameraLayout(at: time(2.2))
        #expect(middle.share(of: .hidden) > 0.999, "fully hidden at its middle")
        let early = edit.cameraLayout(at: time(2.1))
        #expect(abs(early.progress - 0.5) < 0.001, "the ramp is half the region, 0.2 s")
    }

    @Test("Where two overlap, the later one wins")
    func overlap() {
        let edit = timeline([region(2, 10, .cameraOnly), region(5, 2, .hidden)])
        #expect(edit.cameraLayout(at: time(6)) == .steady(.hidden))
        #expect(edit.cameraLayout(at: time(4)) == .steady(.cameraOnly))
        #expect(edit.cameraLayout(at: time(9)) == .steady(.cameraOnly))
        #expect(edit.cameraLayoutRegion(at: time(6))?.layout == .hidden)
        #expect(edit.cameraLayoutRegion(at: time(1)) == nil)
    }

    /// The lane is read from scratch at every moment, so the order the moments are asked
    /// in cannot matter — which is what makes scrubbing to a frame the same as playing to
    /// it.
    @Test("Scrubbing gives the answer playing does")
    func stateless() {
        let edit = timeline([region(1, 2, .sideBySide), region(3, 1, .hidden), region(6, 4, .cameraOnly)])
        let moments = stride(from: 0.0, to: 11, by: 0.05).map { $0 }
        let played = moments.map { edit.cameraLayout(at: time($0)) }
        let scrubbed = moments.shuffled().map { ($0, edit.cameraLayout(at: time($0))) }
        for (moment, state) in scrubbed {
            let index = Int((moment / 0.05).rounded())
            #expect(played[index] == state)
        }
    }

    @Test("Snapping sees the lane's edges")
    func boundaries() {
        let edit = timeline([region(2, 4, .hidden)])
        #expect(edit.boundaries.contains(time(2)))
        #expect(edit.boundaries.contains(time(6)))
    }
}

/// What is written and read back.
@Suite("Camera layouts in a saved project")
struct CameraLayoutCodingTests {
    @Test("A project written before layouts opens with none")
    func oldProject() throws {
        let json = """
        { "sourceDuration": { "value": 6000, "timescale": 600, "flags": 1, "epoch": 0 },
          "webcam": { "isEnabled": true, "corner": "topLeft", "position": [0.5, 0.5],
                      "size": 0.3, "roundness": 0.5, "isMirrored": false,
                      "shadowOpacity": 0.2, "reactsToZoom": false } }
        """
        let decoded = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(decoded.cameraLayouts.isEmpty)
        #expect(decoded.cameraLayout(at: time(3)) == .steady(.bubble))
    }

    @Test("A layout from a newer build reads as the bubble, and keeps its place")
    func unknownLayout() throws {
        let json = """
        { "id": "7A0E1B4C-2F0E-4F43-9C39-2D0C5E0B6A11",
          "start": { "value": 600, "timescale": 600, "flags": 1, "epoch": 0 },
          "duration": { "value": 1200, "timescale": 600, "flags": 1, "epoch": 0 },
          "layout": "pictureInPictureInPicture" }
        """
        let decoded = try JSONDecoder().decode(CameraLayoutRegion.self, from: Data(json.utf8))
        #expect(decoded.layout == .bubble)
        #expect(decoded.start == time(1))
        #expect(decoded.duration == time(2))
    }

    @Test("An unreadable lane costs the lane and nothing else")
    func unreadableLane() throws {
        let json = """
        { "sourceDuration": { "value": 6000, "timescale": 600, "flags": 1, "epoch": 0 },
          "cameraLayouts": "not a list",
          "webcam": { "isEnabled": true } }
        """
        let decoded = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(decoded.cameraLayouts.isEmpty)
        #expect(decoded.webcam.isEnabled)
    }

    @Test("Layouts survive being saved and opened")
    func roundTrip() throws {
        let edit = timeline([region(1, 2, .sideBySide), region(4, 3, .hidden)])
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(edit))
        #expect(decoded.cameraLayouts == edit.cameraLayouts)
    }
}

/// The lane's own edits.
@Suite("Editing the camera lane")
struct CameraLayoutCommandTests {
    @Test("Adding one switches the camera on, in the same edit")
    func addSwitchesOn() {
        var edit = timeline()
        #expect(!edit.webcam.isEnabled)
        let command = Commands.AddCameraLayout(region(3, 5, .cameraOnly))
        #expect(command.apply(to: &edit))
        #expect(edit.cameraLayouts.count == 1)
        #expect(edit.webcam.isEnabled)
        #expect(command.name == "Camera Only")
    }

    @Test("Hiding the camera does not switch it on")
    func hideLeavesItOff() {
        var edit = timeline()
        #expect(Commands.AddCameraLayout(region(3, 5, .hidden)).apply(to: &edit))
        #expect(!edit.webcam.isEnabled)
        #expect(Commands.AddCameraLayout(region(3, 5, .hidden)).name == "Hide Camera")
    }

    @Test("A region past the end is refused, and one running over it is cut to fit")
    func keptInsideTheEdit() {
        var edit = timeline(length: 10)
        #expect(!Commands.AddCameraLayout(region(12, 2, .hidden)).apply(to: &edit))
        #expect(Commands.AddCameraLayout(region(8, 5, .hidden)).apply(to: &edit))
        #expect(edit.cameraLayouts[0].end == time(10))
    }

    @Test("The lane is kept in time order")
    func sorted() {
        var edit = timeline()
        #expect(Commands.AddCameraLayout(region(10, 2, .hidden)).apply(to: &edit))
        #expect(Commands.AddCameraLayout(region(3, 2, .sideBySide)).apply(to: &edit))
        #expect(edit.cameraLayouts.map(\.start) == [time(3), time(10)])
        let later = edit.cameraLayouts[1].id
        #expect(Commands.MoveRegion(id: later, start: time(1)).apply(to: &edit))
        #expect(edit.cameraLayouts.map(\.id).first == later)
    }

    @Test("Changing a region's layout is one edit, and changing it to what it is is none")
    func setLayout() {
        var edit = timeline([region(2, 3, .hidden)])
        let id = edit.cameraLayouts[0].id
        #expect(!Commands.SetCameraLayout(id: id, layout: .hidden).apply(to: &edit))
        #expect(Commands.SetCameraLayout(id: id, layout: .sideBySide).apply(to: &edit))
        #expect(edit.cameraLayouts[0].layout == .sideBySide)
        #expect(edit.webcam.isEnabled)
    }

    @Test("Delete, remove all, and a selection that points at one")
    func deleteAndSelect() {
        var edit = timeline([region(2, 3, .hidden), region(8, 3, .cameraOnly)])
        let first = edit.cameraLayouts[0].id
        #expect(Selection.cameraLayout(first).isValid(in: edit))
        #expect(Selection.cameraLayout(first).range(in: edit) == CMTimeRange(start: time(2), duration: time(3)))
        #expect(Selection.cameraLayout(first).regionID == first)
        #expect(edit.range(ofRegion: first) == CMTimeRange(start: time(2), duration: time(3)))
        #expect(Commands.DeleteRegion(id: first).apply(to: &edit))
        #expect(!Selection.cameraLayout(first).isValid(in: edit))
        #expect(Commands.RemoveCameraLayouts().apply(to: &edit))
        #expect(edit.cameraLayouts.isEmpty)
        #expect(!Commands.RemoveCameraLayouts().apply(to: &edit), "nothing left to remove is no edit")
    }

    @Test("Copied and pasted, through the pasteboard's bytes")
    func copyPaste() throws {
        var edit = timeline([region(2, 3, .sideBySide)])
        let original = edit.cameraLayouts[0]
        let copied = try #require(CopiedRegion(.cameraLayout(original.id), in: edit))
        let bytes = try #require(copied.encoded())
        let read = try #require(CopiedRegion.decoded(from: bytes))
        #expect(read == copied)
        #expect(read.title == "Camera Layout")

        let placed = try #require(read.placed(at: time(20), in: edit))
        #expect(Commands.InsertRegion(placed, name: "Paste Camera Layout").apply(to: &edit))
        #expect(edit.cameraLayouts.count == 2)
        let pasted = try #require(edit.cameraLayouts.last)
        #expect(pasted.id != original.id)
        #expect(pasted.layout == .sideBySide)
        #expect(pasted.start == time(20) && pasted.duration == time(3))
        #expect(placed.selection == .cameraLayout(pasted.id))
    }
}

/// The lane follows the footage exactly as the zoom lane does.
///
/// Each edit below is made to a timeline with a zoom and a camera layout in the same place;
/// afterwards they must still be in the same place. Measured against the zoom rather than
/// against numbers worked out here, because what is being promised is not a particular
/// arithmetic but *the same* arithmetic as every other lane.
@Suite("The camera lane follows the footage")
struct CameraLayoutFollowsFootageTests {
    private func paired(_ start: Double, _ duration: Double) -> Timeline {
        var edit = timeline([region(start, duration, .cameraOnly)])
        edit.zooms = [ZoomRegion(start: time(start), duration: time(duration))]
        return edit
    }

    private func expectTogether(_ edit: Timeline, _ comment: Comment,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(edit.cameraLayouts.count == edit.zooms.count, comment, sourceLocation: sourceLocation)
        for (camera, zoom) in zip(edit.cameraLayouts, edit.zooms) {
            #expect(camera.start == zoom.start && camera.duration == zoom.duration, comment,
                    sourceLocation: sourceLocation)
        }
    }

    @Test("Deleting footage before it pulls it back; over it, drops or trims it")
    func delete() {
        var before = paired(20, 5)
        #expect(ClipSequence.delete(&before, range: CMTimeRange(start: time(5), duration: time(4))))
        expectTogether(before, "a cut earlier in the video")
        #expect(before.cameraLayouts.first?.start == time(16))

        var over = paired(20, 5)
        ClipSequence.delete(&over, range: CMTimeRange(start: time(19), duration: time(8)))
        expectTogether(over, "a cut over the whole of it")

        var straddling = paired(20, 5)
        ClipSequence.delete(&straddling, range: CMTimeRange(start: time(22), duration: time(6)))
        expectTogether(straddling, "a cut over its end")
    }

    @Test("A speed change carries it along and stretches it")
    func speed() {
        var slowed = paired(12, 4)
        ClipSequence.setSpeed(&slowed, range: CMTimeRange(start: time(10), end: time(20)), speed: 0.5)
        expectTogether(slowed, "inside a slowed stretch")

        var after = paired(30, 4)
        ClipSequence.setSpeed(&after, range: CMTimeRange(start: time(10), end: time(20)), speed: 2)
        expectTogether(after, "after a sped-up stretch")
        #expect(after.cameraLayouts.first?.start == time(25))
    }

    @Test("Trimming the first clip's head moves it with the footage")
    func trim() throws {
        var edit = paired(20, 5)
        let clip = try #require(edit.clips.first)
        #expect(ClipSequence.trim(&edit, clipID: clip.id, head: time(4), tail: nil))
        expectTogether(edit, "a head trim")
    }

    @Test("Pasting footage before it pushes it along, and footage carries its own")
    func insert() throws {
        var edit = paired(20, 5)
        let lifted = try #require(CopiedFootage(CMTimeRange(start: time(18), duration: time(10)), in: edit))
        #expect(lifted.cameraLayouts.count == 1, "the layout inside the copied stretch comes with it")
        #expect(lifted.cameraLayouts.first?.start == time(2), "measured from the start of the copy")
        #expect(ClipSequence.insert(&edit, lifted.freshened(), at: time(5)))
        expectTogether(edit, "footage pasted earlier in the video")
        #expect(edit.cameraLayouts.count == 2)
        #expect(Set(edit.cameraLayouts.map(\.id)).count == 2, "the pasted one is a new region")
    }

    @Test("Footage copied through the pasteboard keeps its layouts; an older payload has none")
    func footagePayload() throws {
        let edit = paired(20, 5)
        let lifted = try #require(CopiedFootage(CMTimeRange(start: time(18), duration: time(10)), in: edit))
        let bytes = try #require(lifted.encoded())
        let read = try #require(CopiedFootage.decoded(from: bytes))
        #expect(read.cameraLayouts == lifted.cameraLayouts)
        #expect(read.carried == lifted.carried)

        // Written by a build that had no camera lane.
        var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "cameraLayouts")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(CopiedFootage.decoded(from: older)?.cameraLayouts == [])
    }

    @Test("An excerpt keeps the layout that was changing at its first frame")
    func excerpt() {
        let edit = timeline([region(2, 3, .cameraOnly), region(5, 3, .sideBySide)])
        let cut = edit.cut(to: CMTimeRange(start: time(5.1), duration: time(2)))
        // Within a hair: the excerpt's clock is the video's less 5.1 s, and that
        // subtraction is exact in `CMTime` and not in the seconds the lane is read in.
        func same(_ a: CameraLayoutState, _ b: CameraLayoutState) -> Bool {
            a.from == b.from && a.to == b.to && abs(a.progress - b.progress) < 1e-6
        }
        let first = cut.cameraLayout(at: .zero)
        #expect(!first.isSteady && first.from == .cameraOnly && first.to == .sideBySide,
                "frame 0 of the excerpt is frame 5.1 s of the video, part-way through the change")
        #expect(same(first, edit.cameraLayout(at: time(5.1))))
        #expect(same(cut.cameraLayout(at: time(1)), edit.cameraLayout(at: time(6.1))))
    }

    /// Not the camera's own, but found on the way: the shortcuts were left behind when a
    /// selection was cut out for export, so an excerpt drew every one at its time in the
    /// whole video.
    @Test("An excerpt moves the shortcuts onto its own clock")
    func excerptKeys() {
        var edit = Timeline(sourceDuration: time(60))
        edit.keyCues = [KeyCue(start: time(21), duration: time(1), modifiers: [.command], key: "K"),
                        KeyCue(start: time(50), duration: time(1), modifiers: [.command], key: "S")]
        let cut = edit.cut(to: CMTimeRange(start: time(20), duration: time(5)))
        #expect(cut.keyCues.count == 1, "the one outside the excerpt is not in it")
        #expect(cut.keyCues.first?.start == time(1))
        #expect(cut.keyCue(at: time(1.5))?.key == "K")
    }
}
