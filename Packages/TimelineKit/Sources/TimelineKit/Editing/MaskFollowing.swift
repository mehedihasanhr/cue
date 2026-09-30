import CoreGraphics
import CoreMedia
import Foundation

// MARK: - Where a mask is

public extension BlurRegion {
    /// Whether this mask moves with what it covers.
    var follows: Bool { path != nil }

    /// Where the mask is at a moment of the timeline, as a fraction of the recording.
    ///
    /// The one question the renderer, the canvas and the tests all ask, so a moving mask
    /// cannot be drawn in one place and outlined in another. A still mask is `rect` at
    /// every moment. A following one is `rect` moved by its path, and then kept inside the
    /// recording: a mask whose content slid off the edge stays at the edge, which still
    /// covers whatever part of it is left in the picture.
    func rect(at time: CMTime) -> CGRect {
        guard let path else { return rect }
        let offset = path.offset(at: (time - start).seconds)
        return Self.keptInside(rect.offsetBy(dx: offset.dx, dy: offset.dy))
    }

    /// The `rect` that shows the mask at `shown` at this moment — what moving or resizing
    /// a following mask on the picture stores.
    ///
    /// The whole path moves with it: the outline being dragged is the mask *now*, and the
    /// person dragging it means "a little to the left", not "here, and nowhere else". It is
    /// the same rule a still mask has, since a still mask is a path with no keys.
    func rect(showing shown: CGRect, at time: CMTime) -> CGRect {
        guard let path else { return shown }
        let offset = path.offset(at: (time - start).seconds)
        return shown.offsetBy(dx: -offset.dx, dy: -offset.dy)
    }

    // MARK: A window resized while it was recorded

    /// Where the mask covers the recording at a moment, as a fraction of the whole frame —
    /// the rectangle the renderer blurs, before it crops.
    ///
    /// # What a mask's `rect` is measured against
    ///
    /// A window resized after recording began is scaled by ScreenCaptureKit to fit its
    /// frame, so the window's content moves and shrinks inside the recording while the
    /// resize lasts and after it (see `PictureTrack`). A mask is meant to stay on what it
    /// was drawn over, so:
    ///
    /// - A **still** mask's `rect` is a fraction of the *picture* — the window's content as
    ///   it sat in the frame at that moment (`PictureTrack.pictureFraction`) — and is
    ///   carried through the picture's rescale here. For every recording whose picture
    ///   filled its frame, which is all but resized windows, the picture is the whole frame
    ///   and this is `rect` exactly as it always was.
    /// - A **following** mask's `rect` and path stay fractions of the whole frame: the path
    ///   was measured off the recording's own frames, so it already moves with the content
    ///   wherever a resize put it, and carrying it again would move it twice.
    ///
    /// Measured against the picture rather than against the picture at some chosen moment,
    /// so no edit — a trim of the mask's front, a split, a paste somewhere else — changes
    /// which content a mask is on.
    ///
    /// - Parameters:
    ///   - time: the moment on the timeline.
    ///   - seconds: the same moment in the recording, or `nil` over footage that is not
    ///     the recording (an imported clip), where the picture track means nothing.
    ///   - picture: where the picture sat; empty for every recording but a resized window.
    ///   - frame: the recording's size in the points `picture` is measured in.
    func recordingRect(at time: CMTime, source seconds: Double?, picture: PictureTrack, frame: CGSize) -> CGRect {
        let placed = rect(at: time)
        guard !follows, let seconds, !picture.isEmpty else { return placed }
        return PictureTrack.within(placed, of: picture.pictureFraction(at: seconds, in: frame))
    }

    /// The rectangle to hand `rect(showing:at:)` so the mask covers `covered` — a fraction
    /// of the whole frame, as the canvas measures it — at this moment. The inverse of
    /// `recordingRect(at:source:picture:frame:)`: a following mask is given it as it is, a
    /// still one has it turned into a fraction of the picture.
    func shownRect(covering covered: CGRect, source seconds: Double?, picture: PictureTrack, frame: CGSize) -> CGRect {
        guard !follows else { return covered }
        return Self.stillRect(covering: covered, source: seconds, picture: picture, frame: frame)
    }

