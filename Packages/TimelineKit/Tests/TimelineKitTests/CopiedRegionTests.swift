import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Copying a region, and the three ways it can go wrong.
///
/// A paste is one of the few edits whose input comes from outside the app — a build that
/// may be newer, or bytes that may be nothing at all — so the encoding and the clamping
/// are worth pinning down here, where they can be tested without a window.
struct CopiedRegionTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline(seconds: Double = 60) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    private let rect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3)

    // MARK: - Reading the selection

    @Test func aSelectedZoomIsWhatGetsCopied() {
        var timeline = timeline()
        let zoom = ZoomRegion(start: time(4), duration: time(3), scale: 3.5)
        timeline.zooms = [zoom]
        let copied = CopiedRegion(.zoom(zoom.id), in: timeline)
        #expect(copied == .zoom(zoom))
    }

    @Test func aSelectionPointingAtNothingCopiesNothing() {
        let timeline = timeline()
        #expect(CopiedRegion(.zoom(UUID()), in: timeline) == nil)
        #expect(CopiedRegion(.none, in: timeline) == nil)
    }

    /// Footage is out of scope on purpose: pasting it would have to insert time and ripple
    /// everything after the playhead along, which a region paste does not do.
    @Test func footageIsNotCopyable() {
        let timeline = timeline()
        let clip = timeline.clips[0]
        #expect(CopiedRegion(.clip(clip.id), in: timeline) == nil)
        #expect(CopiedRegion(.range(CMTimeRange(start: .zero, duration: time(10))), in: timeline) == nil)
        #expect(CopiedRegion(.headTrim, in: timeline) == nil)
        #expect(CopiedRegion(.sound, in: timeline) == nil)
    }

    // MARK: - A pasted region is a different region

    @Test func aPastedRegionGetsANewIdentity() {
        let timeline = timeline()
        let zoom = ZoomRegion(start: time(4), duration: time(3))
        let placed = CopiedRegion.zoom(zoom).placed(at: time(20), in: timeline)
        #expect(placed?.id != zoom.id)
    }

    @Test func aPastedRegionKeepsEverythingButItsIdentityAndItsPlace() throws {
        let timeline = timeline()
        let zoom = ZoomRegion(start: time(4), duration: time(3), scale: 4.25,
                              center: CGPoint(x: 0.3, y: 0.7), easing: .easeInOut,
                              transition: time(0.75), followsCursor: false, source: .click)
        let placed = try #require(CopiedRegion.zoom(zoom).placed(at: time(20), in: timeline))
        guard case .zoom(let copy) = placed else { Issue.record("kind changed"); return }
        #expect(copy.scale == zoom.scale)
        #expect(copy.center == zoom.center)
        #expect(copy.easing == zoom.easing)
        #expect(copy.transition == zoom.transition)
        #expect(copy.followsCursor == zoom.followsCursor)
        #expect(copy.source == zoom.source)
        #expect(copy.duration == zoom.duration)
        #expect(copy.start == time(20))
    }

    @Test func pastingTwiceGivesTwoDistinctRegions() throws {
        var timeline = timeline()
        let zoom = ZoomRegion(start: time(4), duration: time(3))
        let copied = CopiedRegion.zoom(zoom)
        let first = try #require(copied.placed(at: time(20), in: timeline))
        #expect(Commands.InsertRegion(first, name: "Paste Zoom").apply(to: &timeline))
        let second = try #require(copied.placed(at: time(30), in: timeline))
        #expect(Commands.InsertRegion(second, name: "Paste Zoom").apply(to: &timeline))
        #expect(timeline.zooms.count == 2)
        #expect(timeline.zooms[0].id != timeline.zooms[1].id)
    }

    // MARK: - Clamping

    @Test func aPasteAtTheEndOfTheEditStaysInsideIt() throws {
        let timeline = timeline(seconds: 10)
        let zoom = ZoomRegion(start: .zero, duration: time(6))
        let placed = try #require(CopiedRegion.zoom(zoom).placed(at: time(8), in: timeline))
        #expect(placed.start == time(8))
        // The position is what was asked for, so the length is what gives way.
        #expect(placed.duration == time(2))
        #expect(placed.end <= timeline.duration)
    }

    @Test func aPasteBeyondTheEndOfTheEditIsPulledBackInside() throws {
        let timeline = timeline(seconds: 10)
        let zoom = ZoomRegion(start: .zero, duration: time(3))
        let placed = try #require(CopiedRegion.zoom(zoom).placed(at: time(90), in: timeline))
        #expect(placed.start == timeline.duration - Clip.minimumDuration)
        #expect(placed.end <= timeline.duration)
        #expect(placed.duration >= Clip.minimumDuration)
    }

    @Test func aPasteKeepsItsLengthWhenThereIsRoomForIt() throws {
        let timeline = timeline(seconds: 60)
        let zoom = ZoomRegion(start: time(4), duration: time(3))
        let placed = try #require(CopiedRegion.zoom(zoom).placed(at: time(20), in: timeline))
        #expect(placed.duration == time(3))
    }

    @Test func anEditWithNoRoomInItRefusesThePaste() {
        let timeline = Timeline(sourceDuration: .zero)
        let zoom = ZoomRegion(start: .zero, duration: time(3))
        #expect(CopiedRegion.zoom(zoom).placed(at: .zero, in: timeline) == nil)
    }

    // MARK: - Inserting

    @Test func insertingPutsEachKindInItsOwnLane() throws {
        var timeline = timeline()
        let inserts: [CopiedRegion] = [
            .zoom(ZoomRegion(start: time(1), duration: time(2))),
            .blur(BlurRegion(start: time(1), duration: time(2), rect: rect)),
            .annotation(AnnotationItem(start: time(1), duration: time(2), kind: .rectangle, rect: rect)),
            .caption(CaptionCue(start: time(1), duration: time(2), text: "hello")),
            .audio(AudioRegion(start: time(1), duration: time(2), path: "audio/music.m4a")),
        ]
        for insert in inserts {
            #expect(Commands.InsertRegion(insert, name: "Paste \(insert.title)").apply(to: &timeline))
        }
        #expect(timeline.zooms.count == 1)
        #expect(timeline.blurs.count == 1)
        #expect(timeline.annotations.count == 1)
        #expect(timeline.captions.count == 1)
        #expect(timeline.audio.count == 1)
    }

    @Test func insertedZoomsAndCaptionsStaySortedByTime() throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(30), duration: time(2))]
        timeline.captions = [CaptionCue(start: time(30), duration: time(2), text: "later")]
        #expect(Commands.InsertRegion(.zoom(ZoomRegion(start: time(5), duration: time(2))),
                                      name: "Paste Zoom").apply(to: &timeline))
        #expect(Commands.InsertRegion(.caption(CaptionCue(start: time(5), duration: time(2), text: "earlier")),
                                      name: "Paste Caption").apply(to: &timeline))
        #expect(timeline.zooms.map(\.start) == [time(5), time(30)])
        #expect(timeline.captions.map(\.text) == ["earlier", "later"])
    }

    @Test func aRegionPastTheEndOfTheEditIsRefusedRatherThanStored() {
        var timeline = timeline(seconds: 10)
        let beyond = CopiedRegion.zoom(ZoomRegion(start: time(40), duration: time(2)))
        #expect(!Commands.InsertRegion(beyond, name: "Paste Zoom").apply(to: &timeline))
        #expect(timeline.zooms.isEmpty)
    }

    @Test func aRegionTooShortToGrabIsRefused() {
        var timeline = timeline()
        let sliver = CopiedRegion.zoom(ZoomRegion(start: .zero, duration: CMTime(value: 1, timescale: 600)))
        #expect(!Commands.InsertRegion(sliver, name: "Paste Zoom").apply(to: &timeline))
        #expect(timeline.zooms.isEmpty)
    }

    // MARK: - The round trip

    @Test(arguments: CopiedRegionTests.everyKind)
    func aRoundTripThroughTheClipboardChangesNothing(region: CopiedRegion) throws {
        let data = try #require(region.encoded())
        #expect(CopiedRegion.decoded(from: data) == region)
    }

    static let everyKind: [CopiedRegion] = {
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3)
        return [
            .zoom(ZoomRegion(start: time(4), duration: time(3), scale: 3.25,
                             center: CGPoint(x: 0.4, y: 0.6), easing: .linear,
                             transition: time(0.4), followsCursor: false, source: .typing)),
            .blur(BlurRegion(start: time(1), duration: time(2), rect: rect, style: .pixelate, radius: 31)),
            .annotation(AnnotationItem(start: time(2), duration: time(5), kind: .text("Look here"),
                                       rect: rect, color: ColorValue(r: 0.1, g: 0.2, b: 0.3, a: 0.8),
                                       fontSize: 0.09)),
            .caption(CaptionCue(start: time(0), duration: time(1.5), text: "and then this happens")),
            .audio(AudioRegion(start: time(7), duration: time(20), path: "audio/music.m4a",
                               gain: 0.42, sourceStart: time(3))),
        ]
    }()

    // MARK: - Rubbish on the pasteboard

    /// Anything at all can be sitting under our type. None of it may crash the paste.
    @Test(arguments: [
        Data(),
        Data("not json at all".utf8),
        Data("{}".utf8),
        Data(#"{"formatVersion":1}"#.utf8),
        // A kind from a build that has one this one does not.
        Data(#"{"formatVersion":2,"kind":"transition","region":{"start":0,"duration":1}}"#.utf8),
        // The right kind, with the region missing.
        Data(#"{"formatVersion":1,"kind":"zoom"}"#.utf8),
        // The right kind, with a region that is not one.
        Data(#"{"formatVersion":1,"kind":"zoom","region":"a zoom, honestly"}"#.utf8),
        // Truncated halfway through a write.
        Data(#"{"formatVersion":1,"kind":"zoom","region":{"id":"#.utf8),
    ])
    func rubbishOnTheClipboardIsIgnoredRatherThanFatal(data: Data) {
        #expect(CopiedRegion.decoded(from: data) == nil)
    }

    /// The newer-build case that *is* readable: a region carrying a field this build has
    /// never heard of still decodes, because every region's decoder ignores what it does
    /// not know. Refusing it would make a copy made after an update unpastable before one.
    @Test func aRegionWithAFieldFromTheFutureStillPastes() throws {
        let zoom = ZoomRegion(start: time(4), duration: time(3), scale: 2.5)
        let data = try #require(CopiedRegion.zoom(zoom).encoded())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var region = try #require(object["region"] as? [String: Any])
        region["parallax"] = 0.5
        object["region"] = region
        object["formatVersion"] = 99
        let forward = try JSONSerialization.data(withJSONObject: object)
        #expect(CopiedRegion.decoded(from: forward) == .zoom(zoom))
    }

    // MARK: - Words for other apps

    @Test func everyKindDescribesItselfInOneLine() {
        for region in Self.everyKind {
            #expect(!region.summary.isEmpty)
            #expect(!region.summary.contains("\n"))
        }
    }
}
