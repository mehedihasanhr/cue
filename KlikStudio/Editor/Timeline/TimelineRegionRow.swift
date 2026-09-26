import CoreMedia
import SwiftUI
import TimelineKit

/// One lane of regions — zooms, blurs, annotations.
///
/// Generic over `TimelineRegion` because moving, resizing, selecting and deleting are
/// the same job whatever the region is: they differ in what they mean, not in how they
/// sit on a timeline. The zoom row needs all of it anyway, so every other lane is free.
struct TimelineRegionRow<Region: TimelineRegion, Badge: View>: View {
    let model: EditorModel
    let regions: [Region]
    let tint: Color
    let title: String
    let symbol: String
    let height: CGFloat
    /// How this kind of region is selected, so the row does not have to know.
    let selection: (UUID) -> Selection
    /// What to draw *inside* the chip, for a lane whose contents have a shape worth
    /// reading rather than only a label worth naming.
    ///
    /// Defaulted to nothing, so the four lanes that are labels stay exactly as they were.
    /// Only the sound lane fills it in: what you want off a piece of music is where the
    /// words are and where the quiet bit is, so you can line the picture up with them, and
    /// no filename says that. The peaks and the mapping arrive together because a waveform
    /// is meaningless without the spans that say which second each point stands for.
    var waveform: (Region) -> (peaks: WaveformPeaks, spans: [TimelineWaveform.Span])? = { _ in nil }
    @ViewBuilder let badge: (Region) -> Badge

    @State private var dragOrigin: (start: CMTime, duration: CMTime)?
    /// Which grip the pointer is over, as "<region id>-<side>".
    ///
    /// One piece of state for the whole lane rather than one per chip: only one grip can
    /// be under the pointer at a time, so a single value cannot get out of step with
    /// itself the way a dictionary of booleans can.
    @State private var hoveredGrip: String?