    /// A new still mask's `rect`, for one drawn over `covered` — a fraction of the whole
    /// frame — at `seconds` into the recording.
    static func stillRect(covering covered: CGRect, source seconds: Double?, picture: PictureTrack,
                          frame: CGSize) -> CGRect {
        guard let seconds, !picture.isEmpty else { return covered }
        return PictureTrack.inside(covered, of: picture.pictureFraction(at: seconds, in: frame))
    }

    /// Shifted back into the unit square, keeping its size.
    private static func keptInside(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = min(max(rect.minX, 0), max(0, 1 - rect.width))
        rect.origin.y = min(max(rect.minY, 0), max(0, 1 - rect.height))
        return rect
    }

    /// Two masks where there was one, meeting at `time`, looking exactly as the one did.
    ///
    /// The first keeps the identity so a selection stays on something that is still there.
    /// Each half's path is re-timed to its own start, so the second half goes on following
    /// from where the first left off rather than starting the path again. `nil` when either
    /// half would be too short to take hold of.
    func split(at time: CMTime) -> (BlurRegion, BlurRegion)? {
        guard time - start >= Clip.minimumDuration, end - time >= Clip.minimumDuration else { return nil }
        var head = self
        head.duration = time - start
        head.path = path.map { MaskFollowing.clipped($0, to: head.duration.seconds) }
        var tail = placed(at: time, duration: end - time)
        tail.path = path.map {
            MaskFollowing.clipped(MaskFollowing.shifted($0, by: -(time - start).seconds), to: tail.duration.seconds)
        }
        return (head, tail)
    }
}

// MARK: - Keeping a path in step with edits

/// The rules that keep a followed path on its content when the timeline under it changes.
///
/// A path's times are relative to its region, so anything that moves a region whole — a
/// drag along the lane, a copy, a paste, a ripple that moves it later — needs nothing from
/// here. What does need this is an edit that changes *which footage* is under the region:
/// trimming its front edge, cutting footage out of its middle, changing the speed of part
/// of it. Each of those moves timeline moments about, and the path has to move with the
/// moments or it arrives early or late at what it covers.
public enum MaskFollowing {
    /// Masks after an edit, their paths re-timed to match.
    ///
    /// - Parameters:
    ///   - adjusted: the lane after the edit moved and resized its regions.
    ///   - before: the same lane before the edit, matched by id.
    ///   - breaks: moments, on the old clock, where the mapping has a corner. The path is
    ///     sampled there first, so a cut through the middle of a moving mask keeps the
    ///     position either side of the cut exactly rather than whatever keys survive.
    ///   - place: where a moment of the old timeline lands on the new one.
    ///
    /// A region whose start and length the edit did not touch is left alone. That matters
    /// for the edits that only change some regions — a rescale touches only those wholly
    /// inside its range — and it keeps an untouched lane's storage untouched.
    public static func retimed(_ adjusted: [BlurRegion], from before: [BlurRegion],
                               breaks: [CMTime] = [], place: (CMTime) -> CMTime) -> [BlurRegion] {
        guard adjusted.contains(where: { $0.path != nil }) else { return adjusted }
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return adjusted.map { region in
            guard let path = region.path, let was = old[region.id],
                  was.start != region.start || was.duration != region.duration else { return region }
            var region = region
            region.path = retimed(path, from: was.start, to: region.start, breaks: breaks, place: place)
            return region
        }
    }

    /// One path, re-timed. See `retimed(_:from:breaks:place:)`.
    ///
    /// Every key is kept, including those now past either end of the region: they still
    /// say where the content is at those moments, so dragging the region's edge back out
    /// after a trim finds the path still there rather than a mask holding still.
    static func retimed(_ path: MaskPath, from oldStart: CMTime, to newStart: CMTime,
                        breaks: [CMTime], place: (CMTime) -> CMTime) -> MaskPath {
        // The path's own shape at each corner of the mapping, as keys, so the corner is
        // kept wherever the keys happen to fall. Two keys a hair apart at each, because a
        // corner can tear the clock in two: footage pasted in at a moment sends the instant
        // before it one way and the instant after it the other, and the path has to hold
        // across the gap rather than stretch over it.
        var keys = path.keys
        let hair = 0.000_01
        for moment in breaks {
            let relative = (moment - oldStart).seconds
            guard let first = path.keys.first?.time, let last = path.keys.last?.time else { continue }
            for time in [relative - hair, relative] where time > first && time < last {
                keys.append(MaskPath.Key(time: time, offset: path.offset(at: time)))
            }
        }
        keys = MaskPath(keys: keys).keys

        func moved(_ relative: Double) -> Double {
            let absolute = oldStart + CMTime(seconds: relative, preferredTimescale: 600_000)
            return (place(absolute) - newStart).seconds
        }
        let mapped = keys.map { MaskPath.Key(time: moved($0.time), offset: $0.offset) }
        return MaskPath(keys: collapsed(mapped), losses: path.losses.map(moved))
    }

