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

    public init(samples: [CursorSample], input: [InputSample] = []) {
        self.samples = samples.sorted { $0.t < $1.t }
        clicks = input.compactMap { sample in
            guard case .mouseDown(let t, let button, let x, let y) = sample else { return nil }
            return Click(t: t, point: CGPoint(x: x, y: y), isSecondary: button == 1)
        }.sorted { $0.t < $1.t }
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

    /// A smoothed copy of the track.
    ///
    /// An exponential filter, applied forwards and then backwards: one pass alone lags
    /// behind the real pointer, which reads as the cursor trailing the click it is about
    /// to make. Two passes in opposite directions cancel the lag out.
    public func smoothed(_ amount: Double) -> CursorTrack {
        let amount = min(1, max(0, amount))
        guard amount > 0, samples.count > 2 else { return self }

        // 0 → no smoothing, 1 → very heavy. Mapped so the middle of the slider is a
        // noticeable but still-responsive amount.
        let alpha = 1 - pow(amount, 0.35) * 0.92
        var forward = samples
        for index in 1..<forward.count {
            forward[index].x = forward[index].x * alpha + forward[index - 1].x * (1 - alpha)
            forward[index].y = forward[index].y * alpha + forward[index - 1].y * (1 - alpha)
        }
        for index in stride(from: forward.count - 2, through: 0, by: -1) {
            forward[index].x = forward[index].x * alpha + forward[index + 1].x * (1 - alpha)
            forward[index].y = forward[index].y * alpha + forward[index + 1].y * (1 - alpha)
        }
        return CursorTrack(samples: forward, clicks: clicks)
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

    private init(samples: [CursorSample], clicks: [Click]) {
        self.samples = samples
        self.clicks = clicks
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
