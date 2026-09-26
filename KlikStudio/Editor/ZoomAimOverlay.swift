import CoreMedia
import SwiftUI
import TimelineKit

/// Framing a zoom on the picture: where it looks, and how much it takes in.
///
/// `ZoomRegion` has carried `center` and `scale` from the beginning and there has never
/// been a way to set either by eye. Two normalised coordinates and a slider were the cheap
/// answer and the wrong one, because nobody knows where 0.38, 0.71 is, and nobody thinks
/// "2.4×". What they know is *which part of the screen they want in shot* — which is a
/// rectangle, and is what this draws.
///
/// The preview is flattened while this tool is on (`EditorTool.flattensPreview`), and that
/// is the whole reason the tool works. Over the composed picture the zoom is already in
/// force, so the framing rectangle would always be the frame: the tool would show you its
/// own answer and give you no way to ask the question. Flat, the picture is the recording,
/// and the box is a rectangle of it.
///
/// Every edit here goes through `EditorModel.setZoomArea`, which owns the arithmetic and
/// the clamping, so the box and the renderer cannot disagree about what was drawn.
struct ZoomAimOverlay: View {
    let model: EditorModel
    /// Where the picture is, in this view's coordinates.
    let stage: CGRect

    /// The framing at the moment a drag began. Held so every change is measured against
    /// where the box started rather than against where the last event left it, which is
    /// what stops a slow drag accumulating rounding into a drift.
    @State private var origin: CGRect?
    /// Where the drag has put the box, before the document has been asked about it.
    ///
    /// The box used to be drawn from the model alone, so every frame of a drag waited on a
    /// command, a refresh and a re-render of the preview before it moved: the pointer led
    /// and the box followed a beat behind, which is the whole of "not smooth". The drag
    /// draws itself now, through the same clamping the model applies, so what is on screen
    /// is both immediate and honest about what will be rendered.
    @State private var draft: CGRect?
    @State private var isDragging = false

    private var geometry: CanvasGeometry {
        CanvasGeometry(stage: stage, scene: model.scene)
    }

    /// The zoom being framed. The overlay is only ever reached from one, but a delete or
    /// an undo can take it away while the tool is still on.
    private var zoom: ZoomRegion? {
        guard case .zoom(let id) = model.selection else { return nil }
        return model.timeline.zooms.first { $0.id == id }
    }

    /// How long a corner bracket's arms are, and how thick they are drawn.
    private let arm: CGFloat = 20
    private let thickness: CGFloat = 3

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A catcher under the box: a drag on empty picture frames a new area from
            // scratch, the way the blur tool draws a new rectangle.
            Color.clear
                .contentShape(Rectangle())
                .gesture(frameFromScratch)

