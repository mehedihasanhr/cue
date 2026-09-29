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

                // The time centred over its mark, and a dot under it: the mark is the
                // second, and the rows below put a region's edge on the same number.
                // Held inside the ruler at the very start, where centring would put half
                // of "0s" off the edge.
                let label = context.resolve(Text(Timecode.ruler(second, step: step))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary))
                let labelWidth = label.measure(in: size).width
                let labelX = max(x, labelWidth / 2 + 1)
                context.draw(label, at: CGPoint(x: labelX, y: 6), anchor: .center)

                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: size.height - 5, width: 3, height: 3)),
                             with: .color(.secondary.opacity(0.7)))

                // A smaller, fainter dot between each pair of labels, so the eye can
                // subdivide without another row of numbers.
                let midway = viewport.x(forSeconds: second + step / 2)
                if midway < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: midway - 1, y: size.height - 4.5, width: 2, height: 2)),
                                 with: .color(.secondary.opacity(0.4)))
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .gesture(
            // The lanes' own space, which stays put: the ruler scrolls with the viewport,
            // and a gesture measured in a space that can scroll under it is a gesture that
            // can chase itself.
            DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineStrip.space))
                .onChanged { value in
                    model.beginScrub()
                    model.scrub(to: viewport.time(at: value.location.x))
                }
                .onEnded { _ in model.endScrub() }
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