    /// Runs of keys that a cut put at one moment, down to the first and the last: the
    /// position before the cut and the position after it, which is a step.
    static func collapsed(_ keys: [MaskPath.Key]) -> [MaskPath.Key] {
        var result: [MaskPath.Key] = []
        for key in keys {
            if result.count >= 2, result[result.count - 1].time == key.time, result[result.count - 2].time == key.time {
                result[result.count - 1] = key
            } else {
                result.append(key)
            }
        }
        return result
    }

    /// The path moved earlier or later by `seconds`.
    static func shifted(_ path: MaskPath, by seconds: Double) -> MaskPath {
        MaskPath(keys: path.keys.map { MaskPath.Key(time: $0.time + seconds, offset: $0.offset) },
                 losses: path.losses.map { $0 + seconds })
    }

    /// Only the keys a region of `length` seconds can ask about, with the path's position
    /// at each end kept as a key so nothing it drew changes.
    static func clipped(_ path: MaskPath, to length: Double) -> MaskPath {
        guard let first = path.keys.first, let last = path.keys.last else { return path }
        guard first.time < 0 || last.time > length else {
            return MaskPath(keys: path.keys, losses: path.losses.filter { $0 >= 0 && $0 <= length })
        }
        var keys: [MaskPath.Key] = []
        if first.time < 0 { keys.append(MaskPath.Key(time: 0, offset: path.offset(at: 0))) }
        keys += path.keys.filter { $0.time >= 0 && $0.time <= length }
        if last.time > length { keys.append(MaskPath.Key(time: length, offset: path.offset(at: length))) }
        // A path clipped to a region that ends before its first key or starts after its
        // last still has one position to hold.
        if keys.isEmpty { keys = [MaskPath.Key(time: 0, offset: path.offset(at: 0))] }
        return MaskPath(keys: keys, losses: path.losses.filter { $0 >= 0 && $0 <= length })
    }
}

// MARK: - From what was followed to a path

public extension MaskPath {
    /// One moment of following: where the mask was, as an offset from where it began.
    struct Sample: Equatable, Sendable {
        /// Seconds from the start of the region.
        public var time: Double
        public var offset: CGVector

        public init(time: Double, offset: CGVector) {
            self.time = time
            self.offset = offset
        }
    }

