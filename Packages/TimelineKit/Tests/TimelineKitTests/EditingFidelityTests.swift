import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// Every stored field of a value, by name, as text — which is enough to say whether two
/// of them differ and where.
private func fields(of value: Any) -> [String: String] {
    var found: [String: String] = [:]
    for child in Mirror(reflecting: value).children {
        guard let label = child.label else { continue }
        found[label] = String(describing: child.value)
    }
    return found
}

/// The fields two values disagree about, leaving out the ones that are meant to differ.
private func differences(_ original: Any, _ copy: Any, except: Set<String>) -> [String] {
    let before = fields(of: original)
    let after = fields(of: copy)
    return before.keys.sorted().filter { !except.contains($0) && before[$0] != after[$0] }
}

/// A copy is the thing it was copied from.
///
/// Copies are rebuilt field by field, because a region's identity is fixed when it is made
/// and a copy needs a new one. That is a list somebody has to keep, and it had fallen
/// behind twice: pasted footage lost every annotation's turn, opacity and entrance, and a
/// zoom that had been switched off came back on when it was duplicated.
///
/// These compare *every* stored field by reflection rather than the ones anybody thought
/// to list, so a field added to a region next year and forgotten in a copy fails here.
struct CopiesKeepEverythingTests {
    private var timeline: Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.zooms = [ZoomRegion(start: time(2), duration: time(4), scale: 2.6,
                                     center: CGPoint(x: 0.3, y: 0.7), easing: .linear,
                                     transition: time(0.9), followsCursor: false, source: .click,
                                     isEnabled: false, isEdited: true, isInstant: true)]
        timeline.blurs = [BlurRegion(start: time(3), duration: time(2),
                                     rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                                     style: .pixelate, radius: 31)]
        timeline.annotations = [AnnotationItem(start: time(4), duration: time(3), kind: .text("Here"),
                                               rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2),
                                               color: ColorValue(r: 0.1, g: 0.6, b: 0.9, a: 0.8),
                                               fontSize: 0.09, rotation: 25, opacity: 0.6,
                                               animation: AnnotationAnimation(entrance: .pop, exit: .slideLeft),
                                               isHidden: true)]
        timeline.captions = [CaptionCue(start: time(5), duration: time(2), text: "Said aloud",
                                        words: [.init(text: "Said", from: 0, to: 0.4),
                                                .init(text: "aloud", from: 0.5, to: 1)])]
        timeline.audio = [AudioRegion(start: time(6), duration: time(5), path: "Audio/song.m4a",
                                      gain: 0.4, sourceStart: time(12))]
        timeline.cursorRegions = [CursorRegion(start: time(7), duration: time(2), isHidden: true,
                                               smoothing: 0.4, isHeld: true, transition: time(0.4))]
        timeline.keyCues = [KeyCue(start: time(8), duration: time(1), modifiers: [.command, .shift],
                                   key: "K", count: 3, isHidden: true)]
        timeline.cameraLayouts = [CameraLayoutRegion(start: time(9), duration: time(3), layout: .sideBySide)]
        return timeline
    }

    /// What a copy is allowed to change: who it is, and where it was put.
    private let placement: Set<String> = ["id", "start", "duration"]

    @Test func aPastedZoomIsTheZoomThatWasCopied() throws {
        let original = timeline.zooms[0]
        guard case .zoom(let copy)? = CopiedRegion.zoom(original).placed(at: time(20), in: timeline) else {
            Issue.record("the zoom did not paste")
            return
        }
        // Left behind on purpose: a ramp for one end only means something beside the
        // region it was cut from, and a copy arrives unlocked.
        let dropped: Set<String> = ["transitionIn", "transitionOut", "isLocked"]
        #expect(differences(original, copy, except: placement.union(dropped)).isEmpty)
        #expect(!copy.isEnabled, "a zoom that was switched off stays off")
        #expect(copy.isEdited, "and one framed by hand stays framed by hand")
        #expect(copy.id != original.id)
    }

    @Test func aPastedAnnotationIsTheAnnotationThatWasCopied() throws {
        let original = timeline.annotations[0]
        guard case .annotation(let copy)? = CopiedRegion.annotation(original).placed(at: time(20), in: timeline) else {
            Issue.record("the annotation did not paste")
            return
        }
        #expect(differences(original, copy, except: placement.union(["isLocked"])).isEmpty)
    }

    @Test func everyOtherKindOfRegionPastesWhole() throws {
        let timeline = timeline
        let copies: [(Any, CopiedRegion)] = [
            (timeline.blurs[0], .blur(timeline.blurs[0])),
            (timeline.captions[0], .caption(timeline.captions[0])),
            (timeline.audio[0], .audio(timeline.audio[0])),
            (timeline.cursorRegions[0], .cursor(timeline.cursorRegions[0])),
            (timeline.keyCues[0], .key(timeline.keyCues[0])),
            (timeline.cameraLayouts[0], .cameraLayout(timeline.cameraLayouts[0])),
        ]
        for (original, copied) in copies {
            let placed = try #require(copied.placed(at: time(20), in: timeline))
            let copy: Any = switch placed {
            case .zoom(let r): r
            case .blur(let r): r
            case .annotation(let r): r
            case .caption(let r): r
            case .audio(let r): r
            case .cursor(let r): r
            case .key(let r): r
            case .cameraLayout(let r): r
            }
            #expect(differences(original, copy, except: placement).isEmpty,
                    "\(type(of: original)) lost \(differences(original, copy, except: placement))")
        }
    }

    /// The other way a copy is made: a stretch of footage, with everything over it.
    @Test func footageBringsItsRegionsWhole() throws {
        let timeline = timeline
        let footage = CopiedFootage(clips: timeline.clips,
                                    zooms: timeline.zooms, blurs: timeline.blurs,
                                    annotations: timeline.annotations, captions: timeline.captions,
                                    audio: timeline.audio, cursorRegions: timeline.cursorRegions,
                                    keyCues: timeline.keyCues,
                                    cameraLayouts: timeline.cameraLayouts,
                                    sourceDuration: time(60)).freshened()

        let identity: Set<String> = ["id"]
        #expect(differences(timeline.zooms[0], footage.zooms[0],
                            except: identity.union(["transitionIn", "transitionOut", "isLocked"])).isEmpty)
        #expect(differences(timeline.annotations[0], footage.annotations[0],
                            except: identity.union(["isLocked"])).isEmpty)
        #expect(differences(timeline.blurs[0], footage.blurs[0], except: identity).isEmpty)
        #expect(differences(timeline.captions[0], footage.captions[0], except: identity).isEmpty)
        #expect(differences(timeline.audio[0], footage.audio[0], except: identity).isEmpty)
        #expect(differences(timeline.cursorRegions[0], footage.cursorRegions[0], except: identity).isEmpty)
        #expect(differences(timeline.keyCues[0], footage.keyCues[0], except: identity).isEmpty)
        #expect(differences(timeline.cameraLayouts[0], footage.cameraLayouts[0], except: identity).isEmpty)
        #expect(footage.cameraLayouts[0].id != timeline.cameraLayouts[0].id)
        #expect(differences(timeline.clips[0], footage.clips[0], except: identity).isEmpty)
        #expect(footage.zooms[0].id != timeline.zooms[0].id)
    }
}

