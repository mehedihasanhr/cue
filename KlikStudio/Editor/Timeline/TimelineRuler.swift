import CoreMedia
import SwiftUI

/// The times along the top, and the lane you scrub in.
///
/// Scrubbing lives here and on empty background rather than over the whole strip: a
/// drag that both scrubs *and* moves whatever is under it does neither well, and that
/// is what a strip-wide gesture amounts to once the rows below can be dragged.
struct TimelineRuler: View {
    let model: EditorModel
    let height: CGFloat

    private var viewport: TimelineViewport { model.viewport }

    var body: some View {
        Canvas { context, size in
            let step = Self.step(forPointsPerSecond: viewport.pointsPerSecond)
            let visible = viewport.visibleSeconds
            var second = (visible.lowerBound / step).rounded(.down) * step

            while second <= visible.upperBound {
                defer { second += step }
                guard second >= 0, second <= model.duration.seconds + step else { continue }
                let x = viewport.x(forSeconds: second)

                context.draw(Text(Timecode.ruler(second, step: step))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary),
                    at: CGPoint(x: x + 3, y: 6), anchor: .leading)

                // A dot between each pair of labels, so the eye can subdivide without
                // another row of numbers.
                let midway = viewport.x(forSeconds: second + step / 2)
                if midway < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: midway - 1, y: size.height - 4, width: 2, height: 2)),
                                 with: .color(.secondary.opacity(0.4)))
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.viewport.followsPlayhead = false
                    model.scrub(to: viewport.time(at: value.location.x))
                }
        )
    }

    /// A tick every second up close, every ten when the whole thing is on screen.
    static func step(forPointsPerSecond pointsPerSecond: Double) -> Double {
        for candidate in [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600] where candidate * pointsPerSecond >= 56 {
            return candidate
        }
        return 900
    }
}
