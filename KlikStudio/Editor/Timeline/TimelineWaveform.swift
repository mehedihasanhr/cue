import CoreMedia
import SwiftUI
import TimelineKit

/// The recording's sound, drawn through the clips that play it.
///
/// Indexed by *source* time, not timeline time: a trim changes which footage a clip
/// shows and a speed changes how long it takes, so a waveform drawn against the timeline
/// would slide off the sound it belongs to the first time either is used. Within one
/// clip the mapping is affine, so each clip contributes one linearly-mapped slice and
/// the whole row costs one pass over the columns.
struct TimelineWaveform: View {
    let model: EditorModel
    let peaks: WaveformPeaks
    let height: CGFloat

    private var viewport: TimelineViewport { model.viewport }

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var path = Path()

            for (index, clip) in model.timeline.clips.enumerated() {
                let start = model.timeline.start(ofClipAt: index)
                let left = viewport.x(for: start)
                let right = viewport.x(for: start + clip.duration)
                guard right > 0, left < size.width, right > left else { continue }

                // Only the part on screen is drawn, so a long recording costs the same
                // as a short one.
                let visibleLeft = max(0, left)
                let visibleRight = min(size.width, right)
                let columns = max(1, Int((visibleRight - visibleLeft).rounded()))

                let secondsPerPoint = clip.speed / viewport.pointsPerSecond
                let sourceFrom = clip.sourceStart.seconds + (visibleLeft - left) * secondsPerPoint
                let sourceTo = clip.sourceStart.seconds + (visibleRight - left) * secondsPerPoint

                let values = peaks.columns(from: sourceFrom, to: sourceTo, count: columns,
                                           pointsPerSecond: viewport.pointsPerSecond / clip.speed)

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

            context.fill(path, with: .color(.white.opacity(0.28)))
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}
