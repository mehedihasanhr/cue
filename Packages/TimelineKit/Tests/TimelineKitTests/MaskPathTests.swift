import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// A mask that follows its content: how its path is stored, read back, drawn between keys,
/// built from what was followed, and kept on its content through copies, splits, trims and
/// cuts.
struct MaskPathTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private let rect = CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.1)

    /// Moves right by 0.1 of the picture a second for four seconds, then jumps down at 4 s.
    private var path: MaskPath {
        MaskPath(keys: [MaskPath.Key(time: 0, offset: .zero),
                        MaskPath.Key(time: 4, offset: CGVector(dx: 0.4, dy: 0)),
                        MaskPath.Key(time: 4, offset: CGVector(dx: 0.4, dy: 0.3)),
                        MaskPath.Key(time: 6, offset: CGVector(dx: 0.4, dy: 0.3))],
                 losses: [5.5])
    }

    private func mask(start: Double = 2, duration: Double = 6) -> BlurRegion {
        BlurRegion(start: time(start), duration: time(duration), rect: rect, style: .cover, path: path)
    }

    private func close(_ a: CGRect, _ b: CGRect, _ slack: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) < slack && abs(a.minY - b.minY) < slack
            && abs(a.width - b.width) < slack && abs(a.height - b.height) < slack
    }

    // MARK: - Where it is

    @Test func aStillMaskIsItsRectEverywhere() {
        let still = BlurRegion(start: time(2), duration: time(6), rect: rect)
        #expect(still.path == nil)
        #expect(!still.follows)
        for t in [0.0, 2, 5, 9] { #expect(still.rect(at: time(t)) == rect) }
    }

    @Test func aFollowingMaskMovesInStraightLinesBetweenKeys() {
        let mask = mask()
        #expect(close(mask.rect(at: time(2)), rect))
        #expect(close(mask.rect(at: time(3)), rect.offsetBy(dx: 0.1, dy: 0)))
        #expect(close(mask.rect(at: time(4)), rect.offsetBy(dx: 0.2, dy: 0)))
        // Before its start and after its end it holds.
        #expect(close(mask.rect(at: time(1)), rect))
        #expect(close(mask.rect(at: time(9)), rect.offsetBy(dx: 0.4, dy: 0.3)))
    }

    /// Two keys at one moment are a step: the old place right up to it, the new from it.
    @Test func twoKeysAtOneMomentAreAStepNotASlide() {
        let mask = mask()
        #expect(close(mask.rect(at: time(6) - CMTime(value: 1, timescale: 600)).offsetBy(dx: 0, dy: 0),
                      rect.offsetBy(dx: 0.4, dy: 0), 0.001))
        #expect(close(mask.rect(at: time(6)), rect.offsetBy(dx: 0.4, dy: 0.3)))
    }

    /// Moved off the picture by its path, it stays at the edge, the same size — which is
    /// where whatever is left of its content is.
    @Test func itStaysInsideThePictureAtTheEdge() {
        let wide = BlurRegion(start: .zero, duration: time(4), rect: CGRect(x: 0.7, y: 0.8, width: 0.2, height: 0.1),
                              path: MaskPath(keys: [MaskPath.Key(time: 0, offset: .zero),
                                                    MaskPath.Key(time: 2, offset: CGVector(dx: 0.5, dy: 0.5))]))
        let end = wide.rect(at: time(2))
        #expect(close(end, CGRect(x: 0.8, y: 0.9, width: 0.2, height: 0.1)))
    }

    /// Dragging the outline at the playhead moves the whole path by the same amount.
    @Test func movingItOnThePictureOffsetsTheWholePath() {
        var mask = mask()
        let now = time(4)
        let dragged = mask.rect(at: now).offsetBy(dx: -0.05, dy: 0.02)
        mask.rect = mask.rect(showing: dragged, at: now)
        #expect(close(mask.rect(at: now), dragged))
        #expect(close(mask.rect(at: time(2)), rect.offsetBy(dx: -0.05, dy: 0.02)))
        #expect(close(mask.rect(at: time(7)), rect.offsetBy(dx: 0.35, dy: 0.32)))
    }

    /// The command the canvas sends: a still mask is kept inside the picture as before; a
    /// following one moves its whole path, even where that puts its stored `rect` outside.
    @Test func placingAMaskOnThePictureMovesItsPath() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [mask(), BlurRegion(start: time(2), duration: time(6), rect: rect)]
        let following = timeline.blurs[0].id, still = timeline.blurs[1].id

        // At 7 s the following one is 0.3 lower than its rect; dragged to the top there, its
        // rect goes above the picture, and it is drawn at the top.
        let top = CGRect(x: 0.6, y: 0, width: 0.2, height: 0.1)
        #expect(Commands.PlaceMask(id: following, shown: top, at: time(7)).apply(to: &timeline))
        #expect(close(timeline.blurs[0].rect(at: time(7)), top))
        #expect(timeline.blurs[0].rect.minY < 0)
        #expect(close(timeline.blurs[0].rect(at: time(2)), CGRect(x: 0.2, y: 0, width: 0.2, height: 0.1)))

        #expect(Commands.PlaceMask(id: still, shown: CGRect(x: -0.1, y: 0.5, width: 0.2, height: 0.1),
                                   at: time(7)).apply(to: &timeline))
        #expect(timeline.blurs[1].rect == CGRect(x: 0, y: 0.5, width: 0.2, height: 0.1), "kept inside, as it always was")
    }

    /// Footage pasted into the middle of a following mask pushes the rest of its path on by
    /// as much, so it is still over the same footage after the gap.
    @Test func footagePastedIntoAMaskPushesItsPathOn() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [mask()]
        let before = timeline.blurs[0]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(20), duration: time(2)), in: timeline))
        #expect(ClipSequence.insert(&timeline, footage, at: time(4)))
        let after = try #require(timeline.blurs.first { $0.id == before.id })
        #expect(after.duration == time(8))
        #expect(close(after.rect(at: time(3.5)), before.rect(at: time(3.5))))
        #expect(close(after.rect(at: time(7)), before.rect(at: time(5))))
    }

    // MARK: - Stored

    @Test func aPathSurvivesARoundTrip() throws {
        let original = mask()
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(BlurRegion.self, from: data)
        #expect(back == original)
        #expect(back.path?.keys.count == 4)
        #expect(back.path?.losses == [5.5])
        // Short keys: a path of hundreds of these is part of the project file.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"t\":4"))
    }

    /// A mask written before following existed has no path, and draws where it was put.
    @Test func aMaskWithoutAPathDecodesStill() throws {
        let json = """
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
         "start":{"value":600,"timescale":600,"flags":1,"epoch":0},
         "duration":{"value":1200,"timescale":600,"flags":1,"epoch":0},
         "rect":[[0.2,0.3],[0.2,0.1]],"style":"cover","radius":18}
        """
        let blur = try JSONDecoder().decode(BlurRegion.self, from: Data(json.utf8))
        #expect(blur.path == nil)
        #expect(blur.rect(at: time(2)) == rect)
        // And one written without a path writes none.
        let written = String(decoding: try JSONEncoder().encode(blur), as: UTF8.self)
        #expect(!written.contains("path"))
    }

    /// One unreadable key costs that key, a path of nothing readable costs the path, and
    /// neither costs the mask.
    @Test func aDamagedPathIsReadLeniently() throws {
        func decode(_ path: String) throws -> BlurRegion {
            let json = """
            {"start":{"value":0,"timescale":600,"flags":1,"epoch":0},
             "duration":{"value":1200,"timescale":600,"flags":1,"epoch":0},
             "rect":[[0.2,0.3],[0.2,0.1]],"style":"cover","path":\(path)}
            """
            return try JSONDecoder().decode(BlurRegion.self, from: Data(json.utf8))
        }
        let skipped = try decode(#"{"keys":[{"t":0,"x":0,"y":0},{"x":"nope"},{"t":1,"x":0.1,"y":0}],"losses":["?",0.5]}"#)
        #expect(skipped.path?.keys.count == 2)
        #expect(skipped.path?.losses == [0.5])
        #expect(try decode(#"{"keys":[{"x":1}]}"#).path == nil)
        #expect(try decode(#""a path""#).path == nil)
        #expect(try decode(#"{}"#).path == nil)
        // Out of order on disk, in order once read.
        let shuffled = try decode(#"{"keys":[{"t":2,"x":0.2,"y":0},{"t":0,"x":0,"y":0}]}"#)
        #expect(shuffled.path?.keys.map(\.time) == [0, 2])
    }

    // MARK: - Built from what was followed

    @Test func aSteadyMoveIsTwoKeys() {
        let samples = (0...90).map { MaskPath.Sample(time: Double($0) / 30, offset: CGVector(dx: Double($0) * 0.002, dy: 0)) }
        let path = MaskPath(samples: samples, tolerance: CGVector(dx: 0.0005, dy: 0.0005),
                            jump: CGVector(dx: 0.05, dy: 0.05))
        #expect(path.keys.count == 2)
        #expect(abs(path.offset(at: 1.5).dx - 0.09) < 1e-9)
    }

    /// A tracker a pixel out on odd frames draws a mask that does not twitch: it only ever
    /// moves forwards, stays within the tolerance and the wobble of the true line, and is a
    /// few keys.
    @Test func jitterIsSmoothedAway() {
        let pixel = 1.0 / 1_280
        let samples = (0...120).map { index -> MaskPath.Sample in
            let wobble = [0.0, pixel, 0, -pixel, 0, 0, pixel][index % 7]
            return MaskPath.Sample(time: Double(index) / 60, offset: CGVector(dx: Double(index) * 3 * pixel + wobble, dy: 0))
        }
        let path = MaskPath(samples: samples, tolerance: CGVector(dx: 1.5 * pixel, dy: 1.5 * pixel),
                            jump: CGVector(dx: 0.1, dy: 0.1))
        #expect(path.keys.count <= 6)
        var last = -1.0
        for index in 0...120 {
            let truth = Double(index) * 3 * pixel
            let drawn = path.offset(at: Double(index) / 60).dx
            #expect(abs(drawn - truth) <= 2.5 * pixel)
            #expect(drawn > last, "never back the way it came, at frame \(index)")
            last = drawn
        }
    }

    @Test func aJumpIsKeptAsAStep() {
        let samples = (0..<60).map { index in
            MaskPath.Sample(time: Double(index) / 30, offset: index < 30 ? .zero : CGVector(dx: 0.3, dy: 0.2))
        }
        let path = MaskPath(samples: samples, tolerance: CGVector(dx: 0.0005, dy: 0.0005),
                            jump: CGVector(dx: 0.05, dy: 0.05))
        #expect(path.offset(at: 29.99 / 30) == .zero)
        #expect(path.offset(at: 1) == CGVector(dx: 0.3, dy: 0.2))
        // Two keys either side, and the pair that is the step.
        #expect(path.keys.count == 5)
    }

    // MARK: - Copies, splits and trims

    @Test func aCopyCarriesItsPath() throws {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [mask()]
        let copied = try #require(CopiedRegion(.blur(timeline.blurs[0].id), in: timeline))
        guard case .blur(let pasted) = try #require(copied.placed(at: time(10), in: timeline)) else {
            Issue.record("not a mask")
            return
        }
        #expect(pasted.id != timeline.blurs[0].id)
        #expect(pasted.path == path)
        // Relative to its own start, so it does at 10 s what the original did at 2 s.
        #expect(close(pasted.rect(at: time(13)), mask().rect(at: time(5))))

        // And through the pasteboard's encoding.
        let data = try JSONEncoder().encode(copied)
        #expect(CopiedRegion.decoded(from: data) == copied)
    }

    @Test func aSplitLooksExactlyLikeTheMaskItWas() throws {
        let whole = mask()
        let (head, tail) = try #require(whole.split(at: time(5)))
        #expect(head.id == whole.id)
        #expect(head.end == tail.start)
        for t in stride(from: 2.0, to: 8, by: 0.25) {
            let piece = t < 5 ? head : tail
            #expect(close(piece.rect(at: time(t)), whole.rect(at: time(t))), "at \(t) s")
        }
        #expect(tail.path?.losses == [2.5])
        #expect(head.path?.losses.isEmpty == true)
        #expect(whole.split(at: time(2.01)) == nil, "too short to take hold of")
    }

    @Test func splittingAMaskIsOneCommand() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [mask()]
        #expect(Commands.SplitMask(id: timeline.blurs[0].id, at: time(5)).apply(to: &timeline))
        #expect(timeline.blurs.count == 2)
        #expect(close(timeline.blurs[1].rect(at: time(7)), mask().rect(at: time(7))))
    }

    /// Trimming the front keeps the path on the moments it was followed at; moving the
    /// whole mask carries the path with it.
    @Test func aTrimKeepsThePathOnItsMomentsAndAMoveCarriesIt() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [mask()]
        let id = timeline.blurs[0].id

        var trimmed = timeline
        #expect(Commands.MoveRegion(id: id, start: time(3), duration: time(5)).apply(to: &trimmed))
        for t in stride(from: 3.0, to: 8, by: 0.5) {
            #expect(close(trimmed.blurs[0].rect(at: time(t)), mask().rect(at: time(t))), "at \(t) s")
        }
        #expect(trimmed.blurs[0].path?.losses == [4.5])
        // Dragged back out, the path is still there.
        #expect(Commands.MoveRegion(id: id, start: time(2), duration: time(6)).apply(to: &trimmed))
        for t in stride(from: 2.0, to: 8, by: 0.5) {
            #expect(close(trimmed.blurs[0].rect(at: time(t)), mask().rect(at: time(t))), "at \(t) s, restored")
        }

        var moved = timeline
        #expect(Commands.MoveRegion(id: id, start: time(10)).apply(to: &moved))
        #expect(close(moved.blurs[0].rect(at: time(11)), mask().rect(at: time(3))))
    }

    /// Footage cut out from under a following mask takes that part of the path with it:
    /// after the cut, the mask is where it was over the same footage before.
    @Test func cuttingFootageUnderAMaskKeepsItOnItsContent() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [mask()]
        let before = timeline.blurs[0]
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(3), duration: time(1))))
        let after = timeline.blurs[0]
        #expect(after.duration == time(5))
        #expect(close(after.rect(at: time(2.5)), before.rect(at: time(2.5))))
        // What was at 4.5 s is at 3.5 s now.
        #expect(close(after.rect(at: time(3.5)), before.rect(at: time(4.5))))
        #expect(close(after.rect(at: time(6.5)), before.rect(at: time(7.5))))

        // The front of it cut away: what is left starts where the cut is.
        var front = Timeline(sourceDuration: time(30))
        front.blurs = [mask()]
        #expect(ClipSequence.delete(&front, range: CMTimeRange(start: time(1), duration: time(2))))
        #expect(front.blurs[0].start == time(1))
        #expect(close(front.blurs[0].rect(at: time(2)), before.rect(at: time(4))))
    }

    @Test func slowingFootageUnderAMaskSlowsItsPath() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [mask()]
        let before = timeline.blurs[0]
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(2), duration: time(2)), speed: 0.5))
        let after = timeline.blurs[0]
        #expect(after.duration == time(8))
        // 3 s was one second into the slowed stretch; it is two seconds in now.
        #expect(close(after.rect(at: time(4)), before.rect(at: time(3))))
        #expect(close(after.rect(at: time(9)), before.rect(at: time(7))))
    }

    // MARK: - Following, and not

    @Test func followContentAndStopFollowingAreOneEditEach() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.blurs = [BlurRegion(start: time(2), duration: time(6), rect: rect)]
        let id = timeline.blurs[0].id
        let start = rect.offsetBy(dx: 0.1, dy: 0)
        #expect(Commands.FollowContent(id: id, rect: start, path: path).apply(to: &timeline))
        #expect(timeline.blurs[0].rect == start)
        #expect(timeline.blurs[0].path == path)
        #expect(!Commands.FollowContent(id: id, rect: start, path: MaskPath(keys: [])).apply(to: &timeline),
                "an empty path is not following")

        // Stopped at 4 s, it stays where it was at 4 s.
        let shown = timeline.blurs[0].rect(at: time(4))
        #expect(Commands.StopFollowing(id: id, at: time(4)).apply(to: &timeline))
        #expect(timeline.blurs[0].path == nil)
        #expect(close(timeline.blurs[0].rect, shown))
        #expect(!Commands.StopFollowing(id: id, at: time(4)).apply(to: &timeline), "nothing to stop")
    }
}
