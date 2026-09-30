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
    /// A label's type size when a resize began, for scaling it from a corner.
    @State private var fontOrigin: Double?
    /// The lines a box being dragged has lined up with, while it is being dragged.
    @State private var guides: [CanvasSnapping.Guide] = []
    /// The end of a line that stays put while the other is dragged, on the picture.
    @State private var heldEnd: CGPoint?
    /// Whether a callout's tail is being dragged, so the drag is one undo step.
    @State private var isPointing = false
    /// The annotation being typed into, if any.
    @State private var editingID: UUID?
    @FocusState private var isTyping: Bool

    private var geometry: CanvasGeometry {
        CanvasGeometry(stage: stage, scene: model.scene)
    }

    /// The picture's perspective, in canvas points. Every rectangle below is worked out on
    /// the flat picture, as it always was; this moves what is drawn onto the turned one and
    /// brings every drag back off it. See `CanvasTilt`.
    private var tilt: CanvasTilt {
        CanvasTilt(stage: stage, scene: model.scene)
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
                // Where the mask is now: a following one moves. See `BlurRegion.rect(at:)`.
                let rect = geometry.view(blur: blur.rect(at: model.playhead))
                box(id: blur.id,
                    rect: rect,
                    kind: .blur,
                    isSelected: model.selection == .blur(blur.id))
                if blur.follows {
                    MaskFollowBadge(isLost: model.hasLostContent(blur, at: model.playhead))
                        .position(tilt.drawn(CGPoint(x: rect.minX + 12, y: rect.minY - 11)))
                }
            }
            ForEach(model.annotationsAtPlayhead) { item in
                box(id: item.id,
                    rect: geometry.view(annotation: item.rect),
                    kind: .annotation(item),
                    isSelected: model.selection == .annotation(item.id))
            }

            // Lined up on the flat picture, and drawn on the turned one: a straight line stays
            // straight through a perspective, so its two ends are all it takes.
            ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                let ends = Self.ends(of: guide)
                tilt.line(from: ends.start, to: ends.end)
                    .stroke(Self.guideColour, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            if let draft {
                if tilt.isTilted {
                    let outline = tilt.outline(of: draft)
                    outline.fill(Color.accentColor.opacity(0.12))
                        .overlay(outline.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                        .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(Color.accentColor.opacity(0.12))
                        .frame(width: draft.width, height: draft.height)
                        .offset(x: draft.minX, y: draft.minY)
                        .allowsHitTesting(false)
                }
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
            Text(isBlurring ? "Drag over anything to \(model.newMaskStyle == .spotlight ? "spotlight" : "hide") it"
                            : "Drag to place a label")
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
            placedOutline(kind: kind, isSelected: isSelected, rect: rect, rotation: rotation)
                // Double-click to type has to come first: registered after the single
                // tap, SwiftUI hands the first click to selection and the second never
                // arrives as a pair.
                //
                // Only something with words opens for typing. A double-click on a box used to
                // open an invisible text field over it and take the box out of the picture
                // while it was open — and typing into it turned the box into a label.
                .onTapGesture(count: 2) {
                    if case .annotation(let item) = kind, item.kind.hasWords { beginEditing(id) }
                }
                .onTapGesture {
                    // A label that is already selected opens for typing on a single click,
                    // the way a name does in Finder. Double-click still works from cold,
                    // and neither is the only way in: the inspector has the same field.
                    if case .annotation(let item) = kind, item.kind.hasWords, isSelected {
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

            if case .annotation(let item) = kind, editingID == id, item.kind.hasWords {
                editor(for: item, in: rect)
            }

            if isSelected {
                if isLocked {
                    lockBadge(on: rect, rotation: rotation)
                } else {
                    ForEach(Self.handles(for: kind).filter { Self.fits($0, on: rect) }) { handle in
                        self.handle(handle, of: rect, rotation: rotation, id: id, kind: kind)
                    }
                    if case .annotation(let item) = kind {
                        // A line is aimed by its ends, which say which way it points; a
                        // turn handle on top of that would be a second way to do the same.
                        if item.kind.ends != nil {
                            endHandle(.from, of: item, in: rect)
                            endHandle(.to, of: item, in: rect)
                        } else {
                            rotationHandle(of: rect, rotation: rotation, id: id)
                        }
                        if case .callout(_, let tail) = item.kind {
                            tailHandle(tail, of: item, in: rect)
                        }
                    }
                }
            }
        }
    }

    /// The handles a kind offers. A blur is a rectangle of the recording, and turning or
    /// pulling one side of it has never been asked for; an annotation gets all eight sides
    /// and corners.
    ///
    /// An arrow and a line are pulled by their two ends instead, and a step by its corners
    /// only, since it is round whatever box it is given.
    private static func handles(for kind: Kind) -> [AnnotationGeometry.Handle] {
        switch kind {
        case .blur: AnnotationGeometry.Handle.allCases.filter(\.isCorner)
        case .annotation(let item):
            switch item.kind.name {
            case .arrow, .line: []
            case .step: AnnotationGeometry.Handle.allCases.filter(\.isCorner)
            // A label's height is its lines, so nothing pulls its top or bottom: the sides
            // set where it wraps and the corners scale its type. See `AnnotationFit`.
            case .text: AnnotationGeometry.Handle.allCases.filter { $0.isCorner || $0.direction.y == 0 }
            default: AnnotationGeometry.Handle.allCases
            }
        }
    }

    /// Guides in the colour layout tools use for them, which no picture is likely to be.
    private static let guideColour = Color(red: 1, green: 0.22, blue: 0.62)

    /// A guide's two ends, on the flat picture.
    private static func ends(of guide: CanvasSnapping.Guide) -> (start: CGPoint, end: CGPoint) {
        switch guide.axis {
        case .vertical:
            (CGPoint(x: guide.position, y: guide.from), CGPoint(x: guide.position, y: guide.to))
        case .horizontal:
            (CGPoint(x: guide.from, y: guide.position), CGPoint(x: guide.to, y: guide.position))
        }
    }

    /// Where the frame is on the canvas, for lining a box up with its edges and middle.
    private func snapStage(for kind: Kind) -> CGRect {
        switch kind {
        case .annotation: geometry.view(annotation: CGRect(x: 0, y: 0, width: 1, height: 1))
        case .blur: geometry.view(blur: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// Every other box showing now, in canvas points.
    private func otherBoxes(than id: UUID) -> [CGRect] {
        model.annotationsAtPlayhead.filter { $0.id != id }.map { geometry.view(annotation: $0.rect) }
            + model.blursAtPlayhead.filter { $0.id != id }.map { geometry.view(blur: $0.rect(at: model.playhead)) }
    }

    /// Whether a side's pill has room on a box this size. Corners always do.
    private static func fits(_ handle: AnnotationGeometry.Handle, on rect: CGRect) -> Bool {
        guard !handle.isCorner else { return true }
        let side = handle.direction.x != 0 ? rect.height : rect.width
        return side >= CanvasGrip.shortestSideWithPill
    }

    private static func isLabel(_ kind: Kind) -> Bool {
        if case .annotation(let item) = kind { AnnotationFit.isLabel(item) } else { false }
    }

    /// A step stays square on screen, so the circle fills the box it is resized to.
    private static func keepsShape(_ kind: Kind) -> Bool {
        if case .annotation(let item) = kind, item.kind.name == .step { true } else { false }
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
            .position(tilt.drawn(corner))
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
            MaskFollowMenu(model: model, id: id)
            Divider()
            Button("Delete", role: .destructive) { model.deleteSelection(id) }
        case .annotation(let item):
            AnnotationMenu(model: model, item: item) { beginEditing(id) }
        }
    }

    /// A box's outline where the picture has it, and the area a click on it lands in.
    ///
    /// Flat, a rectangle turned about its own centre, as the renderer turns an annotation —
    /// so the outline sits on the drawing, and a click on the drawing lands on the outline.
    /// On a picture the Perspective look has turned, the same rectangle's corners carried
    /// through the turn: a quadrilateral, drawn as lines, and the quadrilateral is what
    /// takes the click.
    @ViewBuilder
    private func placedOutline(kind: Kind, isSelected: Bool, rect: CGRect, rotation: Double) -> some View {
        if tilt.isTilted {
            let shape = tilt.outline(of: rect, rotation: rotation)
            tiltedOutline(kind: kind, isSelected: isSelected, shape: shape, rect: rect)
                .contentShape(shape)
        } else {
            outline(kind: kind, isSelected: isSelected)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .rotationEffect(.degrees(rotation))
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    /// `outline(kind:isSelected:)` on a turned picture: the same lines, in the same colours,
    /// along the four sides of `shape` rather than round a rounded rectangle.
    @ViewBuilder
    private func tiltedOutline(kind: Kind, isSelected: Bool, shape: Path, rect: CGRect) -> some View {
        switch kind {
        case .blur:
            shape.stroke(isSelected ? Color.accentColor : .white.opacity(0.7),
                         style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [5, 4]))
        case .annotation(let item):
            let dash: [CGFloat] = item.isHidden ? [4, 4] : []
            ZStack(alignment: .topLeading) {
                if isSelected {
                    ZStack {
                        shape.stroke(Color.white.opacity(0.55), lineWidth: 2.5)
                        shape.stroke(Color.accentColor,
                                     style: StrokeStyle(lineWidth: 1.25, dash: item.isHidden ? [4, 3] : []))
                    }
                    .opacity(item.kind.ends != nil ? 0.35 : 1)
                } else {
                    shape.stroke(Color.black.opacity(item.isHidden ? 0.35 : 0.2), style: StrokeStyle(lineWidth: 2.5, dash: dash))
                    shape.stroke(Color.white.opacity(item.isHidden ? 0.5 : 0.35), style: StrokeStyle(lineWidth: 1, dash: dash))
                }
                if case .text(let string) = item.kind, string.isEmpty, editingID != item.id {
                    Self.clickToType
                        .fixedSize()
                        .position(tilt.drawn(CGPoint(x: rect.midX, y: rect.minY + min(14, rect.height / 2))))
                }
            }
        }
    }

    /// The hint in an empty label, on a plate of its own: white words on a white page were
    /// the one hint nobody could read.
    private static var clickToType: some View {
        Text("Click to type")
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
    }

    @ViewBuilder
    private func outline(kind: Kind, isSelected: Bool) -> some View {
        switch kind {
        case .blur:
            // Hatched rather than filled: the picture underneath is already blurred by
            // the renderer, and covering it again would hide the very thing being judged.
            // The same outline for all four kinds — a spotlight's rectangle is the clear
            // area, and the renderer has already made the rest of the picture say so.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.7),
                              style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [5, 4]))
        case .annotation(let item):
            // A hidden annotation draws nothing, so its outline is all there is of it on the
            // picture: dashed, and fainter, so it can still be found and switched back on.
            //
            // A dark line inside the light one, so the outline can be found on a white
            // page as well as a dark one: white alone vanished on every light recording,
            // and with it any hidden annotation over one.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(isSelected ? Color.clear : .white.opacity(item.isHidden ? 0.5 : 0.35),
                              style: StrokeStyle(lineWidth: 1, dash: item.isHidden ? [4, 4] : []))
                .overlay {
                    // A line is shown by its ends; a box round it would be a second, wrong
                    // outline of the same thing, so it is only a whisper.
                    if isSelected {
                        SelectionOutline(dashed: item.isHidden)
                            .opacity(item.kind.ends != nil ? 0.35 : 1)
                    }
                }
                .background {
                    if !isSelected {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Color.black.opacity(item.isHidden ? 0.35 : 0.2),
                                          style: StrokeStyle(lineWidth: 1, dash: item.isHidden ? [4, 4] : []))
                            .padding(1)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if case .text(let string) = item.kind, string.isEmpty, editingID != item.id {
                        // On a plate of its own: white words on a white page were the
                        // one hint nobody could read.
                        Text("Click to type")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.45), in: Capsule())
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
        let size = max(9, stage.height * item.fontSize)
        let isCallout = item.kind.name == .callout
        let plate = item.style.plate(for: item.color)
        // Where the renderer puts the words: a callout's in the middle of its bubble, a
        // plated label's in from the plate's edge. See `AnnotationArtwork`.
        let inset: (x: CGFloat, y: CGFloat) = isCallout ? (size * 0.5, size * 0.3)
            : plate != nil ? (size * 0.35, size * 0.2) : (0, 0)
        return TextField("Type your label", text: text(of: item.id), axis: .vertical)
            .textFieldStyle(.plain)
            .multilineTextAlignment(Self.alignment(item.style.alignment))
            // The renderer's font, exactly: `NSFont.systemFont(ofSize: outputHeight *
            // fontSize, weight:)`. The stage *is* the finished frame on screen, so its
            // height stands in for the output's. This used to be half the box's height,
            // which is a different number entirely — which is why what you typed was never
            // the size of what appeared.
            .font(.system(size: size, weight: Self.weight(item.style.weight)))
            .foregroundStyle(Color(item.style.textColour(for: item.color).rgba.nsColor))
            .padding(.horizontal, inset.x)
            .padding(.vertical, inset.y)
            // No plate behind it unless the annotation has one. The point of typing on the
            // picture is seeing what the label will look like on the picture, and a dark
            // rectangle under it is the one thing guaranteed not to be in the export. What
            // says "you are typing" is the caret and the box's own accent outline. The one
            // being typed into is left out of the render while it is, so a callout's bubble
            // or a label's plate is drawn here instead — without it, white words would be
            // typed onto a white page.
            .frame(width: rect.width, height: rect.height,
                   alignment: isCallout ? .center : Self.frameAlignment(item.style.alignment))
            .background {
                let shape = RoundedRectangle(cornerRadius: min(size * 0.5, rect.height / 2), style: .continuous)
                if let plate {
                    shape.fill(Color(plate.rgba.nsColor))
                } else if isCallout {
                    shape.strokeBorder(Color(item.color.rgba.nsColor), lineWidth: 2)
                }
            }
            .rotationEffect(.degrees(item.rotation))
            .offset(x: rect.minX, y: rect.minY)
            // Laid out on the flat picture like everything else here, and then *drawn* turned
            // with it, so the words being typed sit on the plate the export will draw them on.
            // Nothing at all when the picture is square-on.
            .projectionEffect(tilt.projection)
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
            model.timeline.annotations.first(where: { $0.id == id })?.kind.text ?? ""
        } set: { string in
            model.setText(ofAnnotation: id, to: string)
        }
    }

    private static func alignment(_ alignment: AnnotationStyle.Alignment) -> TextAlignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private static func frameAlignment(_ alignment: AnnotationStyle.Alignment) -> Alignment {
        switch alignment {
        case .left: .topLeading
        case .center: .top
        case .right: .topTrailing
        }
    }

    private static func weight(_ weight: AnnotationStyle.Weight) -> Font.Weight {
        switch weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
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
        let label = Self.isLabel(kind)
        return CanvasGrip(shape: handle.isCorner ? .corner : .side(vertical: handle.direction.x != 0),
                          cursor: Self.cursor(for: handle, rotation: rotation))
            .rotationEffect(.degrees(rotation))
            // At the corner as the picture is turned; the drag is brought back off it.
            .position(tilt.drawn(point))
            .gesture(resizeDrag(handle, id: id, kind: kind))
            .help(label ? (handle.isCorner ? "Drag to scale the text" : "Drag to set where the text wraps")
                        : (handle.isCorner ? "Drag to resize · ⇧ keeps the shape" : "Drag to resize"))
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
            tilt.line(from: top, to: point)
                .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)

            RotationKnob()
                .position(tilt.drawn(point))
                .gesture(rotateDrag(id: id))
                .help("Drag to turn · ⇧ snaps to 15°")
        }
    }

    // MARK: - Gestures

    /// Dragging on empty picture makes a new region.
    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                // Both ends taken back to the flat picture, where the box is stored: dragged
                // across a turned picture, what is drawn is the box's turned outline.
                guard let start = tilt.flat(value.startLocation), let end = tilt.flat(value.location) else { return }
                draft = CGRect(x: min(start.x, end.x),
                               y: min(start.y, end.y),
                               width: abs(end.x - start.x),
                               height: abs(end.y - start.y))
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
                // Measured on the flat picture: on a turned one the same distance on screen
                // is further on the far side than on the near one. See `CanvasTilt`.
                guard let travel = tilt.flatTranslation(from: value.startLocation, to: value.location) else { return }
                var moved = start
                moved.origin.x += travel.width
                moved.origin.y += travel.height
                // Lined up with the frame and the other boxes on screen, unless ⌘ is held
                // for a free move. See `CanvasSnapping`.
                if NSEvent.modifierFlags.contains(.command) {
                    guides = []
                } else {
                    let snapped = CanvasSnapping.snap(moved, to: otherBoxes(than: id), stage: snapStage(for: kind))
                    moved = snapped.rect
                    guides = snapped.guides
                }
                store(moved, id: id, kind: kind)
            }
            .onEnded { _ in
                guides = []
                end()
            }
    }

    private func resizeDrag(_ handle: AnnotationGeometry.Handle, id: UUID, kind: Kind) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let location = tilt.flat(value.location) else { return }
                let start = begin(id: id, kind: kind, name: "Resize")
                // In view points, which are square — so the turned box is resized along its
                // own sides. See `AnnotationGeometry`.
                let label = Self.isLabel(kind)
                let rect = AnnotationGeometry.resize(start,
                                                     rotation: Self.rotation(of: kind),
                                                     dragging: handle,
                                                     to: location,
                                                     minimumSide: 8,
                                                     keepingAspect: NSEvent.modifierFlags.contains(.shift)
                                                         || Self.keepsShape(kind)
                                                         || (label && handle.isCorner))
                if label, case .annotation(let item) = kind {
                    let font = fontOrigin ?? model.annotation(id)?.fontSize ?? item.fontSize
                    fontOrigin = font
                    let scale = handle.isCorner && start.height > 0 ? rect.height / start.height : 1
                    model.resizeLabel(id, rect: geometry.annotation(view: rect), fontSize: font * scale)
                } else {
                    store(rect, id: id, kind: kind)
                }
            }
            .onEnded { _ in end() }
    }

    /// Turning an annotation, as one undo step however far it goes round.
    private func rotateDrag(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let location = tilt.flat(value.location) else { return }
                let start = begin(id: id, kind: .annotation(model.annotation(id) ?? placeholder), name: "Rotate")
                let degrees = AnnotationGeometry.rotation(of: start, toward: location,
                                                          snapping: NSEvent.modifierFlags.contains(.shift))
                model.restyleAnnotation(id, "Rotate") { $0.rotation = degrees }
            }
            .onEnded { _ in end() }
    }

    // MARK: - Ends and tails

    private enum End { case from, to }

    /// One end of an arrow or a line: a round knob, since it is a point rather than a side.
    @ViewBuilder
    private func endHandle(_ end: End, of item: AnnotationItem, in rect: CGRect) -> some View {
        if let ends = item.kind.ends {
            let point = AnnotationGeometry.point(end == .from ? ends.from : ends.to, in: rect, rotation: item.rotation)
            knob(at: point, filled: false)
                .onHover { inside in
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .gesture(endDrag(end, id: item.id))
                .help(end == .to && item.kind.name == .arrow
                      ? "Drag to aim the arrow · ⇧ snaps to 15°" : "Drag to move this end · ⇧ snaps to 15°")
                .accessibilityLabel(end == .from ? "Start" : "End")
        }
    }

    /// The tip of a callout's tail, filled so it reads as a different thing from the
    /// bubble's own handles.
    private func tailHandle(_ tail: CGPoint, of item: AnnotationItem, in rect: CGRect) -> some View {
        knob(at: AnnotationGeometry.point(tail, in: rect, rotation: item.rotation), filled: true)
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(tailDrag(id: item.id))
            .help("Drag to point the tail")
            .accessibilityLabel("Tail")
    }

    private func knob(at point: CGPoint, filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.white)
            .overlay(Circle().strokeBorder(filled ? Color.white : Color.accentColor, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
            .contentShape(Circle().inset(by: -8))
            .position(tilt.drawn(point))
    }

    /// Moving one end of a line, the other held where it is on the picture.
    private func endDrag(_ end: End, id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let held = beginEnd(end, id: id), var moving = tilt.flat(value.location) else { return }
                if NSEvent.modifierFlags.contains(.shift) {
                    let angle = atan2(moving.y - held.y, moving.x - held.x)
                    let step = Double.pi / 12
                    let snapped = (angle / step).rounded() * step
                    let length = hypot(moving.x - held.x, moving.y - held.y)
                    moving = CGPoint(x: held.x + length * cos(snapped), y: held.y + length * sin(snapped))
                }
                let placed = AnnotationGeometry.ends(from: end == .from ? moving : held,
                                                     to: end == .from ? held : moving,
                                                     minimumSide: 16)
                model.setEnds(ofAnnotation: id, rect: geometry.annotation(view: placed.rect),
                              from: placed.from, to: placed.to)
            }
            .onEnded { _ in
                heldEnd = nil
                model.finishInteraction()
            }
    }

    /// Where the end that is not moving is, worked out once when the drag starts.
    private func beginEnd(_ end: End, id: UUID) -> CGPoint? {
        if let heldEnd { return heldEnd }
        guard let item = model.annotation(id), let ends = item.kind.ends else { return nil }
        let rect = geometry.view(annotation: item.rect)
        let held = AnnotationGeometry.point(end == .from ? ends.to : ends.from, in: rect, rotation: item.rotation)
        heldEnd = held
        model.select(.annotation(id))
        model.document.beginInteraction("Move End")
        return held
    }

    private func tailDrag(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let item = model.annotation(id), let location = tilt.flat(value.location) else { return }
                if !isPointing {
                    isPointing = true
                    model.select(.annotation(id))
                    model.document.beginInteraction("Move Tail")
                }
                let rect = geometry.view(annotation: item.rect)
                model.setTail(ofAnnotation: id, to: AnnotationGeometry.local(location, in: rect,
                                                                             rotation: item.rotation))
            }
            .onEnded { _ in
                isPointing = false
                model.finishInteraction()
            }
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
            geometry.view(blur: model.timeline.blurs.first { $0.id == id }?.rect(at: model.playhead) ?? .zero)
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
        case .blur: model.setMaskRect(id, shown: geometry.blur(view: rect))
        case .annotation: model.setRegionRect(id, rect: geometry.annotation(view: rect))
        }
    }

    private func end() {
        gestureOrigin = nil
        fontOrigin = nil
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

    /// The same mapping, told which part of the recording the picture is showing. A blur
    /// is stored against the whole recording and the renderer applies it before it crops,
    /// so its outline has to be drawn through the crop as well — see `PictureMapping`.
    private var footageMapping: PictureMapping {
        PictureMapping(stage: stage, video: videoInOutput,
                       crop: scene?.sourceCrop ?? PictureMapping.wholeRecording)
    }

    func view(blur rect: CGRect) -> CGRect { footageMapping.view(footage: rect) }

    func blur(view rect: CGRect) -> CGRect { footageMapping.footage(view: rect) }

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

/// The knob above a box that turns it: a corner knob with a turning arrow in it, so it says
/// what it does before it is tried.
private struct RotationKnob: View {
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            Circle().strokeBorder(Color.accentColor, lineWidth: 1.25)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 15, height: 15)
        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
        .scaleEffect(isHovering ? 1.15 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.closedHand.push() } else { NSCursor.pop() }
        }
    }
}
