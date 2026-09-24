import CoreMedia
import SwiftUI
import TimelineKit

/// Sound, drawn through whatever is playing it.
///
/// Indexed by *source* time, not timeline time: a trim changes which footage a run shows
/// and a speed changes how long it takes, so a waveform drawn against the timeline would
/// slide off the sound it belongs to the first time either is used. Within one run the
/// mapping is affine, so each contributes one linearly-mapped slice and the whole row
/// costs one pass over the columns.
///
/// It used to read `model.timeline.clips` directly, which quietly said that the only thing
/// a waveform can be indexed by is the clip sequence. That stopped being true twice over:
/// a detached sound lane has runs of its own, and an imported sound has a file of its own
/// with no clips anywhere near it. So the mapping arrives as `spans` and this view knows
/// nothing about where they came from — which is also what makes it testable by eye at a
/// glance, since a wrong span is visible rather than inferred.
struct TimelineWaveform: View {
    /// One stretch of the row over which points map linearly to seconds of the source.
    ///
    /// Deliberately not a `Clip` or a `SoundRun`: it is the *intersection* of the two
    /// ideas — where this piece sits on the timeline, and where its sound starts — and
    /// holding it separately is what lets one drawing routine serve three lanes.
    struct Span: Equatable {
        let start: CMTime
        let duration: CMTime
        let sourceStart: CMTime
        let speed: Double

        init(start: CMTime, duration: CMTime, sourceStart: CMTime, speed: Double = 1) {
            self.start = start
            self.duration = duration
            self.sourceStart = sourceStart
            self.speed = speed
        }
    }

    let viewport: TimelineViewport
    let spans: [Span]
    let peaks: WaveformPeaks
    let height: CGFloat
    var opacity: Double = 0.28

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var path = Path()

            for span in spans {
                let left = viewport.x(for: span.start)
                let right = viewport.x(for: span.start + span.duration)
                guard right > 0, left < size.width, right > left else { continue }

                // Only the part on screen is drawn, so a long recording costs the same
                // as a short one.
                let visibleLeft = max(0, left)
                let visibleRight = min(size.width, right)
                let columns = max(1, Int((visibleRight - visibleLeft).rounded()))

                let secondsPerPoint = span.speed / viewport.pointsPerSecond
                let sourceFrom = span.sourceStart.seconds + (visibleLeft - left) * secondsPerPoint
                let sourceTo = span.sourceStart.seconds + (visibleRight - left) * secondsPerPoint

                let values = peaks.columns(from: sourceFrom, to: sourceTo, count: columns,
                                           pointsPerSecond: viewport.pointsPerSecond / span.speed)

                // One closed shape: out along the top, back along the bottom.
                for (column, value) in values.enumerated() {
                    let x = visibleLeft + Double(column)
                    let y = midY - Double(value.max) * midY * 0.92
                    if column == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                for (column, value) in values.enumerated().reversed() {
                    let x = visibleLeft + Double(column)
                    path.addLine(to: CGPoint(x: x, y: midY - Double(value.min) * midY * 0.92))
                }
                path.closeSubpath()
            }

            context.fill(path, with: .color(.white.opacity(opacity)))
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

extension TimelineWaveform.Span {
    /// The picture's own spans: the recording's sound as the clips cut it.
    static func followingClips(of timeline: Timeline) -> [Self] {
        timeline.clips.enumerated().map { index, clip in
            Self(start: timeline.start(ofClipAt: index),
                 duration: clip.duration,
                 sourceStart: clip.sourceStart,
                 speed: clip.speed)
        }
    }

    /// One run of a detached sound lane, which already carries everything a span needs.
    init(_ run: SoundRun) {
        self.init(start: run.start, duration: run.duration,
                  sourceStart: run.sourceStart, speed: run.speed)
    }

    /// An imported sound: one span, and never sped up — an `AudioRegion` has no speed,
    /// because trimming it changes how much of the file plays rather than how fast.
    init(_ region: AudioRegion) {
        self.init(start: region.start, duration: region.duration, sourceStart: region.sourceStart)
    }
}
