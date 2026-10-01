import CoreMedia
import SwiftUI
import TimelineKit

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
            // The selected stretch, as a band under the numbers: I and O mark it from the
            // keyboard, and a selection that is drawn nowhere is one nobody can trust
            // Export Selection with. Behind the ticks, so it colours rather than covers.
            if let range = model.selectedRange {
                let from = viewport.x(forSeconds: range.start.seconds)
                let to = viewport.x(forSeconds: range.end.seconds)
                let band = CGRect(x: from, y: 0, width: max(1, to - from), height: size.height)
                    .intersection(CGRect(origin: .zero, size: size))
                if !band.isNull {
                    context.fill(Path(band), with: .color(StudioPalette.brand.opacity(0.22)))
                    context.fill(Path(CGRect(x: band.minX, y: 0, width: 1, height: size.height)),
                                 with: .color(StudioPalette.brand.opacity(0.8)))
                    context.fill(Path(CGRect(x: band.maxX - 1, y: 0, width: 1, height: size.height)),
                                 with: .color(StudioPalette.brand.opacity(0.8)))
                }
            }

            let pointsPerSecond = viewport.pointsPerSecond
            let step = Self.step(forPointsPerSecond: pointsPerSecond)
            let parts = TimelineLayout.rulerSubdivisions(step: step, pointsPerSecond: pointsPerSecond)
            let visible = viewport.visibleSeconds
            let end = model.duration.seconds
            // Where the playhead's knob is, so the numbers can make way for it. Read here,
            // so the ruler redraws as the playhead moves — a few dozen labels, cheaply.
            let playheadX = viewport.x(for: model.playhead)
            var second = (visible.lowerBound / step).rounded(.down) * step

            while second <= visible.upperBound {
                defer { second += step }
                guard second >= 0, second <= end + step else { continue }
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
                // Faded out from under the playhead's knob, which is drawn over this
                // ruler: "0s" with the playhead parked at the start was a number read
                // through a blue disc. See `TimelineLayout.rulerLabelOpacity`.
                let opacity = TimelineLayout.rulerLabelOpacity(minX: labelX - labelWidth / 2,
                                                               maxX: labelX + labelWidth / 2,
                                                               playheadX: playheadX)
                if opacity > 0 {
                    var faded = context
                    faded.opacity = opacity
                    faded.draw(label, at: CGPoint(x: labelX, y: 6), anchor: .center)
                }

                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: size.height - 5, width: 3, height: 3)),
                             with: .color(.secondary.opacity(0.7)))

                // Smaller, fainter dots between each pair of labels, so the eye can
                // subdivide without another row of numbers — one halfway when the numbers
                // are close, more as zooming spreads them out. None past the end.
                for part in 1..<parts {
                    let time = second + step * Double(part) / Double(parts)
                    guard time <= end else { break }
                    let between = viewport.x(forSeconds: time)
                    guard between < size.width else { break }
                    let isHalf = parts % 2 == 0 && part == parts / 2
                    let diameter: CGFloat = isHalf ? 2.2 : 1.6
                    context.fill(Path(ellipseIn: CGRect(x: between - diameter / 2,
                                                        y: size.height - 3.5 - diameter / 2,
                                                        width: diameter, height: diameter)),
                                 with: .color(.secondary.opacity(isHalf ? 0.45 : 0.3)))
                }
            }

            // The markers dropped while recording: a small flag each, over the numbers, in
            // the colour a marker is everywhere. Orange rather than the brand blue, which is
            // the selection's, and legible on the ruler's light and dark backgrounds alike.
            for time in model.markerTimes {
                let x = viewport.x(forSeconds: time.seconds)
                guard x >= -6, x <= size.width + 6 else { continue }
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)),
                             with: .color(.orange.opacity(0.9)))
                var flag = Path()
                flag.move(to: CGPoint(x: x, y: 0))
                flag.addLine(to: CGPoint(x: x + 7, y: 3))
                flag.addLine(to: CGPoint(x: x, y: 6))
                flag.closeSubpath()
                context.fill(flag, with: .color(.orange))
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

    /// A tick every second up close, every ten when the whole thing is on screen. The rule
    /// itself is `TimelineLayout.rulerStep(forPointsPerSecond:)`, where it is tested.
    static func step(forPointsPerSecond pointsPerSecond: Double) -> Double {
        TimelineLayout.rulerStep(forPointsPerSecond: pointsPerSecond)
    }
}
