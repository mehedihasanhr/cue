import CoreGraphics
import CoreMedia
import Foundation
import RecordKit

/// The recorded pointer, ready to be drawn.
///
/// Sampled positions are jittery — a hand on a trackpad is not a smooth curve, and at
/// 120 Hz every tremor is in the file. Smoothing them is what makes a recording look
/// deliberate, and it can only be done here, after the fact, because the recorder was
/// careful not to burn the pointer into the picture.
public struct CursorTrack: Sendable {
    /// A button going down: when, and where.
    ///
    /// The position was always on disk and was always thrown away here, because the only
    /// thing drawn for a click was a swell of the pointer, which happens wherever the
    /// pointer already is. Anything that marks the *place* a click happened needs the
    /// place — and it has to be the recorded one rather than the drawn one, because
    /// smoothing moves the pointer a little and a ring drawn around the smoothed position
    /// would sit slightly off the thing that was actually clicked.
    public struct Click: Equatable, Sendable {
        public let t: Double
        public let point: CGPoint
        /// A right-click, or a two-finger tap. Drawn differently, because the two mean
        /// different things to someone following along.
        public let isSecondary: Bool

        public init(t: Double, point: CGPoint, isSecondary: Bool) {
            self.t = t
            self.point = point
            self.isSecondary = isSecondary
        }
    }

    public let samples: [CursorSample]
    public let clicks: [Click]
    /// The stretches in which the pointer was doing something — moving, or pressing a
    /// button — oldest first, none touching. Everything between them is the pointer at
    /// rest.
    ///
    /// Worked out from the recorded path and kept through smoothing: a filter spreads a
    /// movement out in time, so a smoothed pointer looks as if it set off earlier and
    /// arrived later than the hand did.
    public let activity: [ClosedRange<Double>]
    /// When the pointer's shape changed, and to what, with shapes held for only an instant
    /// left out. See `steadyShape(at:)`.
    private let steadyShapes: [(t: Double, shape: CursorShape)]

    public init(samples: [CursorSample], input: [InputSample] = []) {
        let sorted = samples.sorted { $0.t < $1.t }
        self.samples = Self.pinned(sorted, to: input)
        clicks = input.compactMap { sample in
            guard case .mouseDown(let t, let button, let x, let y) = sample else { return nil }
            return Click(t: t, point: CGPoint(x: x, y: y), isSecondary: button == 1)
        }.sorted { $0.t < $1.t }
        activity = Self.activity(in: self.samples, input: input)
        steadyShapes = Self.steadyShapes(in: sorted)
    }