    /// A path from one position per frame, smoothed and cut down to the keys that matter.
    ///
    /// Four steps, and the order is the point of them:
    ///
    /// 1. **A median of three**, on each axis. What a tracker gets wrong on screen content
    ///    is the odd frame a pixel or two out, and a median throws that frame away without
    ///    rounding off a real jump the way an average would: a mask that eases across a jump
    ///    uncovers what it was hiding for as long as it eases.
    /// 2. **Jumps kept as steps.** Where the content moved further in one frame than
    ///    `jump`, the path holds its old place up to the new frame and is at the new place
    ///    from it — two keys at one moment — so no frame in between ever shows the mask
    ///    halfway.
    /// 3. **A light average between jumps** — a quarter, a half, a quarter — which is
    ///    what takes the last pixel of wobble out of a steady move without reaching across
    ///    a jump, since it never sees one.
    /// 4. **Only the keys that matter**, between jumps: Ramer–Douglas–Peucker on the
    ///    position over time, keeping a key wherever leaving it out would move the mask by
    ///    more than `tolerance` at some frame. A steady scroll is two keys. What is left is
    ///    straight lines, which is also what removes the last of the jitter: nothing
    ///    smaller than `tolerance` survives as a wiggle.
    ///
    /// - Parameters:
    ///   - tolerance: how far the path may stray from a sample, per axis, as a fraction of
    ///     the recording. Half a pixel or so of the picture it was followed in.
    ///   - jump: a move in one frame at least this long, per axis, is a step.
    init(samples: [Sample], losses: [Double] = [], tolerance: CGVector, jump: CGVector) {
        let samples = samples.filter { $0.time.isFinite && $0.offset.dx.isFinite && $0.offset.dy.isFinite }
            .sorted { $0.time < $1.time }
        guard samples.count > 2 else {
            self.init(keys: samples.map { Key(time: $0.time, offset: $0.offset) }, losses: losses)
            return
        }
        let smoothed = Self.median3(samples)

        // Where the steps are: between sample i - 1 and sample i.
        var runs: [[Sample]] = [[smoothed[0]]]
        for index in 1..<smoothed.count {
            let a = smoothed[index - 1].offset, b = smoothed[index].offset
            if abs(b.dx - a.dx) >= jump.dx || abs(b.dy - a.dy) >= jump.dy {
                runs.append([])
            }
            runs[runs.count - 1].append(smoothed[index])
        }

        var keys: [Key] = []
        for (number, run) in runs.enumerated() {
            if number > 0, let held = keys.last, let first = run.first {
                // The old place, up to the moment of the new frame: the first half of the step.
                keys.append(Key(time: first.time, offset: held.offset))
            }
            keys += Self.simplified(Self.softened(run), tolerance: tolerance).map { Key(time: $0.time, offset: $0.offset) }
        }
        self.init(keys: keys, losses: losses)
    }

    private static func median3(_ samples: [Sample]) -> [Sample] {
        func median(_ a: Double, _ b: Double, _ c: Double) -> Double { max(min(a, b), min(max(a, b), c)) }
        var result = samples
        for index in 1..<(samples.count - 1) {
            let a = samples[index - 1].offset, b = samples[index].offset, c = samples[index + 1].offset
            result[index].offset = CGVector(dx: median(a.dx, b.dx, c.dx), dy: median(a.dy, b.dy, c.dy))
        }
        return result
    }

    /// Each sample a quarter of each neighbour and half itself; the two ends as they are,
    /// so a run still starts and stops exactly where it was followed to.
    private static func softened(_ run: [Sample]) -> [Sample] {
        guard run.count > 2 else { return run }
        var result = run
        for index in 1..<(run.count - 1) {
            let a = run[index - 1].offset, b = run[index].offset, c = run[index + 1].offset
            result[index].offset = CGVector(dx: (a.dx + 2 * b.dx + c.dx) / 4, dy: (a.dy + 2 * b.dy + c.dy) / 4)
        }
        return result
    }

    /// Ramer–Douglas–Peucker over time: the error of leaving a sample out is how far the
    /// straight line between its neighbours is from it *at its own moment*, which is the
    /// distance the mask would be off by on that frame.
    private static func simplified(_ run: [Sample], tolerance: CGVector) -> [Sample] {
        guard run.count > 2 else { return run }
        var keep = [Bool](repeating: false, count: run.count)
        keep[0] = true
        keep[run.count - 1] = true
        var stack = [(0, run.count - 1)]
        while let (from, to) = stack.popLast() {
            guard to > from + 1 else { continue }
            let a = run[from], b = run[to]
            let span = b.time - a.time
            var worst = 0.0
            var worstIndex = -1
            for index in (from + 1)..<to {
                let f = span > 0 ? (run[index].time - a.time) / span : 0
                let x = a.offset.dx + (b.offset.dx - a.offset.dx) * f
                let y = a.offset.dy + (b.offset.dy - a.offset.dy) * f
                let error = max(abs(run[index].offset.dx - x) / max(tolerance.dx, 1e-9),
                                abs(run[index].offset.dy - y) / max(tolerance.dy, 1e-9))
                if error > worst {
                    worst = error
                    worstIndex = index
                }
            }
            if worst > 1, worstIndex > 0 {
                keep[worstIndex] = true
                stack.append((from, worstIndex))
                stack.append((worstIndex, to))
            }
        }
        return run.indices.filter { keep[$0] }.map { run[$0] }
    }
}