/// Trimming the front of a sound.
///
/// Shortening a song from its start means it begins later *in the song*, and what is heard
/// afterwards stays exactly where it was. A sound that was brought in used to slide instead:
/// the edge moved, the song still began at its first bar, and everything in it arrived late
/// by as much as had been trimmed.
struct SoundHeadTrimTests {
    private var timeline: Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.audio = [AudioRegion(start: time(10), duration: time(20), path: "Audio/song.m4a",
                                      sourceStart: time(5))]
        return timeline
    }

    /// What is heard at a moment on the timeline: which second of the file.
    private func heard(at moment: Double, in region: AudioRegion) -> Double {
        region.sourceStart.seconds + (moment - region.start.seconds)
    }

    @Test func trimmingTheFrontLeavesTheRestWhereItWas() {
        var timeline = timeline
        let before = timeline.audio[0]
        #expect(Commands.MoveRegion(id: before.id, start: time(13), duration: time(17), trimsHead: true)
            .apply(to: &timeline))
        let after = timeline.audio[0]
        #expect(after.start == time(13))
        #expect(after.end == before.end, "the far edge has not moved")
        #expect(after.sourceStart == time(8), "three seconds further into the song")
        #expect(abs(heard(at: 20, in: after) - heard(at: 20, in: before)) < 0.0001,
                "the same second of the song is heard at the same moment")
    }

    @Test func pullingTheFrontBackOutRevealsWhatWasTrimmed() {
        var timeline = timeline
        let before = timeline.audio[0]
        Commands.MoveRegion(id: before.id, start: time(7), duration: time(23), trimsHead: true)
            .apply(to: &timeline)
        let after = timeline.audio[0]
        #expect(after.start == time(7))
        #expect(after.sourceStart == time(2))
        #expect(after.end == before.end)
    }

    /// There is nothing before a file's first sample. The edge stops where the song starts,
    /// rather than going on and dragging the song with it.
    @Test func theFrontCannotGoPastTheStartOfTheFile() {
        var timeline = timeline
        let before = timeline.audio[0]
        Commands.MoveRegion(id: before.id, start: time(1), duration: time(29), trimsHead: true)
            .apply(to: &timeline)
        let after = timeline.audio[0]
        #expect(after.sourceStart == .zero)
        #expect(after.start == time(5), "five seconds of song were hidden, so five seconds is all there is")
        #expect(after.end == before.end)
        #expect(abs(heard(at: 20, in: after) - heard(at: 20, in: before)) < 0.0001)
    }

    /// Dragging the whole thing is a move, and a move does not re-cut it.
    @Test func draggingTheWholeSoundSlidesIt() {
        var timeline = timeline
        let before = timeline.audio[0]
        Commands.MoveRegion(id: before.id, start: time(15)).apply(to: &timeline)
        #expect(timeline.audio[0].sourceStart == before.sourceStart)
        #expect(timeline.audio[0].duration == before.duration)
    }

    @Test func aGroupDragTrimsASoundTheSameWay() {
        var timeline = timeline
        let before = timeline.audio[0]
        Commands.MoveMany([.init(id: before.id, start: time(13), duration: time(17), trimsHead: true)],
                          name: "Trim").apply(to: &timeline)
        #expect(timeline.audio[0].sourceStart == time(8))
    }

    /// The same rule for a run of the recording's own sound, which already trimmed but
    /// could be dragged past the start of the recording.
    @Test func aRunOfTheRecordingStopsAtTheStartOfTheRecording() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.detachedSound = [SoundRun(start: time(10), duration: time(20), sourceStart: time(4))]
        let before = timeline.detachedSound![0]
        Commands.MoveSoundRun(id: before.id, start: time(2), duration: time(28), trimsHead: true)
            .apply(to: &timeline)
        let after = timeline.detachedSound![0]
        #expect(after.sourceStart == .zero)
        #expect(after.start == time(6))
        #expect(after.end == before.end)
    }

    /// A zoom has nothing underneath it to keep still, so the flag changes nothing there.
    @Test func otherRegionsAreNotAffected() {
        var plain = Timeline(sourceDuration: time(60))
        plain.zooms = [ZoomRegion(start: time(10), duration: time(10))]
        var flagged = plain
        Commands.MoveRegion(id: plain.zooms[0].id, start: time(12), duration: time(8)).apply(to: &plain)
        Commands.MoveRegion(id: flagged.zooms[0].id, start: time(12), duration: time(8), trimsHead: true)
            .apply(to: &flagged)
        #expect(plain.zooms == flagged.zooms)
    }
}

