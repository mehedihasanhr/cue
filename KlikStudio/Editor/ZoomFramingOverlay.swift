import AppKit
import SwiftUI
import TimelineKit

/// Framing a zoom by dragging a rectangle on the picture: where it looks, and how much it
/// takes in.
///
/// `ZoomRegion` has carried `center` and `scale` from the beginning, and two normalised
/// coordinates and a slider were the cheap way to set them and the wrong one. Nobody knows
/// where 0.38, 0.71 is, and nobody thinks "2.4×". What they know is *which part of the
/// screen they want in shot* — which is a rectangle, and is what this draws.
///
/// **One preview, two readings of it.** There used to be a second picture in the corner
/// rendering the same frame through the zoom being edited, and a tool mode to enter before
/// any of this appeared at all. Both are gone. Selecting a zoom on the timeline is already
/// an unambiguous statement about which zoom you mean, so the box appears on the main
/// preview the moment you make it; `EditorModel.ZoomPreview` switches that same surface
/// between the framing and the finished result. See `EditorModel.framedZoom`.
///
/// The picture under the box is the recording with **every zoom taken out** and everything
/// else — padding, corners, shadow, background — left exactly as it is, which is what lets
/// the rectangle be a rectangle *of the recording* without the switch looking like a
/// different video. A box drawn over an already-zoomed picture would always be the whole
/// picture: the tool would show you its own answer and refuse you the question.
///
/// The box has three verbs: the corners and edges change how much is in shot, the middle
/// moves what is in it, and the arrow keys do both a step at a time. A drag that lands off
/// the box does nothing at all, rather than throwing the framing away and starting a new
/// one, which is what it used to do and which cost the framing you had every time a move
/// slipped an inch wide.
///
/// Every edit goes through `EditorModel.setZoomArea`, which owns the arithmetic and the
/// clamping, so the box and the renderer cannot disagree about what was drawn.
struct ZoomFramingOverlay: View {
    let model: EditorModel
    /// Where the picture is, in this view's coordinates.
    let stage: CGRect

    /// The framing at the moment a drag began. Held so every change is measured against
    /// where the box started rather than against where the last event left it, which is
    /// what stops a slow drag accumulating rounding into a drift — and what stops the box
    /// jumping when the pointer first goes down.
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
    @State private var hovered: Handle?
    @State private var isInside = false

    private var geometry: CanvasGeometry {
        CanvasGeometry(stage: stage, scene: model.scene)
    }