// MARK: - Commands

public extension Commands {
    /// A mask told to follow what it covers.
    ///
    /// Carries the rectangle as well as the path, because following starts from where the
    /// mask is *at the playhead*, and on a mask that was already following that is not
    /// its stored `rect`. One command so the whole thing is one undo step.
    struct FollowContent: TimelineCommand {
        public let id: UUID
        public let rect: CGRect
        public let path: MaskPath
        public var name: String { "Follow Content" }

        public init(id: UUID, rect: CGRect, path: MaskPath) {
            self.id = id
            self.rect = rect
            self.path = path
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard !path.isEmpty, let index = timeline.blurs.firstIndex(where: { $0.id == id }) else { return false }
            guard timeline.blurs[index].rect != rect || timeline.blurs[index].path != path else { return false }
            timeline.blurs[index].rect = rect
            timeline.blurs[index].path = path
            return true
        }
    }

    /// A following mask made still again, where it is at `time` — so taking the path away
    /// does not make the mask jump somewhere else under the playhead.
    struct StopFollowing: TimelineCommand {
        public let id: UUID
        public let time: CMTime
        /// Where a resized window's picture sat, and the frame it is measured in: a still
        /// mask is a fraction of the picture, a following one of the whole frame, so the
        /// place the mask had stopped at is turned from one into the other. See
        /// `BlurRegion.recordingRect(at:source:picture:frame:)`.
        public let picture: PictureTrack
        public let frame: CGSize
        public var name: String { "Stop Following" }

        public init(id: UUID, at time: CMTime, picture: PictureTrack = PictureTrack(), frame: CGSize = .zero) {
            self.id = id
            self.time = time
            self.picture = picture
            self.frame = frame
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.blurs.firstIndex(where: { $0.id == id }),
                  timeline.blurs[index].path != nil else { return false }
            let clamped = min(max(time, timeline.blurs[index].start), timeline.blurs[index].end)
            let moment = timeline.mediaTime(at: clamped)
            let seconds = moment?.source == nil ? moment?.time.seconds : nil
            timeline.blurs[index].rect = BlurRegion.stillRect(covering: timeline.blurs[index].rect(at: clamped),
                                                             source: seconds, picture: picture, frame: frame)
            timeline.blurs[index].path = nil
            return true
        }
    }

    /// A mask moved or resized on the picture, by where it is shown at `time`.
    ///
    /// A still mask is exactly `SetRegionRect`: kept inside the recording. A following one
    /// stores the `rect` that shows it there, which moves the whole path by as much — and
    /// that `rect` may sit outside the recording, because it is only ever drawn moved by
    /// the path and kept inside (`BlurRegion.rect(at:)`). Clamping it as a still mask is
    /// clamped would stop a mask followed down the page from being dragged up at its end.
    struct PlaceMask: TimelineCommand {
        public let id: UUID
        public let shown: CGRect
        public let time: CMTime
        public var name: String { "Move" }

        public init(id: UUID, shown: CGRect, at time: CMTime) {
            self.id = id
            self.shown = shown
            self.time = time
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.blurs.firstIndex(where: { $0.id == id }) else { return false }
            let mask = timeline.blurs[index]
            guard mask.follows else { return SetRegionRect(id: id, rect: shown).apply(to: &timeline) }
            let placed = SetRegionRect.clamped(shown)
            let rect = mask.rect(showing: placed, at: time)
            guard rect != mask.rect else { return false }
            timeline.blurs[index].rect = rect
            return true
        }
    }

    /// One mask cut in two at a moment. See `BlurRegion.split(at:)`.
    struct SplitMask: TimelineCommand {
        public let id: UUID
        public let time: CMTime
        public var name: String { "Split Mask" }

        public init(id: UUID, at time: CMTime) {
            self.id = id
            self.time = time
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.blurs.firstIndex(where: { $0.id == id }),
                  let (head, tail) = timeline.blurs[index].split(at: time) else { return false }
            timeline.blurs[index] = head
            timeline.blurs.insert(tail, at: index + 1)
            return true
        }
    }
}
