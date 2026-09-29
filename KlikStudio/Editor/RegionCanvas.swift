import AppKit
import BackgroundKit
import CoreMedia
import RenderKit
import SwiftUI
import TimelineKit

/// Drawing on the picture: blur rectangles and annotations.
///
/// Unlike crop, these work over the frame as it will be exported — padding, corners,
/// camera and all — because that is where the user is looking when they decide something
/// needs covering up or pointing at.
///
/// The two kinds live in different coordinate spaces and that is deliberate, not an
/// oversight: a blur is normalised to the *recording*, so it stays on the thing it
/// covers when the camera moves, while an annotation is normalised to the *finished
/// frame*, so a label stays where it was put. `CanvasGeometry` is the one place that
/// difference is spelled out; everything below works in view coordinates.
struct RegionCanvas: View {
    let model: EditorModel
    /// Where the picture is, in this view's coordinates.
    let stage: CGRect

    @State private var draft: CGRect?
    @State private var gestureOrigin: CGRect?
    /// The annotation being typed into, if any.
    @State private var editingID: UUID?
    @FocusState private var isTyping: Bool

    private var geometry: CanvasGeometry {
        CanvasGeometry(stage: stage, scene: model.scene)
    }

    private var isBlurring: Bool { model.tool == .blur }

    /// A space that does not move with the things being dragged in it.
    ///
    /// A box is offset by the rect it is editing and a corner handle is positioned by it,
    /// so a gesture measured in either one's local space is measured against an origin the
    /// gesture is moving — which oscillates.
    private static let space = "canvas"

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A transparent catcher under everything, so a drag that starts on empty
            // picture draws a new region rather than falling through to the pane.
            Color.clear
                .contentShape(Rectangle())
                .gesture(createDrag)

            ForEach(model.blursAtPlayhead) { blur in
                box(id: blur.id,
                    rect: geometry.view(blur: blur.rect),
                    kind: .blur,
                    isSelected: model.selection == .blur(blur.id))
            }
            ForEach(model.annotationsAtPlayhead) { item in
                box(id: item.id,
                    rect: geometry.view(annotation: item.rect),
                    kind: .annotation(item),
                    isSelected: model.selection == .annotation(item.id))
            }

            if let draft {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .background(Color.accentColor.opacity(0.12))
                    .frame(width: draft.width, height: draft.height)
                    .offset(x: draft.minX, y: draft.minY)
                    .allowsHitTesting(false)
            }