    /// The zoom being framed. A delete or an undo can take it away while the box is up.
    private var zoom: ZoomRegion? { model.framedZoom }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Behind everything, and the only thing here that is focusable.
            //
            // The focus modifier used to be on this stack, wrapping the box and its
            // handles. A modifier that wraps the gestures is a modifier that can eat them,
            // and there is no way to tell by reading which one it will be — so it goes
            // where it can only ever catch a click on bare footage, which does nothing
            // else anyway.
            keyboard
            if let zoom {
                let area = draft ?? model.zoomArea(of: zoom)
                let rect = geometry.view(blur: area)
                shade(around: rect)
                box(rect, zoom: zoom)
            }
        }
        // Escape hands the picture back without dropping the selection, so the inspector is
        // still showing the zoom that was just framed.
        .onExitCommand { model.zoomPreview = .result }
    }

    /// Takes focus when the picture is clicked, so the arrow keys can nudge the framing
    /// without anyone having to find a number field. Draws nothing and does nothing else.
    private var keyboard: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                nudge(press) ? .handled : .ignored
            }
            .onKeyPress(characters: ["=", "+", "-", "_"]) { press in
                resizeByKey(press) ? .handled : .ignored
            }
    }

    // MARK: - Chrome

    /// Everything outside the box, dimmed — so the box reads as "this is what you will see"
    /// rather than as a rectangle lying on the picture.
    ///
    /// Lighter than a crop's shade on purpose. A crop throws the outside away; a zoom is a
    /// camera move, and the part of the recording being framed *out* is still the thing you
    /// are judging the framing against.
    private func shade(around rect: CGRect) -> some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(rect)
            context.fill(path, with: .color(.black.opacity(isDragging ? 0.4 : 0.28)),
                         style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
        .animation(StudioMotion.state, value: isDragging)
    }

    /// The move target, the outline, the number and the eight handles — in that order,
    /// because later children sit on top and that is the priority a drag should have: a
    /// handle near an edge, the body everywhere else.
    private func box(_ rect: CGRect, zoom: ZoomRegion) -> some View {
        ZStack(alignment: .topLeading) {
            // **Shaped, then placed.** `contentShape` describes the hit area of the view it
            // is applied to, in that view's own frame — so a `contentShape` written *after*
            // an `offset` describes a rectangle back where the view was laid out, not where
            // it was drawn. The box drew in the right place and was grabbable in another,
            // which is the whole of "dragging does nothing".
            //
            // `Color.clear` rather than the stroked rectangle for the same reason the camera
            // bubble uses one: a stroke is hit only along the stroke, and the thing being
            // dragged here is the area, not the line around it.
            Color.clear
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .offset(x: rect.minX, y: rect.minY)
                .gesture(move(from: zoom))
                .onHover { inside in
                    guard !model.isGesturing || isDragging else { return }
                    isInside = inside
                    if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }

            Rectangle()
                .strokeBorder(.white.opacity(isDragging || isInside ? 0.95 : 0.72), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)

            scaleChip(zoom, rect: rect)

            ForEach(Handle.allCases, id: \.self) { handle in
                grip(handle, of: rect, zoom: zoom)
            }
        }
    }

    /// The magnification the box stands for, on the box.
    ///
    /// Drawn inside the top-left corner when there is room and just outside it when there
    /// is not, so a zoom framed tight into a corner does not put its own number over the
    /// thing it is framing.
    private func scaleChip(_ zoom: ZoomRegion, rect: CGRect) -> some View {
        let inside = rect.width > 88 && rect.height > 52
        return HStack(spacing: 5) {
            Text("\(scaleShown(zoom), format: .number.precision(.fractionLength(0...1)))×")
            if zoom.followsCursor {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.85)
                    .accessibilityLabel("Follows the pointer")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.62), in: Capsule())
        .fixedSize()
        .offset(x: rect.minX + (inside ? 8 : 0), y: rect.minY + (inside ? 8 : -24))
        .allowsHitTesting(false)
    }

    /// The magnification the box is standing for — the draft's while a drag is running, so
    /// the number on the box and the box itself are never a frame out of step.
    private func scaleShown(_ zoom: ZoomRegion) -> Double {
        guard let draft, draft.width > 0 else { return zoom.scale }
        return 1 / draft.width
    }

    // MARK: - Handles

    /// The eight handles come from `ZoomFraming.Handle`, which is where the geometry lives
    /// and where it is tested. What belongs here is only how each one looks and reads.
    private typealias Handle = ZoomFraming.Handle

    /// An angle at the corner rather than a block on it.
    ///
    /// A square handle is a viewfinder's answer to nothing: it covers the picture at the one
    /// place the user is looking, and it says "grab me" without saying which way the corner
    /// goes. Two arms along the edges they belong to leave the corner itself clear and read
    /// as the corner of a frame.
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

    private let arm: CGFloat = 20
    private let thickness: CGFloat = 3

    /// One handle, placed by **offsetting its own frame** rather than by `.position`.
    ///
    /// That distinction is the whole of a bug worth remembering. `.position` does not place
    /// a small view — it returns a view that fills every point of space it is offered and
    /// draws its content at the given coordinate. The shared `contentShape` below then had
    /// a stage-sized frame to inset, so each edge handle's grab area was the entire picture.
    /// The last one in `allCases` is `.left`, drawn on top of everything, so every drag
    /// anywhere — on the box, on a corner, on bare footage — was a left-edge resize.
    ///
    /// `.offset` moves both the drawing and the hit testing while leaving the layout frame
    /// the size it was asked for, which is what a handle needs: a small frame, at a known
    /// place, that `contentShape` can widen by a fixed slop.
    @ViewBuilder
    private func grip(_ handle: Handle, of rect: CGRect, zoom: ZoomRegion) -> some View {
        let lit = hovered == handle || isDragging
        let along = handle.movesLeft || handle.movesRight
        let size: CGSize = handle.isCorner
            ? CGSize(width: arm, height: arm)
            : (along ? CGSize(width: thickness, height: 26) : CGSize(width: 26, height: thickness))
        // A corner's arms run *inward* from its vertex; an edge's bar straddles its middle.
        // `ZoomFraming.Handle` works that out, and is where the claim that no handle covers
        // the middle of the box is actually checked.
        let frame = handle.frame(in: rect, size: size)
        // Edge handles go away on a box too small to hold them and its corners both: eight
        // targets crowded into ninety points is four of them unhittable. Hidden means gone,
        // not merely invisible — an untouchable target that still takes the click is the
        // same bug as above wearing a different hat.
        let room = handle.isCorner || (along ? rect.height > 90 : rect.width > 90)

        Group {
            if handle.isCorner {
                // The stroke is inset by half its width so its outer edge lands on the
                // box's line instead of straddling it.
                CornerBracket(isTrailing: handle.movesRight, isBottom: handle.movesBottom)
                    .stroke(.white, style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
                    .padding(thickness / 2)
            } else {
                Capsule().fill(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .opacity(room ? (lit ? 1 : 0.88) : 0)
        // Bigger than it looks, because a 3pt line is not a target — and described before
        // the handle is moved into place, not after. See `box(_:zoom:)`.
        .contentShape(Rectangle().inset(by: -9))
        .offset(x: frame.minX, y: frame.minY)
        .allowsHitTesting(room)
        .gesture(resize(handle, from: zoom))
        .onHover { inside in
            guard !model.isGesturing || isDragging else { return }
            hovered = inside ? handle : (hovered == handle ? nil : hovered)
            if inside { cursor(for: handle).set() } else { NSCursor.arrow.set() }
        }
        .accessibilityLabel("\(label(for: handle)) framing handle")
    }

    /// How each handle reads to the pointer and to VoiceOver. The geometry is
    /// `ZoomFraming.Handle`'s; this is the half that only a view can answer.
    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }

    private func label(for handle: Handle) -> String {
        switch handle {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .right: "Right"
        case .bottomRight: "Bottom right"
        case .bottom: "Bottom"
        case .bottomLeft: "Bottom left"
        case .left: "Left"
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
                frame(zoom, to: start.offsetBy(dx: delta.width, dy: delta.height), name: "Move Zoom")
            }
            .onEnded { _ in end() }
    }

    /// Dragging a handle changes how much is in shot, holding the opposite edge still.
    ///
    /// A smaller box is a bigger zoom, which is the relationship a viewfinder has and the
    /// one `EditorModel.setZoomArea` reads: the scale is the reciprocal of the box's width.
    /// The box stays the picture's shape throughout — a zoom scales both axes by one
    /// number, so an output that was never stretched cannot be stretched from here.
    private func resize(_ handle: Handle, from zoom: ZoomRegion) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = begin(zoom, name: "Frame Zoom")
                let delta = normalisedDelta(value.translation)
                frame(zoom, to: ZoomFraming.resized(start, by: delta, handle: handle),
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

    /// A drag's travel in view points, as a fraction of the recording.
    private func normalisedDelta(_ translation: CGSize) -> CGSize {
        geometry.mapping.delta(view: translation)
    }

    private func begin(_ zoom: ZoomRegion, name: String) -> CGRect {
        if let origin { return origin }
        let rect = model.zoomArea(of: zoom)
        origin = rect
        isDragging = true
        // One undo entry for the whole drag, not one per pixel of it — and no decode per
        // frame either, since the picture under the box cannot change while it runs.
        model.isFramingDrag = true
        model.document.beginInteraction(name)
        return rect
    }

    private func end() {
        guard isDragging else { return }
        origin = nil
        draft = nil
        isDragging = false
        model.isFramingDrag = false
        model.finishInteraction()
    }

    // MARK: - Keyboard

    /// Arrow keys move the framing a step at a time; ⇧ makes the step ten times bigger.
    ///
    /// A step is a fraction of the *recording* rather than a number of points, so the same
    /// key moves the framing the same amount however big the window is — which is the point
    /// of having keys at all: a repeatable nudge that a drag cannot give you.
    private func nudge(_ press: KeyPress) -> Bool {
        guard let zoom else { return false }
        let step = press.modifiers.contains(.shift) ? 0.05 : 0.005
        let delta: CGSize = switch press.key {
        case .leftArrow: CGSize(width: -step, height: 0)
        case .rightArrow: CGSize(width: step, height: 0)
        case .upArrow: CGSize(width: 0, height: -step)
        default: CGSize(width: 0, height: step)
        }
        model.setZoomArea(zoom.id,
                          to: ZoomFraming.moved(model.zoomArea(of: zoom), by: delta),
                          name: "Move Zoom")
        return true
    }

    /// `+` and `-` change how much is in shot, about the middle of the current framing.
    private func resizeByKey(_ press: KeyPress) -> Bool {
        guard let zoom else { return false }
        let widening = press.characters == "-" || press.characters == "_"
        model.setZoomArea(zoom.id,
                          to: ZoomFraming.scaled(model.zoomArea(of: zoom), by: widening ? 1.1 : 1 / 1.1),
                          name: "Frame Zoom")
        return true
    }
}