    /// The sampled path with every press and release added to it as a sample of its own.
    ///
    /// The path is read on a timer and a click is an event, so the two are two accounts of
    /// where the pointer was — and at the one moment a viewer is looking hardest, they
    /// differ: the timer's reading is as stale as the last time the pointer reported in,
    /// which for a hand still moving as it clicks is a few points. A click says exactly
    /// where the pointer was and exactly when. Putting that in the path makes the pointer
    /// pass through the place it clicked, at the moment it clicked, by construction rather
    /// than by the two happening to agree.
    private static func pinned(_ samples: [CursorSample], to input: [InputSample]) -> [CursorSample] {
        guard !samples.isEmpty else { return samples }
        var pins: [(t: Double, point: CGPoint)] = []
        for sample in input {
            switch sample {
            case .mouseDown(let t, _, let x, let y), .mouseUp(let t, _, let x, let y):
                pins.append((t, CGPoint(x: x, y: y)))
            case .scroll, .key:
                continue
            case .shortcut:
                continue
            }
        }
        guard !pins.isEmpty else { return samples }

        var merged = samples
        merged.reserveCapacity(samples.count + pins.count)
        for pin in pins.sorted(by: { $0.t < $1.t }) {
            // Where it goes: after every sample at or before its time.
            var low = 0
            var high = merged.count
            while low < high {
                let middle = (low + high) / 2
                if merged[middle].t <= pin.t { low = middle + 1 } else { high = middle }
            }
            // The shape is whatever the pointer looked like just then, which a click does
            // not say and the sample before it does.
            let shape = merged[max(0, low - 1)].shape
            if low > 0, merged[low - 1].t == pin.t {
                merged[low - 1].x = pin.point.x
                merged[low - 1].y = pin.point.y
            } else {
                merged.insert(CursorSample(t: pin.t, x: pin.point.x, y: pin.point.y, shape: shape), at: low)
            }
        }
        return merged
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Where the pointer was at a moment in the recording, interpolated between samples.
    ///
    /// Interpolated rather than nearest-neighbour because the renderer asks at the frame
    /// rate and the samples are on their own clock; snapping to the nearest sample makes
    /// the pointer stutter at exactly the rate the two disagree.
    public func position(at time: Double) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        if time <= samples[0].t { return samples[0].point }
        if time >= samples[samples.count - 1].t { return samples[samples.count - 1].point }

        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if samples[middle].t <= time { low = middle } else { high = middle }
        }
        let a = samples[low]
        let b = samples[high]
        let span = b.t - a.t
        guard span > 0 else { return a.point }
        let progress = (time - a.t) / span
        return CGPoint(x: a.x + (b.x - a.x) * progress,
                       y: a.y + (b.y - a.y) * progress)
    }

    public func shape(at time: Double) -> CursorShape {
        guard !samples.isEmpty else { return .arrow }
        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if samples[middle].t <= time { low = middle } else { high = middle }
        }
        return samples[low].shape
    }

    /// The track as a style asks for it: shakes taken out if it says so, then smoothed.
    ///
    /// The one place the renderer's pointer is prepared, so the preview, a still and an
    /// export cannot disagree about which readings were dropped.
    public func prepared(for style: CursorStyle) -> CursorTrack {
        (style.removesShakes ? withoutShakes(threshold: style.shakeThreshold) : self).smoothed(style.smoothing)
    }

    /// The track with its shakes taken out, the reference's way: a reading further than
    /// `threshold` — across plus down — from *both* of the next two readings is a jump
    /// there and back, not a movement, and is dropped. A click is never dropped: it is
    /// where somebody pressed, whatever the readings around it say.
    public func withoutShakes(threshold: Double) -> CursorTrack {
        guard samples.count > 3 else { return self }
        let pressed = Set(clicks.map(\.t))
        func far(_ a: CursorSample, _ b: CursorSample) -> Bool {
            abs(a.x - b.x) + abs(a.y - b.y) > threshold
        }
        var kept: [CursorSample] = []
        kept.reserveCapacity(samples.count)
        for index in samples.indices {
            let sample = samples[index]
            if index + 2 < samples.count, !pressed.contains(sample.t),
               far(sample, samples[index + 1]), far(sample, samples[index + 2]) {
                continue
            }
            kept.append(sample)
        }
        guard kept.count != samples.count else { return self }
        return CursorTrack(samples: kept, clicks: clicks, activity: activity, steadyShapes: steadyShapes)
    }

    /// A smoothed copy of the track: the drawn pointer is a weight on a spring that chases
    /// the recorded one.
    ///
    /// The reference's model (docs/studio/10-motion-reference.md): a clamped spring stepped
    /// every millisecond, so the pointer eases into a stop without overshooting it. Within
    /// half a second of a click it chases the click instead of the hand, so it arrives where
    /// the click lands rather than wherever the hand wobbled on the way; in the last 175 ms
    /// it switches to the stiff Rapid spring, so it is there on time. `amount` picks the
    /// spring: 0 is the raw pointer, the middle is Medium, 1 is Smooth.
    public func smoothed(_ amount: Double) -> CursorTrack {
        let amount = min(1, max(0, amount))
        guard amount > 0, samples.count > 2 else { return self }

        var result = samples
        var spring = PointerSpring(chosen: .blended(amount), start: samples[0].point)
        var nextClick = 0
        var t = samples[0].t
        for index in 1..<samples.count {
            let a = samples[index - 1]
            let b = samples[index]
            let span = b.t - a.t
            while t < b.t {
                let step = min(PointerSpring.step, b.t - t)
                t += step
                while nextClick < clicks.count, clicks[nextClick].t < t { nextClick += 1 }
                let click = nextClick < clicks.count ? clicks[nextClick] : nil
                let untilClick = click.map { $0.t - t } ?? .infinity
                let progress = span > 0 ? (t - a.t) / span : 1
                let hand = CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
                let target = untilClick <= PointerSpring.clickLookahead ? click!.point : hand
                spring.advance(toward: target, by: step,
                               using: untilClick <= PointerSpring.rapidLookahead ? .rapid : spring.chosen)
            }
            result[index].x = spring.position.x
            result[index].y = spring.position.y
        }
        anchorToClicks(&result)
        return CursorTrack(samples: result, clicks: clicks, activity: activity, steadyShapes: steadyShapes)
    }

    /// How long either side of a click the pointer is held to where it really was.
    ///
    /// Long enough to cover the approach and the release, short enough that the rest of the
    /// move is still smoothed.
    public static let clickAnchorWindow = 0.14

    /// Pulls the smoothed path back onto the recorded one around every click.
    ///
    /// Smoothing is what makes a recorded pointer look deliberate instead of shaky, and it
    /// is a filter: it rounds corners. Arriving somewhere and stopping is a corner, so the
    /// smoothed path cuts it — the drawn pointer comes to rest a little short of where the
    /// hand actually went. Anywhere else that is invisible and desirable. At a click it is
    /// the one thing that must not happen: the viewer is being shown *what was clicked*, and
    /// a pointer resting an inch above the tab it just pressed says the recording is wrong.
    ///
    /// So the filter yields around a click and the raw sample wins, easing back out over
    /// `clickAnchorWindow` so nothing snaps. Cosine rather than linear for the same reason:
    /// a corner taken out of the path must not be replaced by two new ones.
    private func anchorToClicks(_ smoothed: inout [CursorSample]) {
        guard !clicks.isEmpty else { return }
        let window = Self.clickAnchorWindow
        for index in smoothed.indices {
            let t = smoothed[index].t
            guard let nearest = clicks.min(by: { abs($0.t - t) < abs($1.t - t) }) else { continue }
            let distance = abs(t - nearest.t)
            guard distance < window else { continue }
            // 1 at the click, 0 at the edge of the window, with no kink at either end.
            let weight = (cos(.pi * distance / window) + 1) / 2
            let raw = samples[index]
            smoothed[index].x += (raw.x - smoothed[index].x) * weight
            smoothed[index].y += (raw.y - smoothed[index].y) * weight
        }
    }

    /// The clicks worth drawing a mark for at this moment, each with how far through its
    /// mark it is — 0 the instant the button went down, 1 when the mark has finished.
    ///
    /// Several can overlap: a double-click is two, and they must not be collapsed into one
    /// or the second tap would be invisible, which is exactly the moment somebody is
    /// watching for.
    public func marks(at time: Double, duration: Double = 0.45) -> [(click: Click, progress: Double)] {
        guard duration > 0 else { return [] }
        return clicks.compactMap { click in
            let elapsed = time - click.t
            guard elapsed >= 0, elapsed < duration else { return nil }
            return (click, elapsed / duration)
        }
    }

    private init(samples: [CursorSample], clicks: [Click],
                 activity: [ClosedRange<Double>],
                 steadyShapes: [(t: Double, shape: CursorShape)]) {
        self.samples = samples
        self.clicks = clicks
        self.activity = activity
        self.steadyShapes = steadyShapes
    }

    // MARK: - At rest

    /// Two movements closer together than this are one movement with a hesitation in it.
    static let activityGap = 0.3
    /// How far the pointer has to travel between two readings to count as having moved.
    /// A pointer at rest reads the same place exactly; this is only room for rounding.
    static let stillness = 0.5

    private static func activity(in samples: [CursorSample], input: [InputSample]) -> [ClosedRange<Double>] {
        var moments: [Double] = []
        for (before, after) in zip(samples, samples.dropFirst())
        where hypot(after.x - before.x, after.y - before.y) > stillness {
            moments.append(before.t)
            moments.append(after.t)
        }
        for event in input {
            switch event {
            case .mouseDown(let t, _, _, _), .mouseUp(let t, _, _, _): moments.append(t)
            case .scroll(let t, _, _): moments.append(t)
            case .key: continue
            case .shortcut: continue
            }
        }
        moments.sort()

        var ranges: [ClosedRange<Double>] = []
        for moment in moments {
            if let last = ranges.last, moment - last.upperBound <= activityGap {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, moment)
            } else {
                ranges.append(moment...moment)
            }
        }
        return ranges
    }

    /// How much of the pointer to draw at a moment, for a pointer that goes away when it
    /// is left alone: 1 while it is in use, fading to 0 once it has been still for
    /// `delay`, and back before it moves again.
    ///
    /// Back *before*, not as: the whole recording is already known, so the pointer can be
    /// there when the movement begins instead of arriving part of the way through it. A
    /// pointer that fades in while already travelling reads as one that appeared from
    /// nowhere.
    ///
    /// Stateless, like everything the renderer asks: scrubbing to a moment gives what
    /// playing to it gives.
    public func idleOpacity(at time: Double, after delay: Double,
                            fadeOut: Double = 0.35, fadeIn: Double = 0.2) -> Double {
        guard !activity.isEmpty else {
            // Never touched. It is shown for as long as the delay and then goes.
            return Self.faded(since: time, delay: delay, over: fadeOut)
        }
        // The last stretch that has begun by now.
        var low = 0
        var high = activity.count
        while low < high {
            let middle = (low + high) / 2
            if activity[middle].lowerBound <= time { low = middle + 1 } else { high = middle }
        }
        let previous = low > 0 ? activity[low - 1] : nil
        let next = low < activity.count ? activity[low] : nil

        if let previous, time <= previous.upperBound { return 1 }

        let leaving = Self.faded(since: time - (previous?.upperBound ?? 0), delay: delay, over: fadeOut)
        guard let next, fadeIn > 0 else { return leaving }
        let arriving = 1 - min(1, max(0, (next.lowerBound - time) / fadeIn))
        return max(leaving, arriving)
    }

    private static func faded(since rest: Double, delay: Double, over fade: Double) -> Double {
        guard rest > delay else { return 1 }
        guard fade > 0 else { return 0 }
        return max(0, 1 - (rest - delay) / fade)
    }

    // MARK: - Shapes that last

    /// A shape held for less than this is a flicker.
    static let briefestShape = 0.15

    private static func steadyShapes(in samples: [CursorSample]) -> [(t: Double, shape: CursorShape)] {
        guard let first = samples.first else { return [] }
        // Runs of one shape, as (when it began, what it was).
        var runs: [(t: Double, shape: CursorShape)] = [(first.t, first.shape)]
        for sample in samples.dropFirst() where sample.shape != runs[runs.count - 1].shape {
            runs.append((sample.t, sample.shape))
        }
        let end = samples[samples.count - 1].t

        var steady: [(t: Double, shape: CursorShape)] = []
        for (index, run) in runs.enumerated() {
            let length = (index + 1 < runs.count ? runs[index + 1].t : end) - run.t
            // The first shape is kept however briefly it lasted: there is nothing before
            // it to go on showing. So is the last, which lasts until the recording ends.
            let isBrief = length < briefestShape && index > 0 && index + 1 < runs.count
            if isBrief { continue }
            if steady.last?.shape != run.shape { steady.append(run) }
        }
        return steady
    }

    /// The pointer's shape at a moment, ignoring any it held for only an instant.
    public func steadyShape(at time: Double) -> CursorShape {
        guard !steadyShapes.isEmpty else { return shape(at: time) }
        var low = 0
        var high = steadyShapes.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if steadyShapes[middle].t <= time { low = middle } else { high = middle - 1 }
        }
        return steadyShapes[low].shape
    }

    /// How much the pointer should swell for a click at this moment, 1 being not at all.
    ///
    /// A quick squash and release: the pointer dips in, springs past its size and
    /// settles. It is the cheapest possible way to make a click legible in a silent
    /// video, which is what most of these recordings are.
    public func clickScale(at time: Double, duration: Double = 0.28, depth: Double = 0.25) -> Double {
        guard let click = clicks.last(where: { $0.t <= time && time - $0.t < duration }) else { return 1 }
        let progress = (time - click.t) / duration
        // One dip, one overshoot, settling at 1.
        return 1 - depth * sin(progress * .pi * 2) * (1 - progress)
    }

    /// Where the pointer has been lately, averaged — the camera's idea of where to look.
    ///
    /// Following the pointer exactly is what makes a zoom unwatchable: at 2× every
    /// twitch of a hand is 2× on screen, and the viewer is riding the mouse rather than
    /// watching the work. A camera operator lags the subject and smooths out the
    /// fidgeting, and this is the cheapest honest way to do that.
    ///
    /// Averaged over a window rather than simulated with a spring, deliberately:
    /// scrubbing to a moment must give exactly the same frame as playing to it, and a
    /// stateful simulation gives a different answer depending on how you arrived. The
    /// same rule `Easing.spring` is evaluated under.
    /// - Parameter window: how far back to look, in seconds.
    public func averagePosition(at time: Double, window: Double) -> CGPoint? {
        guard window > 0, !samples.isEmpty else { return position(at: time) }
        let from = time - window

        // Every recorded sample in the window, not a fixed number of probes across it.
        // Probing at a fixed rate aliases: a hand jittering at 10 Hz sampled 12 times a
        // window lands on the same phase repeatedly and the "average" swings as widely
        // as the pointer does. Averaging what was actually recorded cannot alias.
        var low = 0
        var high = samples.count - 1
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].t < from { low = middle + 1 } else { high = middle }
        }

        var total = CGPoint.zero
        var weightTotal = 0.0
        var index = low
        while index < samples.count, samples[index].t <= time {
            let sample = samples[index]
            // Weighted towards now: the far end of the window steers, the near end
            // decides, so the camera leads rather than trailing a long way behind.
            let age = time - sample.t
            let weight = max(0.05, 1 - age / (window * 1.6))
            total.x += sample.x * weight
            total.y += sample.y * weight
            weightTotal += weight
            index += 1
        }

        // Fewer than two samples in the window means a sparse track, not a still hand:
        // interpolating is a better answer than the one sample that happened to land.
        guard weightTotal > 0, index - low > 1 else { return position(at: time) }
        return CGPoint(x: total.x / weightTotal, y: total.y / weightTotal)
    }

    /// How fast the pointer was moving, and which way.
    ///
    /// Direction as well as magnitude, because motion blur has to be smeared *along* the
    /// travel: a blur in the wrong direction looks like a rendering fault rather than
    /// like movement.
    public func velocity(at time: Double, window: Double = 1 / 30) -> CGVector {
        guard window > 0,
              let now = position(at: time),
              let before = position(at: time - window) else { return .zero }
        return CGVector(dx: (now.x - before.x) / window, dy: (now.y - before.y) / window)
    }

    /// Whether the pointer moved far enough recently to be worth motion blur.
    public func speed(at time: Double, window: Double = 1 / 30) -> Double {
        let v = velocity(at: time, window: window)
        return hypot(v.dx, v.dy)
    }
}