            hint
        }
        .coordinateSpace(.named(Self.space))
        .onExitCommand { model.tool = .frame }
    }

    /// What to do, for as long as there is nothing to look at yet.
    @ViewBuilder
    private var hint: some View {
        if model.blursAtPlayhead.isEmpty, model.annotationsAtPlayhead.isEmpty, draft == nil {
            Text(isBlurring ? "Drag over anything to hide it" : "Drag to place a label")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .position(x: stage.midX, y: stage.maxY - 26)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - An existing region

    private enum Kind {
        case blur
        case annotation(AnnotationItem)
    }

    private func box(id: UUID, rect: CGRect, kind: Kind, isSelected: Bool) -> some View {
        let rotation = Self.rotation(of: kind)
        let isLocked = Self.isLocked(kind)
        return ZStack(alignment: .topLeading) {
            outline(kind: kind, isSelected: isSelected)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                // Turned about its own centre, as the renderer turns it — so the outline sits
                // on the drawing, and a click on the drawing lands on the outline.
                .rotationEffect(.degrees(rotation))
                .offset(x: rect.minX, y: rect.minY)
                // Double-click to type has to come first: registered after the single
                // tap, SwiftUI hands the first click to selection and the second never
                // arrives as a pair.
                .onTapGesture(count: 2) { if case .annotation = kind { beginEditing(id) } }
                .onTapGesture {
                    // A label that is already selected opens for typing on a single click,
                    // the way a name does in Finder. Double-click still works from cold,
                    // and neither is the only way in: the inspector has the same field.
                    if case .annotation(let item) = kind, case .text = item.kind, isSelected {
                        beginEditing(id)
                    } else {
                        select(id: id, kind: kind)
                    }
                }
                .onHover { inside in
                    // Says it can be picked up — unless it is locked, where saying so would
                    // be a promise the drag then breaks.
                    guard !isLocked else { return }
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(moveDrag(id: id, kind: kind))
                .contextMenu { menu(id: id, kind: kind) }

            if case .annotation(let item) = kind, editingID == id {
                editor(for: item, in: rect)
            }

            if isSelected {
                if isLocked {
                    lockBadge(on: rect, rotation: rotation)
                } else {
                    ForEach(Self.handles(for: kind)) { handle in
                        self.handle(handle, of: rect, rotation: rotation, id: id, kind: kind)
                    }
                    if case .annotation = kind {
                        rotationHandle(of: rect, rotation: rotation, id: id)
                    }
                }
            }
        }
    }

    /// The handles a kind offers. A blur is a rectangle of the recording, and turning or
    /// pulling one side of it has never been asked for; an annotation gets all eight sides
    /// and corners.
    private static func handles(for kind: Kind) -> [AnnotationGeometry.Handle] {
        switch kind {
        case .blur: AnnotationGeometry.Handle.allCases.filter(\.isCorner)
        case .annotation: AnnotationGeometry.Handle.allCases
        }
    }

    private static func rotation(of kind: Kind) -> Double {
        if case .annotation(let item) = kind { item.rotation } else { 0 }
    }

    private static func isLocked(_ kind: Kind) -> Bool {
        if case .annotation(let item) = kind { item.isLocked } else { false }
    }

    /// Where a locked annotation's handles would be: one padlock, so the absence of handles
    /// reads as a decision and not as a selection that failed.
    private func lockBadge(on rect: CGRect, rotation: Double) -> some View {
        let corner = AnnotationGeometry.point(of: .topLeft, in: rect, rotation: rotation)
        return Image(systemName: "lock.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color.accentColor, in: Circle())
            .shadow(color: .black.opacity(0.4), radius: 2)
            .position(corner)
            .allowsHitTesting(false)
            .accessibilityLabel("Locked")
    }

    /// Right-click on the picture: the same verbs as on the timeline chip, plus the ones
    /// that only make sense on the picture.
    @ViewBuilder
    private func menu(id: UUID, kind: Kind) -> some View {
        switch kind {
        case .blur:
            Button("Duplicate") { model.duplicateRegion(.blur(id)) }
            Button("Copy") { model.copyRegion(.blur(id)) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteSelection(id) }
        case .annotation(let item):
            AnnotationMenu(model: model, item: item) { beginEditing(id) }
        }
    }

    @ViewBuilder
    private func outline(kind: Kind, isSelected: Bool) -> some View {
        switch kind {
        case .blur:
            // Hatched rather than filled: the picture underneath is already blurred by
            // the renderer, and covering it again would hide the very thing being judged.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.7),
                              style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [5, 4]))
        case .annotation(let item):
            // A hidden annotation draws nothing, so its outline is all there is of it on the
            // picture: dashed, and fainter, so it can still be found and switched back on.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(item.isHidden ? 0.5 : 0.35),
                              style: StrokeStyle(lineWidth: isSelected ? 2 : 1,
                                                 dash: item.isHidden ? [4, 4] : []))
                .overlay(alignment: .topLeading) {
                    if case .text(let string) = item.kind, string.isEmpty, editingID != item.id {
                        Text("Click to type")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(4)
                    }
                }
        }
    }

    /// Typing straight onto the picture.
    ///
    /// The alternative — draw a box, then go and find the inspector to say what it says —
    /// is how a label ends up empty in an export. A new text annotation opens this
    /// immediately, so drawing one and typing into it is a single motion.
    private func editor(for item: AnnotationItem, in rect: CGRect) -> some View {
        TextField("Type your label", text: text(of: item.id), axis: .vertical)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            // The renderer's font, exactly: `NSFont.systemFont(ofSize: outputHeight *
            // fontSize, weight: .semibold)`. The stage *is* the finished frame on screen, so
            // its height stands in for the output's. This used to be half the box's height,
            // which is a different number entirely — which is why what you typed was never
            // the size of what appeared.
            .font(.system(size: max(9, stage.height * item.fontSize), weight: .semibold))
            .foregroundStyle(Color(item.color.rgba.nsColor))
            // No plate behind it. The point of typing on the picture is seeing what the
            // label will look like on the picture, and a dark rectangle under it is the one
            // thing guaranteed not to be in the export. What says "you are typing" is the
            // caret and the box's own accent outline.
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .rotationEffect(.degrees(item.rotation))
            .offset(x: rect.minX, y: rect.minY)
            .focused($isTyping)
            .onSubmit { endEditing() }
            .onExitCommand { endEditing() }
            .onAppear {
                isTyping = true
                model.editingAnnotation = item.id
            }
            .onDisappear { model.editingAnnotation = nil }
            .accessibilityLabel("Annotation text")
    }

    private func text(of id: UUID) -> Binding<String> {
        Binding {
            guard let item = model.timeline.annotations.first(where: { $0.id == id }),
                  case .text(let string) = item.kind else { return "" }
            return string
        } set: { string in
            model.restyleAnnotation(id, "Annotation Text") { $0.kind = .text(string) }
        }
    }

    private func beginEditing(_ id: UUID) {
        model.select(.annotation(id))
        editingID = id
        model.editingAnnotation = id
    }

    /// Leaves typing, and takes an empty label away with it.
    ///
    /// A blank text annotation draws nothing at all, so leaving one behind would be an
    /// invisible object on the timeline that the user cannot see to delete.
    private func endEditing() {
        defer {
            editingID = nil
            isTyping = false
            model.editingAnnotation = nil
        }
        guard let editingID,
              let item = model.timeline.annotations.first(where: { $0.id == editingID }),
              case .text(let string) = item.kind,
              string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.deleteSelection(editingID)
    }

    private func select(id: UUID, kind: Kind) {
        switch kind {
        case .blur: model.select(.blur(id))
        case .annotation: model.select(.annotation(id))
        }
    }

    // MARK: - Handles

    private func handle(_ handle: AnnotationGeometry.Handle, of rect: CGRect, rotation: Double,
                        id: UUID, kind: Kind) -> some View {
        let point = AnnotationGeometry.point(of: handle, in: rect, rotation: rotation)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: handle.isCorner ? 10 : 8, height: handle.isCorner ? 10 : 8)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .rotationEffect(.degrees(rotation))
            // Slop around the drawn handle, for the same reason the crop handles have it:
            // ten points of white is a hairline to aim at.
            .contentShape(Rectangle().inset(by: -8))
            .position(point)
            .onHover { inside in
                if inside { Self.cursor(for: handle, rotation: rotation).push() } else { NSCursor.pop() }
            }
            .gesture(resizeDrag(handle, id: id, kind: kind))
            .help(handle.isCorner ? "Drag to resize · ⇧ keeps the shape" : "Drag to resize")
    }

    /// The pointer a handle shows: the resize arrows that match the way it pulls, once it is
    /// turned — a side handle on a box stood on end pulls up and down, not left and right.
    private static func cursor(for handle: AnnotationGeometry.Handle, rotation: Double) -> NSCursor {
        guard !handle.isCorner else { return .crosshair }
        let across = handle.direction.x != 0
        let turned = abs(AnnotationGeometry.normalisedDegrees(rotation))
        let quarterTurned = turned > 45 && turned < 135
        return across != quarterTurned ? .resizeLeftRight : .resizeUpDown
    }

    /// The round handle above the box that turns it.
    private func rotationHandle(of rect: CGRect, rotation: Double, id: UUID) -> some View {
        let reach: CGFloat = 22
        let point = AnnotationGeometry.rotationHandle(of: rect, rotation: rotation, reach: reach)
        let top = AnnotationGeometry.point(of: .top, in: rect, rotation: rotation)
        return ZStack {
            // The stalk, from the top edge to the knob, so the knob reads as part of the box.
            Path { path in
                path.move(to: top)
                path.addLine(to: point)
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
            .allowsHitTesting(false)

            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .contentShape(Circle().inset(by: -8))
                .position(point)
                .onHover { inside in
                    if inside { NSCursor.closedHand.push() } else { NSCursor.pop() }
                }
                .gesture(rotateDrag(id: id))
                .help("Drag to turn · ⇧ snaps to 15°")
        }
    }

    // MARK: - Gestures

    /// Dragging on empty picture makes a new region.
    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                draft = CGRect(x: min(value.startLocation.x, value.location.x),
                               y: min(value.startLocation.y, value.location.y),
                               width: abs(value.location.x - value.startLocation.x),
                               height: abs(value.location.y - value.startLocation.y))
                    .intersection(stage)
            }
            .onEnded { _ in
                defer { draft = nil }
                guard let drawn = draft, drawn.width > 6, drawn.height > 6 else { return }
                if isBlurring {
                    model.addBlur(rect: geometry.blur(view: drawn))
                } else {
                    // Straight into typing: a label drawn and then abandoned because the
                    // caret was somewhere else is an empty box in the export.
                    beginEditing(model.addAnnotation(.text(""), rect: geometry.annotation(view: drawn)))
                }
            }
    }

    private func moveDrag(id: UUID, kind: Kind) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = begin(id: id, kind: kind)
                var moved = start
                moved.origin.x += value.translation.width
                moved.origin.y += value.translation.height
                store(moved, id: id, kind: kind)
            }
            .onEnded { _ in end() }
    }

    private func resizeDrag(_ handle: AnnotationGeometry.Handle, id: UUID, kind: Kind) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = begin(id: id, kind: kind, name: "Resize")
                // In view points, which are square — so the turned box is resized along its
                // own sides. See `AnnotationGeometry`.
                let rect = AnnotationGeometry.resize(start,
                                                     rotation: Self.rotation(of: kind),
                                                     dragging: handle,
                                                     to: value.location,
                                                     minimumSide: 8,
                                                     keepingAspect: NSEvent.modifierFlags.contains(.shift))
                store(rect, id: id, kind: kind)
            }
            .onEnded { _ in end() }
    }

    /// Turning an annotation, as one undo step however far it goes round.
    private func rotateDrag(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = begin(id: id, kind: .annotation(model.annotation(id) ?? placeholder), name: "Rotate")
                let degrees = AnnotationGeometry.rotation(of: start, toward: value.location,
                                                          snapping: NSEvent.modifierFlags.contains(.shift))
                model.restyleAnnotation(id, "Rotate") { $0.rotation = degrees }
            }
            .onEnded { _ in end() }
    }

    /// Stands in for an annotation that vanished mid-gesture — deleted by an undo, say — so
    /// the gesture can finish harmlessly rather than needing an optional at every step.
    private var placeholder: AnnotationItem {
        AnnotationItem(start: .zero, duration: .zero, kind: .rectangle, rect: .zero)
    }

    /// Opens one undo entry for a whole gesture, however many commands it applies.
    private func begin(id: UUID, kind: Kind, name: String = "Move") -> CGRect {
        if let gestureOrigin { return gestureOrigin }
        let rect: CGRect = switch kind {
        case .blur:
            geometry.view(blur: model.timeline.blurs.first { $0.id == id }?.rect ?? .zero)
        case .annotation:
            geometry.view(annotation: model.timeline.annotations.first { $0.id == id }?.rect ?? .zero)
        }
        gestureOrigin = rect
        select(id: id, kind: kind)
        model.document.beginInteraction(name)
        return rect
    }

    private func store(_ rect: CGRect, id: UUID, kind: Kind) {
        switch kind {
        case .blur: model.setRegionRect(id, rect: geometry.blur(view: rect))
        case .annotation: model.setRegionRect(id, rect: geometry.annotation(view: rect))
        }
    }

    private func end() {
        gestureOrigin = nil
        model.finishInteraction()
    }
}