/// Lanes that are read in time order stay in it.
///
/// "The next zoom" is asked of the lane by position. A zoom dragged past its neighbour
/// used to keep its old place in the list, so the next one was the wrong one.
struct LaneOrderTests {
    @Test func aZoomDraggedPastItsNeighbourChangesPlacesWithIt() {
        var timeline = Timeline(sourceDuration: time(60))
        let first = ZoomRegion(start: time(5), duration: time(3))
        let second = ZoomRegion(start: time(12), duration: time(3))
        timeline.zooms = [first, second]

        #expect(Commands.MoveRegion(id: first.id, start: time(20)).apply(to: &timeline))
        #expect(timeline.zooms.map(\.id) == [second.id, first.id])
        #expect(timeline.zooms.map(\.start) == [time(12), time(20)])
    }

    @Test func pointerStretchesAndCaptionsAreKeptInOrderToo() {
        var timeline = Timeline(sourceDuration: time(60))
        let early = CursorRegion(start: time(5), duration: time(2))
        let late = CursorRegion(start: time(12), duration: time(2))
        timeline.cursorRegions = [early, late]
        let said = CaptionCue(start: time(3), duration: time(2), text: "one")
        let next = CaptionCue(start: time(8), duration: time(2), text: "two")
        timeline.captions = [said, next]

        Commands.MoveRegion(id: early.id, start: time(30)).apply(to: &timeline)
        Commands.MoveRegion(id: said.id, start: time(40)).apply(to: &timeline)
        #expect(timeline.cursorRegions.map(\.id) == [late.id, early.id])
        #expect(timeline.captions.map(\.id) == [next.id, said.id])
    }

    /// An annotation's place in the list is how far up the stack it is. Moving a label
    /// along the timeline must not send it behind another.
    @Test func annotationsKeepTheirStackingOrder() {
        var timeline = Timeline(sourceDuration: time(60))
        let under = AnnotationItem(start: time(5), duration: time(3), kind: .rectangle,
                                   rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let over = AnnotationItem(start: time(12), duration: time(3), kind: .rectangle,
                                  rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        timeline.annotations = [under, over]

        Commands.MoveRegion(id: under.id, start: time(30)).apply(to: &timeline)
        #expect(timeline.annotations.map(\.id) == [under.id, over.id])
    }

    @Test func aGroupDragLeavesTheLaneInOrder() {
        var timeline = Timeline(sourceDuration: time(60))
        let zooms = [5.0, 12, 20].map { ZoomRegion(start: time($0), duration: time(3)) }
        timeline.zooms = zooms
        Commands.MoveMany([.init(id: zooms[0].id, start: time(40)),
                           .init(id: zooms[1].id, start: time(30))], name: "Move").apply(to: &timeline)
        #expect(timeline.zooms.map(\.start) == [time(20), time(30), time(40)])
    }

    /// Two that start together stay the way round they were.
    @Test func zoomsThatStartTogetherKeepTheirOrder() {
        let a = ZoomRegion(start: time(5), duration: time(3))
        let b = ZoomRegion(start: time(5), duration: time(4))
        let c = ZoomRegion(start: time(2), duration: time(1))
        #expect(Commands.MoveRegion.inTimeOrder([a, b, c]).map(\.id) == [c.id, a.id, b.id])
    }
}