            if let zoom {
                let area = draft ?? model.zoomArea(of: zoom)
                let rect = geometry.view(blur: area)
                shade(around: rect)
                box(rect, zoom: zoom)
                result(of: area)
            }
            hint
        }
        // Escape leaves the tool, as it does on the other canvas tools. The zoom stays
        // selected, so the inspector is still showing what was just framed.
        .onExitCommand { model.tool = .frame }
    }

    /// What this zoom will actually look like, live, in the corner.
    ///
    /// The tool flattens the preview — it has to, because a framing box drawn over an
    /// already-zoomed picture would always be the whole picture, so the tool would be
    /// showing you its own answer and refusing you the question. The cost was that while
    /// aiming a zoom there was no moment at which you could see the zoom, which is most of
    /// what "the zooming effect is not working" turned out to mean.
    ///
    /// It costs nothing to render. This is the picture already on screen, scaled up and
    /// slid so the framed square fills the panel — which is precisely what the zoom does to
    /// the frame. No second render, no decode, and it cannot disagree with the box, because
    /// it is drawn from the same rectangle.
    @ViewBuilder
    private func result(of area: CGRect) -> some View {
        if let preview = model.preview, area.width > 0, stage.width > 0 {
            let width: CGFloat = 188
            let height = width * stage.height / stage.width
            let inner = CGSize(width: width / area.width, height: height / area.height)

            VStack(alignment: .leading, spacing: 5) {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: inner.width, height: inner.height)
                    .offset(x: -area.minX * inner.width, y: -area.minY * inner.height)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }
                Text("What this zoom shows")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(10)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(12)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    // MARK: - The frame

    /// Everything outside the box, dimmed — so the box reads as "this is what you will
    /// see" rather than as a rectangle lying on the picture.
    private func shade(around rect: CGRect) -> some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(rect)
            context.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private func box(_ rect: CGRect, zoom: ZoomRegion) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(.white.opacity(isDragging ? 0.95 : 0.7), lineWidth: 1)
                .background(Color.accentColor.opacity(0.06))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .contentShape(Rectangle())
                .gesture(move(from: zoom))
                .onHover { inside in
                    if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }

            // The scale, on the box, because it is the number the box is setting.
            Text("\(scaleShown(zoom), format: .number.precision(.fractionLength(0...1)))×")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .offset(x: rect.minX + 8, y: rect.minY + 8)
                .allowsHitTesting(false)

            ForEach(Corner.allCases, id: \.self) { corner in
                grip(corner, of: rect, zoom: zoom)
            }
        }
    }

    /// The magnification the box is standing for — the draft's while a drag is running, so
    /// the number on the box and the box itself are never a frame out of step.
    private func scaleShown(_ zoom: ZoomRegion) -> Double {
        guard let draft, draft.width > 0 else { return zoom.scale }
        return 1 / draft.width
    }

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        /// Which way this corner moves the box's far edge — the edge it is anchored to
        /// stays put, so resizing feels like pulling a sheet rather than moving it.
        var anchorIsMax: (x: Bool, y: Bool) {
            switch self {
            case .topLeading: (true, true)
            case .topTrailing: (false, true)
            case .bottomLeading: (true, false)
            case .bottomTrailing: (false, false)
            }
        }

        var isTrailing: Bool { !anchorIsMax.x }
        var isBottom: Bool { !anchorIsMax.y }

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
            case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        @available(macOS 15.0, *)
        var cursor: NSCursor {
            switch self {
            case .topLeading: .frameResize(position: .topLeft, directions: .all)
            case .topTrailing: .frameResize(position: .topRight, directions: .all)
            case .bottomLeading: .frameResize(position: .bottomLeft, directions: .all)
            case .bottomTrailing: .frameResize(position: .bottomRight, directions: .all)
            }
        }
    }

    /// An angle at the corner rather than a block on it.
    ///
    /// A square handle is a viewfinder's answer to nothing: it covers the picture at the
    /// one place the user is looking, and it says "grab me" without saying which way the
    /// corner goes. Two arms along the edges they belong to leave the corner itself clear
    /// and read as the corner of a frame.
    nonisolated private struct CornerBracket: Shape {
        let isTrailing: Bool
        let isBottom: Bool

        func path(in rect: CGRect) -> Path {
            let vertexX = isTrailing ? rect.maxX : rect.minX
            let vertexY = isBottom ? rect.maxY : rect.minY
            let alongX = isTrailing ? rect.minX : rect.maxX
            let alongY = isBottom ? rect.minY : rect.maxY
            var path = Path()
            path.move(to: CGPoint(x: alongX, y: vertexY))
            path.addLine(to: CGPoint(x: vertexX, y: vertexY))
            path.addLine(to: CGPoint(x: vertexX, y: alongY))
            return path
        }
    }

    private func grip(_ corner: Corner, of rect: CGRect, zoom: ZoomRegion) -> some View {
        let point = corner.point(in: rect)
        // The arms run inward from the corner, and the stroke is inset by half its width
        // so its outer edge lands on the box's line instead of straddling it.
        let inset = thickness / 2
        return CornerBracket(isTrailing: corner.isTrailing, isBottom: corner.isBottom)
            .stroke(.white, style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
            .padding(inset)
            .frame(width: arm, height: arm)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .offset(x: corner.isTrailing ? point.x - arm : point.x,
                    y: corner.isBottom ? point.y - arm : point.y)
            // Bigger than it looks, because a 3pt line is not a target.
            .contentShape(Rectangle().inset(by: -8))
            .gesture(resize(corner, from: zoom))
            .onHover { inside in
                if inside, #available(macOS 15.0, *) {
                    corner.cursor.set()
                } else if inside {
                    NSCursor.crosshair.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    // MARK: - Gestures

    /// Dragging the box moves what the zoom looks at, at the magnification it already has.
    private func move(from zoom: ZoomRegion) -> some Gesture {
        // The window's coordinates: the box moves as it is dragged, so its own local space
        // would move under the gesture driving it. See `TimelineRegionRow.drag(_:grip:)`.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = begin(zoom, name: "Move Zoom")
                let delta = normalisedDelta(value.translation)
                frame(zoom, to: start.offsetBy(dx: delta.width, dy: delta.height),
                      name: "Move Zoom")
            }
            .onEnded { _ in end() }
    }

    /// Dragging a corner changes how much is in shot, holding the opposite corner still.
    private func resize(_ corner: Corner, from zoom: ZoomRegion) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = begin(zoom, name: "Frame Zoom")
                let delta = normalisedDelta(value.translation)
                let anchor = corner.anchorIsMax
                // A zoom is one number, so the box stays the picture's shape and a corner
                // drag has one degree of freedom. Taking it from the horizontal alone left
                // a straight pull up or down doing nothing at all, which reads as a broken
                // handle; the drag is measured along the corner's diagonal instead, so both
                // axes push the corner the way the pointer is going.
                let outward = (x: anchor.x ? -delta.width : delta.width,
                               y: anchor.y ? -delta.height : delta.height)
                let side = max(0.05, start.width + (outward.x + outward.y) / 2)
                let x = anchor.x ? start.maxX - side : start.minX
                let y = anchor.y ? start.maxY - side : start.minY
                frame(zoom, to: CGRect(x: x, y: y, width: side, height: side),
                      name: "Frame Zoom")
            }
            .onEnded { _ in end() }
    }

    /// Dragging on bare picture frames an area from nothing, like drawing a blur.
    private var frameFromScratch: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let zoom else { return }
                _ = begin(zoom, name: "Frame Zoom")
                let a = geometry.blur(view: CGRect(origin: value.startLocation, size: .zero)).origin
                let b = geometry.blur(view: CGRect(origin: value.location, size: .zero)).origin
                // The longer side of what was swept, so a tall drag draws a box too.
                let side = max(0.05, max(abs(b.x - a.x), abs(b.y - a.y)))
                frame(zoom, to: CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                       width: side, height: side),
                      name: "Frame Zoom")
            }
            .onEnded { _ in end() }
    }

    /// Puts a drawn rectangle on screen and into the document in the same breath.
    ///
    /// The drawn one goes through `EditorModel.honouredZoomArea` first, which is the
    /// clamping `setZoomArea` will do anyway: the box can lead the render without ever
    /// showing a framing the renderer would refuse.
    private func frame(_ zoom: ZoomRegion, to rect: CGRect, name: String) {
        draft = EditorModel.honouredZoomArea(rect)
        model.setZoomArea(zoom.id, to: rect, name: name)
    }

    /// A drag's translation in view points, as a fraction of the recording.
    private func normalisedDelta(_ translation: CGSize) -> CGSize {
        let zero = geometry.blur(view: CGRect(origin: .zero, size: .zero)).origin
        let moved = geometry.blur(view: CGRect(origin: CGPoint(x: translation.width,
                                                               y: translation.height),
                                               size: .zero)).origin
        return CGSize(width: moved.x - zero.x, height: moved.y - zero.y)
    }

    private func begin(_ zoom: ZoomRegion, name: String) -> CGRect {
        if let origin { return origin }
        let rect = model.zoomArea(of: zoom)
        origin = rect
        isDragging = true
        // One undo entry for the whole drag, not one per pixel of it.
        model.document.beginInteraction(name)
        return rect
    }

    private func end() {
        guard isDragging else { return }
        origin = nil
        draft = nil
        isDragging = false
        model.finishInteraction()
    }

    /// What this tool is for, and — when it is — why the picture is not obeying it.
    @ViewBuilder
    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(zoom == nil
                 ? "Pick a zoom on the timeline to frame it"
                 : "Drag the box to move the shot, a corner to change how much is in it")
            if let zoom, zoom.followsCursor {
                Text("It follows the pointer at the moment — framing it will stop that.")
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(10)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(isDragging ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }
}