/// A clamped spring in two dimensions, stepped a millisecond at a time — the pointer's
/// motion, after the reference's.
struct PointerSpring {
    /// Stiffness, damping and mass, in seconds.
    struct Constants: Equatable {
        var stiffness: Double
        var damping: Double
        var mass: Double

        static let rapid = Constants(stiffness: 530, damping: 40, mass: 1)
        static let medium = Constants(stiffness: 340, damping: 60, mass: 3)
        static let smooth = Constants(stiffness: 470, damping: 70, mass: 3)

        /// Rapid at the low end of the slider, Medium in the middle, Smooth at the top.
        static func blended(_ amount: Double) -> Constants {
            let amount = min(1, max(0, amount))
            if amount <= 0.5 { return mix(.rapid, .medium, amount / 0.5) }
            return mix(.medium, .smooth, (amount - 0.5) / 0.5)
        }

        private static func mix(_ a: Constants, _ b: Constants, _ f: Double) -> Constants {
            Constants(stiffness: a.stiffness + (b.stiffness - a.stiffness) * f,
                      damping: a.damping + (b.damping - a.damping) * f,
                      mass: a.mass + (b.mass - a.mass) * f)
        }
    }

    static let step = 0.001
    /// How far ahead a click becomes what the pointer chases.
    static let clickLookahead = 0.5
    /// How far ahead of a click the stiff spring takes over, so the pointer is on time.
    static let rapidLookahead = 0.175

    let chosen: Constants
    private(set) var position: CGPoint
    private var velocity = CGVector.zero

    init(chosen: Constants, start: CGPoint) {
        self.chosen = chosen
        position = start
    }

    /// One step. Clamped: while it is closing on the target faster than it could stop in
    /// the distance left, it is damped critically, so it eases in rather than overshoots.
    mutating func advance(toward target: CGPoint, by dt: Double, using constants: Constants) {
        let dx = position.x - target.x
        let dy = position.y - target.y
        let distance = hypot(dx, dy)
        var damping = constants.damping
        if distance > 0 {
            let closing = -(velocity.dx * dx + velocity.dy * dy) / distance
            if closing > distance * (constants.stiffness / constants.mass).squareRoot() {
                damping = max(damping, 2 * (constants.mass * constants.stiffness).squareRoot())
            }
        }
        let ax = (-constants.stiffness * dx - damping * velocity.dx) / constants.mass
        let ay = (-constants.stiffness * dy - damping * velocity.dy) / constants.mass
        velocity.dx += ax * dt
        velocity.dy += ay * dt
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt
    }
}
