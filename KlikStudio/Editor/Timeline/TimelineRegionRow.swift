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
    /// A lane's own right-click menu, for a kind with more to do than cut, copy and delete.
    /// `nil` keeps the menu every lane has.
    var menu: ((Region) -> AnyView)?
    @ViewBuilder let badge: (Region) -> Badge

    /// Which grip the pointer is over, as "<region id>-<side>".
    ///
    /// One piece of state for the whole lane rather than one per chip: only one grip can
    /// be under the pointer at a time, so a single value cannot get out of step with
    /// itself the way a dictionary of booleans can.
    @State private var hoveredGrip: String?

    private var viewport: TimelineViewport { model.viewport }
    private let radius: CGFloat = TimelineChipBackground.radius

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: height)

            ForEach(regions) { region in
                body(for: region)
            }
        }
        .frame(height: height)
    }

    private func isSelected(_ region: Region) -> Bool {
        model.isSelected(selection(region.id))
    }

    private func body(for region: Region) -> some View {
        // Mid-drag this is the gesture's answer; otherwise the document's. One rule for
        // both, so a chip being dragged and a chip standing still cannot be placed by two
        // different pieces of arithmetic.
        let live = model.liveRange(of: region.id, start: region.start, duration: region.duration)
        let left = viewport.x(for: live.start)
        let width = max(6, live.duration.seconds * viewport.pointsPerSecond)

        return TimelineChipBackground(tint: tint, isSelected: isSelected(region))
            .overlay { shape(of: region, width: width, left: left) }
            .frame(width: width, height: height)
            .overlay { label(region, width: width) }
            .overlay(alignment: .leading) { edge(region, leading: true, width: width) }
            .overlay(alignment: .trailing) { edge(region, leading: false, width: width) }
            // Anything that no longer fits is cut off by the chip rather than reflowed
            // inside it. See `label(_:width:)`.
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            // ⌘ adds to the selection instead of replacing it, which is what lets a drag
            // afterwards carry several chips at once.
            .onTapGesture {
                model.select(selection(region.id),
                             extending: NSEvent.modifierFlags.contains(.command))
            }
            .gesture(move(region))
            .contextMenu {
                if let menu {
                    menu(region)
                } else {
                    standardMenu(region)
                }
            }
            .help("\(title) · \(Timecode.length(live.duration))")
            // Laid out at its place on the timeline, rather than drawn there.
            //
            // This used to be `.offset(x: left)`, and an offset is a *drawing* — the view's
            // layout frame stays where the stack put it, which for every chip in this lane
            // is the very start. Everything that reads a layout frame therefore read the
            // wrong one: the handles came out at the lane's left edge instead of on their
            // chip, and the chips' hit areas all piled up on top of each other there, so a
            // click went to whichever chip happened to be last in the stack rather than to
            // the one under the pointer. That is why only the newest region on a lane could
            // be selected, and why a chip further along could not be reached at all.
            //
            // `.position` places it, so the frame and the picture are the same rectangle.
            .position(x: left + width / 2, y: height / 2)
    }

    /// Cut, copy, duplicate, paste and delete: what every lane offers.
    @ViewBuilder
    private func standardMenu(_ region: Region) -> some View {
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

    /// What the chip says: the kind of thing it is, faintly, and under it the details —
    /// centred, the way a player's timeline labels its pieces.
    ///
    /// `fixedSize` stops the words being squeezed and re-broken as the chip narrows; the
    /// chip's own clip takes off whatever no longer fits, which is one edge moving instead
    /// of a line of text rearranging itself.
    private func label(_ region: Region, width: CGFloat) -> some View {
        TimelineChipLabel(title: title, height: height, width: width,
                          minimumWidth: TimelineHandle.target * 2 + 20) {
            HStack(spacing: 5) {
                // Empty for a lane whose chips name their own kind — see the annotation
                // lane, where each chip is a different kind of thing.
                if !symbol.isEmpty {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                badge(region)
            }
        }
        .allowsHitTesting(false)
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
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .frame(width: width)
                        .offset(x: left)
                }
                .offset(x: -left)
                .frame(width: width, alignment: .leading)
                .clipped()
        }
    }

    // MARK: - Gestures

    /// A grabbable end of a chip. The drawing is `TimelineHandle`; this says when it is
    /// offered and what happens when it is pulled.
    private func edge(_ region: Region, leading: Bool, width: CGFloat) -> some View {
        let key = "\(region.id)-\(leading)"
        let isHovered = hoveredGrip == key
        return TimelineHandle(leading: leading,
                              height: height,
                              chipWidth: width,
                              radius: radius,
                              isVisible: isSelected(region) || isHovered,
                              isHovered: isHovered,
                              label: leading ? "Drag to change when this \(title.lowercased()) starts"
                                             : "Drag to change when this \(title.lowercased()) ends")
            .onHover { inside in
                // Ignored while a gesture runs: a chip sliding under a stationary pointer
                // fires hover on and off all the way along, and each one costs a fade and a
                // cursor push. See `EditorModel.isGesturing`.
                guard !model.isGesturing else { return }
                hoveredGrip = inside ? key : (hoveredGrip == key ? nil : hoveredGrip)
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(resize(region, leading: leading))
    }

    /// Dragging the body slides everything selected, keeping every length.
    ///
    /// No command is applied while the pointer moves. The gesture lives in `TimelineDrag`,
    /// the chips draw from it, and the document hears one command when the mouse comes up —
    /// see that type for what applying a command per mouse-move was costing.
    private func move(_ region: Region) -> some Gesture {
        drag(region, grip: .body)
    }

    /// Dragging an end resizes everything selected by the same amount, from the same end.
    private func resize(_ region: Region, leading: Bool) -> some Gesture {
        drag(region, grip: leading ? .head : .tail)
    }

    private func drag(_ region: Region, grip: TimelineDrag.Grip) -> some Gesture {
        // Measured in the window's coordinates, never the chip's.
        //
        // `DragGesture`'s default space is `.local` — the dragged view's own — and this
        // view *moves while it is being dragged*, which makes that space move with it. Every
        // point the chip travels to the right takes the pointer's local x the same distance
        // to the left, so the translation shrinks, so the chip comes back, so the
        // translation grows again. That oscillation is the chip appearing at its old and new
        // positions on alternate frames. A space that does not move cannot feed back.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if !model.drag.isActive {
                    model.beginDrag(anchor: selection(region.id), grip: grip)
                }
                // Measured from where the gesture started every frame, never from where the
                // last frame left it, so a slow drag accumulates no drift.
                model.dragOffset(CMTime(seconds: value.translation.width / viewport.pointsPerSecond,
                                        preferredTimescale: 600),
                                 pointsPerSecond: viewport.pointsPerSecond)
            }
            .onEnded { _ in model.endDrag() }
    }
}