    private var viewport: TimelineViewport { model.viewport }
    private let edgeWidth: CGFloat = 8
    /// Below this the two grips would touch, so the chip is left plain.
    private let minimumGripWidth: CGFloat = 26

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: height)

            ForEach(regions) { region in
                body(for: region)
            }
        }
        .frame(height: height)
    }

    private func isSelected(_ region: Region) -> Bool {
        model.selection == selection(region.id)
    }

    private func body(for region: Region) -> some View {
        let left = viewport.x(for: region.start)
        let width = max(6, region.duration.seconds * viewport.pointsPerSecond)

        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.opacity(isSelected(region) ? 0.85 : 0.5))
            .overlay { shape(of: region, width: width, left: left) }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected(region) ? 0.9 : 0), lineWidth: 1.5)
            }
            .overlay {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                    badge(region)
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
            }
            .frame(width: width, height: height)
            .offset(x: left)
            .contentShape(Rectangle())
            .onTapGesture { model.select(selection(region.id)) }
            .gesture(move(region))
            .overlay {
                edge(region, leading: true, width: width).offset(x: left)
                edge(region, leading: false, width: width).offset(x: left + width - edgeWidth)
            }
            .contextMenu {
                // Acting on the region under the pointer rather than on `model.selection`,
                // which is why these take a `Selection` — a right-click should not change
                // what the inspector is showing on its way to copying something.
                Button("Cut") { model.cutRegion(selection(region.id)) }
                Button("Copy") { model.copyRegion(selection(region.id)) }
                Button("Duplicate") { model.duplicateRegion(selection(region.id)) }
                // Pasting is about the playhead, not about this region, but it belongs here
                // for the same reason it belongs in a Finder window's menu: it is where the
                // hand already is after a copy.
                Button("Paste") { model.pasteAtPlayhead() }
                    .disabled(!model.canPasteRegion)
                Divider()
                Button("Delete", role: .destructive) { model.deleteSelection(region.id) }
            }
            .help("\(title) · \(Timecode.length(region.duration))")
    }

    /// The waveform, drawn across the row and then masked down to this chip.
    ///
    /// Masked rather than drawn to fit, for the reason `TimelineSoundRow` does the same: the
    /// peaks are indexed by source time, so the drawing needs the lane's coordinates and the
    /// chip only decides what survives.
    @ViewBuilder
    private func shape(of region: Region, width: CGFloat, left: CGFloat) -> some View {
        if let drawn = waveform(region) {
            TimelineWaveform(viewport: viewport, spans: drawn.spans, peaks: drawn.peaks,
                             height: height, opacity: 0.38)
                .mask {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .frame(width: width)
                        .offset(x: left)
                }
                .offset(x: -left)
                .frame(width: width, alignment: .leading)
                .clipped()
        }
    }

    // MARK: - Gestures

    /// A grabbable end of a chip: the hit area, and the line that says it is there.
    ///
    /// The hit area was always here; the line was not, and an invisible handle is a
    /// feature only the person who wrote it knows about. So the ends are drawn — two
    /// vertical bars, the same vocabulary as the trim handles on a clip — and they are
    /// drawn *always* rather than on hover, because a control you have to find by
    /// sweeping the pointer across the chip is barely better than no control.
    ///
    /// Hidden below `minimumGripWidth`: on a chip a few points wide the two bars would
    /// meet in the middle and read as a filled block rather than as two ends, and the
    /// drag still works because the hit areas do not depend on the drawing.
    private func edge(_ region: Region, leading: Bool, width: CGFloat) -> some View {
        let key = "\(region.id)-\(leading)"
        let isHovered = hoveredGrip == key
        return Rectangle()
            .fill(.clear)
            .frame(width: edgeWidth, height: height)
            .overlay {
                if width >= minimumGripWidth {
                    Capsule()
                        .fill(.white.opacity(isHovered ? 1 : (isSelected(region) ? 0.9 : 0.55)))
                        .frame(width: isHovered ? 3 : 2, height: max(8, height - 10))
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .animation(StudioMotion.state, value: isHovered)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hoveredGrip = inside ? key : (hoveredGrip == key ? nil : hoveredGrip)
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(resize(region, leading: leading))
    }

    private func move(_ region: Region) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = begin(region, name: "Move \(title)")
                let proposed = origin.start + CMTime(seconds: value.translation.width / viewport.pointsPerSecond,
                                                     preferredTimescale: 600)
                let start = snapping().snapRegion(start: max(.zero, proposed),
                                                  duration: origin.duration,
                                                  to: others(of: region))
                model.apply(Commands.MoveRegion(id: region.id, start: max(.zero, start)))
            }
            .onEnded { _ in end() }
    }

    private func resize(_ region: Region, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = begin(region, name: "Resize \(title)")
                let delta = CMTime(seconds: value.translation.width / viewport.pointsPerSecond,
                                   preferredTimescale: 600)
                let edges = others(of: region)
                if leading {
                    let proposed = snapping().snap(max(.zero, origin.start + delta), to: edges)
                    let limit = origin.start + origin.duration - Clip.minimumDuration
                    let start = min(proposed, limit)
                    model.apply(Commands.MoveRegion(id: region.id,
                                                    start: start,
                                                    duration: origin.start + origin.duration - start))
                } else {
                    let proposed = snapping().snap(origin.start + origin.duration + delta, to: edges)
                    model.apply(Commands.MoveRegion(id: region.id,
                                                    start: origin.start,
                                                    duration: max(Clip.minimumDuration, proposed - origin.start)))
                }
            }
            .onEnded { _ in end() }
    }

    private func begin(_ region: Region, name: String) -> (start: CMTime, duration: CMTime) {
        if let dragOrigin { return dragOrigin }
        let origin = (region.start, region.duration)
        dragOrigin = origin
        model.select(selection(region.id))
        model.document.beginInteraction(name)
        return origin
    }

    private func end() {
        dragOrigin = nil
        model.document.endInteraction()
    }

    /// Hold ⌘ to place something exactly where you put it.
    private func snapping() -> Snapping {
        NSEvent.modifierFlags.contains(.command)
            ? .disabled
            : Snapping(pointsPerSecond: viewport.pointsPerSecond)
    }

    /// Everything worth snapping to except this region's own edges, which would only
    /// make it stick to where it already is.
    private func others(of region: Region) -> [CMTime] {
        model.timeline.boundaries.filter { $0 != region.start && $0 != region.end }
    }
}
