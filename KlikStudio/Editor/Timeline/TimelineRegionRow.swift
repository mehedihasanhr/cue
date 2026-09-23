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
    @ViewBuilder let badge: (Region) -> Badge

    @State private var dragOrigin: (start: CMTime, duration: CMTime)?

    private var viewport: TimelineViewport { model.viewport }
    private let edgeWidth: CGFloat = 8

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
                edge(region, leading: true).offset(x: left)
                edge(region, leading: false).offset(x: left + width - edgeWidth)
            }
            .contextMenu {
                Button("Delete", role: .destructive) { model.deleteSelection(region.id) }
            }
            .help("\(title) · \(Timecode.length(region.duration))")
    }

    // MARK: - Gestures

    private func edge(_ region: Region, leading: Bool) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: edgeWidth, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
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