/// The mapping between the picture on screen and the two normalised spaces a region can
/// be stored in.
///
/// Split out of the view because it is the only part with real arithmetic in it, and
/// because "which space is this rectangle in?" should be answered in one file rather than
/// at every call site.
struct CanvasGeometry {
    /// Where the picture is, in view coordinates.
    let stage: CGRect
    /// What the renderer drew, for the video's place inside the output.
    let scene: SceneDescriptor?

    // MARK: - Annotations: normalised to the finished frame

    /// The pure mapping underneath, which lives in TimelineKit so it can be tested without
    /// a window. This type is what knows where the recording ended up; that one is the
    /// arithmetic for going back and forth, and both directions of both conversions come
    /// from it rather than being written out twice here.
    var mapping: PictureMapping { PictureMapping(stage: stage, video: videoInOutput) }

    func view(annotation rect: CGRect) -> CGRect { mapping.view(frame: rect) }

    func annotation(view rect: CGRect) -> CGRect { mapping.frame(view: rect) }

    // MARK: - Blurs: normalised to the recording

    /// Where the recording sits inside the finished frame *as the camera has left it*,
    /// normalised, top-left origin.
    ///
    /// The zoomed rectangle, because a blur is on the footage: it has to travel and grow
    /// with the picture it is covering, or it slides off the thing it was put over.
    private var videoInOutput: CGRect { normalised(scene?.transformedVideoFrame) }

    func view(blur rect: CGRect) -> CGRect { mapping.view(recording: rect) }

    func blur(view rect: CGRect) -> CGRect { mapping.recording(view: rect) }

    // MARK: - A zoom's framing: normalised to the recording, before the camera

    /// Where the recording sits before the camera moves.
    ///
    /// A framing box says which part of the *recording* to point at, so it is drawn against
    /// the picture as the padding left it — not against the picture the camera has already
    /// moved. It has been right so far only because framing renders the timeline with its
    /// zooms taken out; said here, it is right because it asks the right question.
    private var recordingInOutput: CGRect { normalised(scene?.videoFrame) }

    var recordingMapping: PictureMapping { PictureMapping(stage: stage, video: recordingInOutput) }

    func view(framing rect: CGRect) -> CGRect { recordingMapping.view(recording: rect) }

    func framing(view rect: CGRect) -> CGRect { recordingMapping.recording(view: rect) }

    /// A rectangle of the output, in output pixels with Core Image's bottom-left origin,
    /// normalised to the output with SwiftUI's top-left one.
    ///
    /// When there is no scene yet the whole stage stands in, so an overlay that draws a frame
    /// early puts its handles somewhere sane rather than at zero.
    private func normalised(_ rect: CGRect?) -> CGRect {
        guard let rect, let scene, scene.outputSize.width > 0, scene.outputSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: rect.minX / scene.outputSize.width,
                      y: 1 - rect.maxY / scene.outputSize.height,
                      width: rect.width / scene.outputSize.width,
                      height: rect.height / scene.outputSize.height)
    }
}
