import AppKit
import Observation
import os

enum EditorTool: String, CaseIterable, Identifiable {
    case select, background, crop, pencil, highlighter, highlight, shape, arrow, text, blur, counter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .background: "Background"
        case .crop: "Crop"
        case .pencil: "Pencil"
        case .highlighter: "Marker"
        case .highlight: "Highlight"
        case .shape: "Shape"
        case .arrow: "Arrow"
        case .text: "Text"
        case .blur: "Blur"
        case .counter: "Counter"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .background: "photo.on.rectangle.angled"
        case .crop: "crop"
        case .pencil: "pencil.tip"
        case .highlighter: "scribble.variable"
        case .highlight: "highlighter"
        case .shape: "square"
        case .arrow: "arrow.down.left"
        case .text: "character"
        case .blur: "drop.fill"
        case .counter: "1.circle.fill"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .background: "g"
        case .crop: "c"
        case .pencil: "p"
        case .highlighter: "m"
        case .highlight: "h"
        case .shape: "r"
        case .arrow: "a"
        case .text: "t"
        case .blur: "b"
        case .counter: "n"
        }
    }

    var isDrawing: Bool { self != .select && self != .background && self != .crop }
}

enum ShapeKind: String, CaseIterable, Identifiable, Codable {
    case rectangle, ellipse, line
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .rectangle: "square"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        }
    }
}

enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Moves this handle of `rect` to `point` (flipped coordinates: y grows downward).
    func resize(_ rect: CGRect, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch self {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }

    /// The handle across the rect, which stays put while this one is dragged.
    var opposite: ResizeHandle {
        switch self {
        case .topLeft: .bottomRight
        case .top: .bottom
        case .topRight: .bottomLeft
        case .right: .left
        case .bottomRight: .topLeft
        case .bottom: .top
        case .bottomLeft: .topRight
        case .left: .right
        }
    }
}

enum ZoomCommand {
    case fit, actualSize, zoomIn, zoomOut
}

/// Preview shows the capture read-only with zoom / copy / delete and an Edit button;
/// Edit is the full annotation toolbar. Both live in the same window.
enum EditorMode {
    case preview, edit
}

/// Editor state: the document, undo, the active tool and its options, and the
/// in-progress interaction. Views observe it; the canvas redraws on any change.
@Observable
final class EditorViewModel {
    private(set) var document: EditorDocument
    let effects = EffectsCache()

    var mode: EditorMode = .edit {
        didSet {
            guard mode != oldValue, mode == .preview else { return }
            tool = .select
            selectedID = nil
        }
    }

    var tool: EditorTool = .select {
        didSet {
            guard tool != oldValue else { return }
            endTextEditing()
            selectedID = nil
            if tool != .crop { cropDraft = nil }
            if tool == .crop { cropDraft = document.crop ?? document.imageRect }
            if tool == .background, document.background == nil { commit { $0.background = BackgroundStyle() } }
        }
    }
    var selectedID: UUID?
    var draft: Annotation?
    var cropDraft: CGRect?
    var editingTextID: UUID?
    var hoverHandle: ResizeHandle?

    // Tool options; start from `EditorDefaults` (Settings › Editor).
    var color: RGBA = .red { didSet { applyStyleToSelection() } }
    var strokeWidth: CGFloat = 4 { didSet { applyStyleToSelection() } }
    var fillMode: FillMode = .none { didSet { applyStyleToSelection() } }
    var shapeKind: ShapeKind = .rectangle
    var arrowStyle: ArrowStyle = .single { didSet { applyStyleToSelection() } }
    var fontSize: CGFloat = TextStyle.defaultSize { didSet { applyStyleToSelection() } }
    var fontWeight: CGFloat = TextStyle.defaultWeight { didSet { applyStyleToSelection() } }
    var textBackground: TextBackground = .none { didSet { applyStyleToSelection() } }
    var blurKind: BlurKind = .blur { didSet { applyStyleToSelection() } }
    var blurIntensity: CGFloat = 12 { didSet { applyStyleToSelection() } }
    var counterSize: CGFloat = 30 { didSet { applyStyleToSelection() } }
    var highlighterWidth: CGFloat = 18 { didSet { applyStyleToSelection() } }
    var highlightColor: RGBA = .yellow { didSet { applyStyleToSelection() } }

    var zoom: CGFloat = 1
    /// Set by the canvas. Zoom goes straight to it rather than through an observed
    /// property, which dropped a repeated click and re-applied on unrelated updates.
    @ObservationIgnored var zoomHandler: ((ZoomCommand) -> Void)?

    func applyZoom(_ command: ZoomCommand) {
        zoomHandler?(command)
    }

    let undoManager = UndoManager()
    private(set) var isDirty = false
    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    private var suppressStyleSync = false

    init(image: CapturedImage, defaults: EditorDefaults = EditorDefaults()) {
        document = EditorDocument(image: image)
        options = defaults
    }

    /// The current tool options as a defaults record (and the way to apply one).
    var options: EditorDefaults {
        get {
            var record = EditorDefaults()
            record.color = color; record.highlightColor = highlightColor
            record.strokeWidth = strokeWidth; record.fillMode = fillMode; record.shapeKind = shapeKind; record.arrowStyle = arrowStyle
            record.fontSize = fontSize; record.fontWeight = fontWeight; record.textBackground = textBackground
            record.highlighterWidth = highlighterWidth; record.blurKind = blurKind; record.blurIntensity = blurIntensity
            record.counterSize = counterSize
            return record
        }
        set {
            suppressStyleSync = true
            defer { suppressStyleSync = false }
            color = newValue.color; highlightColor = newValue.highlightColor
            strokeWidth = newValue.strokeWidth; fillMode = newValue.fillMode; shapeKind = newValue.shapeKind; arrowStyle = newValue.arrowStyle
            fontSize = newValue.fontSize; fontWeight = newValue.fontWeight; textBackground = newValue.textBackground
            highlighterWidth = newValue.highlighterWidth; blurKind = newValue.blurKind; blurIntensity = newValue.blurIntensity
            counterSize = newValue.counterSize
        }
    }

    // MARK: - Document mutation with undo

    func commit(_ change: (inout EditorDocument) -> Void) {
        let before = document
        var after = document
        change(&after)
        document = after
        isDirty = true
        registerUndo(returningTo: before)
    }

    private func registerUndo(returningTo state: EditorDocument) {
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.document
            model.document = state
            model.isDirty = true
            model.selectedID = nil
            model.registerUndo(returningTo: current)
        }
    }

    func undo() { endTextEditing(); undoManager.undo() }
    func redo() { endTextEditing(); undoManager.redo() }

    func markSaved() { isDirty = false }

    // MARK: - Compare

    /// Lays `images` beside what is on the canvas and makes that the document: the
    /// current annotations, crop and background are flattened into the first piece, so
    /// the comparison shows exactly what was on screen. ⌘Z brings the single image back.
    @discardableResult
    func compare(with images: [CapturedImage], axis: CompareAxis = .auto) -> Bool {
        guard !images.isEmpty else { return false }
        endTextEditing()
        // The backdrop is left off the flattened piece and re-applied to the result, so
        // the padding and gradient frame the whole comparison rather than one image.
        var flattened = document
        let background = flattened.background
        flattened.background = nil
        guard let base = DocumentExporter.render(flattened, effects: effects) else { return false }
        let pieces = [CompareComposer.Piece(image: base, scale: document.scale)] + images.map(CompareComposer.Piece.init)
        guard let composed = CompareComposer.compose(pieces, axis: axis) else { return false }

        let previous = document
        var next = EditorDocument(image: composed)
        next.background = background
        // Counters already drawn into the flattened piece are not offered again.
        next.nextCounter = document.nextCounter
        document = next
        selectedID = nil
        draft = nil
        editingTextID = nil
        // The crop tool always has a draft rect while it is selected.
        cropDraft = tool == .crop ? next.imageRect : nil
        effects.invalidate()
        isDirty = true
        registerUndo(returningTo: previous)
        // After the canvas has taken the new document's size.
        DispatchQueue.main.async { [weak self] in self?.applyZoom(.fit) }
        return true
    }

    // MARK: - Selection

    var selected: Annotation? {
        selectedID.flatMap { document.annotation(id: $0) }
    }

    func select(_ id: UUID?) {
        selectedID = id
        syncOptions(from: selected)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        endTextEditing()
        commit { $0.remove(id: id) }
        selectedID = nil
    }

    func duplicateSelected() {
        guard let annotation = selected else { return }
        let copy = Annotation(kind: annotation.moved(by: CGPoint(x: 16, y: 16)).kind)
        commit { $0.annotations.append(copy) }
        selectedID = copy.id
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let annotation = selected else { return }
        commit { $0.update(annotation.moved(by: CGPoint(x: dx, y: dy))) }
    }

    /// Pull the selected annotation's style into the option controls.
    private func syncOptions(from annotation: Annotation?) {
        guard let annotation else { return }
        suppressStyleSync = true
        defer { suppressStyleSync = false }
        switch annotation.kind {
        case .rectangle(_, let style), .ellipse(_, let style):
            color = style.stroke.color; strokeWidth = style.stroke.width; fillMode = style.fill
        case .line(_, _, let style), .pencil(_, let style):
            color = style.color; strokeWidth = style.width
        case .arrow(_, _, _, let style, let arrowStyle):
            color = style.color; strokeWidth = style.width; self.arrowStyle = arrowStyle
        case .highlighter(_, let style):
            color = style.color; highlighterWidth = style.width
        case .highlight(_, let c):
            highlightColor = c
        case .text(_, _, let style):
            color = style.color; fontSize = style.fontSize; textBackground = style.background; fontWeight = style.weight
        case .counter(_, _, let c, let size):
            color = c; counterSize = size
        case .blur(_, let kind, let intensity):
            blurKind = kind; blurIntensity = intensity
        }
    }

    /// Push option changes onto the selected annotation.
    private func applyStyleToSelection() {
        guard !suppressStyleSync, let annotation = selected else { return }
        var updated = annotation
        switch annotation.kind {
        case .rectangle(let rect, _):
            updated.kind = .rectangle(rect: rect, style: ShapeStyle(stroke: StrokeStyle(color: color, width: strokeWidth), fill: fillMode))
        case .ellipse(let rect, _):
            updated.kind = .ellipse(rect: rect, style: ShapeStyle(stroke: StrokeStyle(color: color, width: strokeWidth), fill: fillMode))
        case .line(let a, let b, _):
            updated.kind = .line(start: a, end: b, style: StrokeStyle(color: color, width: strokeWidth))
        case .arrow(let a, let b, let bend, _, _):
            updated.kind = .arrow(start: a, end: b, bend: bend, style: StrokeStyle(color: color, width: strokeWidth), arrowStyle: arrowStyle)
        case .pencil(let points, _):
            updated.kind = .pencil(points: points, style: StrokeStyle(color: color, width: strokeWidth))
        case .highlighter(let points, _):
            updated.kind = .highlighter(points: points, style: StrokeStyle(color: color, width: highlighterWidth))
        case .text(let origin, let text, _):
            updated.kind = .text(origin: origin, text: text, style: TextStyle(color: color, fontSize: fontSize, background: textBackground, weight: fontWeight))
        case .counter(let center, let n, _, _):
            updated.kind = .counter(center: center, number: n, color: color, size: counterSize)
        case .highlight(let rect, _):
            updated.kind = .highlight(rect: rect, color: highlightColor)
        case .blur(let rect, _, _):
            updated.kind = .blur(rect: rect, kind: blurKind, intensity: blurIntensity)
        }
        guard updated != annotation else { return }
        commit { $0.update(updated) }
    }

    // MARK: - Crop

    func applyCrop() {
        guard let rect = cropDraft?.intersection(document.imageRect), rect.width >= 2, rect.height >= 2 else { return }
        let integral = rect.integral
        commit { $0.crop = integral == $0.imageRect ? nil : integral }
        cropDraft = nil
        tool = .select
    }

    func resetCrop() {
        commit { $0.crop = nil }
        cropDraft = document.imageRect
    }

    // MARK: - Background

    var background: BackgroundStyle {
        get { document.background ?? BackgroundStyle() }
        set { commit { $0.background = newValue } }
    }

    func removeBackground() {
        commit { $0.background = nil }
        tool = .select
    }

    // MARK: - Text editing

    func beginTextEditing(_ id: UUID) {
        editingTextID = id
        selectedID = id
    }

    /// Document as it was before editing started (one undo step is registered when
    /// editing ends). Set eagerly for a freshly placed box, lazily on the first edit
    /// of an existing one.
    private var textEditingSnapshot: EditorDocument?

    func updateEditingText(_ text: String) {
        guard let id = editingTextID, let annotation = document.annotation(id: id),
              case .text(let origin, _, let style) = annotation.kind
        else { return }
        if textEditingSnapshot == nil { textEditingSnapshot = document }
        var updated = annotation
        updated.kind = .text(origin: origin, text: text, style: style)
        document.update(updated)
    }

    func endTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        let snapshot = textEditingSnapshot
        textEditingSnapshot = nil
        if let annotation = document.annotation(id: id), case .text(_, let text, _) = annotation.kind,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty text box: drop it. Only an existing box that had text is an undoable change.
            document.remove(id: id)
            if let snapshot, let previous = snapshot.annotation(id: id), case .text(_, let old, _) = previous.kind, !old.isEmpty {
                isDirty = true
                registerUndo(returningTo: snapshot)
            }
            selectedID = nil
            return
        }
        if let snapshot, snapshot.annotations != document.annotations {
            isDirty = true
            registerUndo(returningTo: snapshot)
        }
    }

    // MARK: - Output

    func renderedImage() -> CGImage? {
        DocumentExporter.render(document, effects: effects)
    }

    // MARK: - Interaction (called by the canvas with image-space points)

    private enum Drag {
        case none
        case creating(anchor: CGPoint)
        case moving(id: UUID, origin: Annotation, start: CGPoint)
        case resizing(id: UUID, handle: ResizeHandle, origin: Annotation)
        case endpoint(id: UUID, which: Int, origin: Annotation)
        case bend(id: UUID, origin: Annotation)
        case rotating(id: UUID, origin: Annotation, startAngle: CGFloat)
        case cropCreating(anchor: CGPoint)
        case cropMoving(origin: CGRect, start: CGPoint)
        case cropResizing(handle: ResizeHandle, origin: CGRect)
    }

    private var drag: Drag = .none
    private var pencilPoints: [CGPoint] = []

    /// The cursor to hold while the current drag lasts, if it has one.
    var dragCursor: NSCursor? {
        switch drag {
        case .moving, .cropMoving: .closedHand
        case .resizing(_, let handle, _), .cropResizing(let handle, _): handle.cursor
        case .rotating: .rotate
        default: nil
        }
    }

    /// `tolerance` is in image points (screen pixels ÷ zoom).
    func mouseDown(at point: CGPoint, clickCount: Int, shift: Bool, tolerance: CGFloat) {
        if editingTextID != nil {
            if let id = editingTextID, let annotation = document.annotation(id: id), annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return // click inside the editor itself
            }
            endTextEditing()
        }

        // Any tool except the freehand ones and crop grabs an existing annotation under the
        // cursor, so shapes and text can be moved, resized or deleted without switching to
        // Select first.
        if tool != .pencil, tool != .highlighter, tool != .crop {
            if let selected {
                if selected.hasEndpoints {
                    let (a, b) = endpoints(of: selected)
                    if point.distance(to: b) <= tolerance * 2 { drag = .endpoint(id: selected.id, which: 1, origin: selected); return }
                    if point.distance(to: a) <= tolerance * 2 { drag = .endpoint(id: selected.id, which: 0, origin: selected); return }
                    if let middle = bendHandle(of: selected), point.distance(to: middle) <= tolerance * 2 {
                        drag = .bend(id: selected.id, origin: selected); return
                    }
                } else {
                    if selected.canRotate, let knob = rotationHandle(of: selected, tolerance: tolerance), point.distance(to: knob) <= tolerance * 2 {
                        let center = selected.center
                        drag = .rotating(id: selected.id, origin: selected, startAngle: atan2(point.y - center.y, point.x - center.x))
                        return
                    }
                    if selected.isResizable, let handle = handle(at: selected.localPoint(point), in: selected.bounds, tolerance: tolerance) {
                        drag = .resizing(id: selected.id, handle: handle, origin: selected)
                        return
                    }
                }
            }
            if let hit = hitTest(point, tolerance: tolerance) {
                select(hit.id)
                if clickCount == 2, case .text = hit.kind {
                    beginTextEditing(hit.id)
                    return
                }
                drag = .moving(id: hit.id, origin: hit, start: point)
                return
            }
            select(nil)
        }

        switch tool {
        case .select, .background:
            break

        case .crop:
            let current = cropDraft ?? document.imageRect
            if let handle = handle(at: point, in: current, tolerance: tolerance) {
                drag = .cropResizing(handle: handle, origin: current)
            } else if current.contains(point) {
                drag = .cropMoving(origin: current, start: point)
            } else {
                drag = .cropCreating(anchor: point)
                cropDraft = CGRect(origin: point, size: .zero)
            }

        case .pencil, .highlighter:
            pencilPoints = [point]
            drag = .creating(anchor: point)
            draft = makeAnnotation(anchor: point, current: point, shift: shift)

        case .text:
            let style = TextStyle(color: color, fontSize: fontSize, background: textBackground, weight: fontWeight)
            let annotation = Annotation(kind: .text(origin: point, text: "", style: style))
            // Not committed yet: an abandoned empty box vanishes without an undo step; the
            // first keystroke snapshots the document without it and registers undo on end.
            textEditingSnapshot = document
            document.annotations.append(annotation)
            beginTextEditing(annotation.id)

        case .counter:
            let number = document.nextCounter
            let annotation = Annotation(kind: .counter(center: point, number: number, color: color, size: counterSize))
            commit {
                $0.annotations.append(annotation)
                $0.nextCounter = number + 1
            }
            select(annotation.id)

        case .shape, .arrow, .blur, .highlight:
            drag = .creating(anchor: point)
            draft = makeAnnotation(anchor: point, current: point, shift: shift)
        }
    }

    func mouseDragged(to point: CGPoint, shift: Bool) {
        switch drag {
        case .none:
            break
        case .creating(let anchor):
            if tool == .pencil || tool == .highlighter {
                if let last = pencilPoints.last, last.distance(to: point) >= 1.5 { pencilPoints.append(point) }
                draft = makeAnnotation(anchor: anchor, current: point, shift: shift)
            } else {
                draft = makeAnnotation(anchor: anchor, current: point, shift: shift)
            }
        case .moving(_, let origin, let start):
            document.update(origin.moved(by: point - start))
        case .resizing(_, let handle, let origin):
            // Resize in the shape's own frame, then keep the opposite handle where it was on
            // screen so a rotated box grows from the dragged edge instead of swinging.
            let resized = handle.resize(origin.bounds, to: origin.localPoint(point))
            let anchor = origin.worldPoint(handle.opposite.point(in: origin.bounds))
            let updated = origin.withRect(resized)
            let anchorNow = updated.worldPoint(handle.opposite.point(in: resized))
            document.update(updated.withRect(resized.offsetBy(dx: anchor.x - anchorNow.x, dy: anchor.y - anchorNow.y)))
        case .rotating(_, let origin, let startAngle):
            let center = origin.center
            var angle = origin.rotation + atan2(point.y - center.y, point.x - center.x) - startAngle
            if shift { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) } // 15° steps
            let turn = 2 * CGFloat.pi
            angle = angle.truncatingRemainder(dividingBy: turn)
            if abs(angle) < 0.01 { angle = 0 }
            document.update(origin.withRotation(angle))
        case .endpoint(_, let which, let origin):
            let (a, b) = endpoints(of: origin)
            var end = point
            if shift, which == 1 { end = Self.snapAngle(from: a, to: point) }
            if shift, which == 0 { end = Self.snapAngle(from: b, to: point) }
            document.update(which == 0 ? origin.withEndpoints(start: end, end: b) : origin.withEndpoints(start: a, end: end))
        case .bend(_, let origin):
            let (a, b) = endpoints(of: origin)
            var bend = ArrowGeometry.bend(forHandleAt: point, start: a, end: b)
            // Snap back to straight when the handle is dragged close to the chord.
            if ArrowGeometry.handlePoint(start: a, end: b, bend: bend).distance(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) < 3 { bend = .zero }
            document.update(origin.withBend(bend))
        case .cropCreating(let anchor):
            cropDraft = CGRect.spanning(anchor, clamp(point)).intersection(document.imageRect)
        case .cropMoving(let origin, let start):
            var moved = origin.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(0, moved.minX), document.imageSize.width - moved.width)
            moved.origin.y = min(max(0, moved.minY), document.imageSize.height - moved.height)
            cropDraft = moved
        case .cropResizing(let handle, let origin):
            cropDraft = handle.resize(origin, to: clamp(point)).intersection(document.imageRect)
        }
    }

    func mouseUp(at point: CGPoint) {
        defer { drag = .none; pencilPoints = [] }
        switch drag {
        case .creating(let anchor):
            guard var annotation = draft else { return }
            draft = nil
            // Ignore accidental clicks that produced nothing.
            switch annotation.kind {
            case .pencil, .highlighter:
                if pencilPoints.count < 2 { return }
            default:
                if anchor.distance(to: point) < 3 { return }
            }
            annotation = Annotation(kind: annotation.kind)
            commit { $0.annotations.append(annotation) }
            select(annotation.id)
        case .moving(_, let origin, _), .resizing(_, _, let origin), .endpoint(_, _, let origin), .bend(_, let origin), .rotating(_, let origin, _):
            // The live drag mutated the document directly; register one undo step for it.
            guard let now = document.annotation(id: origin.id), now != origin else { return }
            var before = document
            before.update(origin)
            isDirty = true
            registerUndo(returningTo: before)
        case .cropCreating:
            if let rect = cropDraft, rect.width < 2 || rect.height < 2 { cropDraft = document.crop ?? document.imageRect }
        case .cropMoving, .cropResizing, .none:
            break
        }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), document.imageSize.width), y: min(max(0, point.y), document.imageSize.height))
    }

    private func makeAnnotation(anchor: CGPoint, current: CGPoint, shift: Bool) -> Annotation {
        switch tool {
        case .shape:
            var rect = CGRect.spanning(anchor, current)
            if shift {
                let side = max(rect.width, rect.height)
                rect = CGRect(x: current.x >= anchor.x ? anchor.x : anchor.x - side,
                              y: current.y >= anchor.y ? anchor.y : anchor.y - side, width: side, height: side)
            }
            let style = ShapeStyle(stroke: StrokeStyle(color: color, width: strokeWidth), fill: fillMode)
            switch shapeKind {
            case .rectangle: return Annotation(kind: .rectangle(rect: rect, style: style))
            case .ellipse: return Annotation(kind: .ellipse(rect: rect, style: style))
            case .line:
                let end = shift ? Self.snapAngle(from: anchor, to: current) : current
                return Annotation(kind: .line(start: anchor, end: end, style: style.stroke))
            }
        case .arrow:
            let end = shift ? Self.snapAngle(from: anchor, to: current) : current
            return Annotation(kind: .arrow(start: anchor, end: end, bend: .zero, style: StrokeStyle(color: color, width: strokeWidth), arrowStyle: arrowStyle))
        case .blur:
            return Annotation(kind: .blur(rect: CGRect.spanning(anchor, current).intersection(document.imageRect), kind: blurKind, intensity: blurIntensity))
        case .highlight:
            return Annotation(kind: .highlight(rect: CGRect.spanning(anchor, current), color: highlightColor))
        case .pencil:
            return Annotation(kind: .pencil(points: pencilPoints, style: StrokeStyle(color: color, width: strokeWidth)))
        case .highlighter:
            let points = shift ? [pencilPoints[0], CGPoint(x: current.x, y: pencilPoints[0].y)] : pencilPoints
            return Annotation(kind: .highlighter(points: points, style: StrokeStyle(color: color, width: highlighterWidth)))
        default:
            return Annotation(kind: .rectangle(rect: .zero, style: ShapeStyle(stroke: StrokeStyle(color: color, width: strokeWidth), fill: .none)))
        }
    }

    /// Snaps the direction to 45° steps.
    private static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return b }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }

    // MARK: - Hit testing

    func endpoints(of annotation: Annotation) -> (CGPoint, CGPoint) {
        switch annotation.kind {
        case .line(let a, let b, _), .arrow(let a, let b, _, _, _): (a, b)
        default: (.zero, .zero)
        }
    }

    /// The draggable middle point of an arrow (on the curve), if `annotation` is one.
    func bendHandle(of annotation: Annotation) -> CGPoint? {
        guard case .arrow(let a, let b, let bend, _, _) = annotation.kind else { return nil }
        return ArrowGeometry.handlePoint(start: a, end: b, bend: bend)
    }

    func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> ResizeHandle? {
        ResizeHandle.allCases.first { $0.point(in: rect).distance(to: point) <= tolerance * 1.6 }
    }

    /// The rotation knob: a little above the top edge, turning with the shape.
    /// `tolerance` (image points per few screen pixels) keeps its distance zoom-independent.
    func rotationHandle(of annotation: Annotation, tolerance: CGFloat) -> CGPoint? {
        guard annotation.canRotate else { return nil }
        let bounds = annotation.bounds
        return annotation.worldPoint(CGPoint(x: bounds.midX, y: bounds.minY - tolerance * 4))
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Annotation? {
        for annotation in document.annotations.reversed() {
            let point = annotation.localPoint(point) // rotated shapes are tested in their own frame
            switch annotation.kind {
            case .line(let a, let b, let style):
                if Self.distance(from: point, toSegment: a, b) <= max(style.width / 2, 2) + tolerance { return annotation }
            case .arrow(let a, let b, let bend, let style, _):
                let threshold = max(style.width / 2, 2) + tolerance
                let points = ArrowGeometry.points(start: a, end: b, bend: bend)
                for i in 0..<(points.count - 1) where Self.distance(from: point, toSegment: points[i], points[i + 1]) <= threshold {
                    return annotation
                }
            case .pencil(let points, let style), .highlighter(let points, let style):
                let threshold = max(style.width / 2, 2) + tolerance
                for i in 0..<max(points.count - 1, 1) where Self.distance(from: point, toSegment: points[i], points[min(i + 1, points.count - 1)]) <= threshold {
                    return annotation
                }
            case .ellipse(let rect, let style):
                // Inside the ellipse (filled) or near its edge.
                let inside = Self.ellipseContains(rect, point)
                if style.fill != .none, inside { return annotation }
                let outer = Self.ellipseContains(rect.insetBy(dx: -tolerance - style.stroke.width, dy: -tolerance - style.stroke.width), point)
                let inner = Self.ellipseContains(rect.insetBy(dx: tolerance + style.stroke.width, dy: tolerance + style.stroke.width), point)
                if outer, !inner { return annotation }
            case .rectangle(let rect, let style):
                if style.fill != .none, rect.contains(point) { return annotation }
                let outer = rect.insetBy(dx: -tolerance - style.stroke.width, dy: -tolerance - style.stroke.width)
                let inner = rect.insetBy(dx: tolerance + style.stroke.width, dy: tolerance + style.stroke.width)
                if outer.contains(point), !inner.contains(point) { return annotation }
            default:
                if annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) { return annotation }
            }
        }
        return nil
    }

    private static func ellipseContains(_ rect: CGRect, _ p: CGPoint) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let dx = (p.x - rect.midX) / (rect.width / 2)
        let dy = (p.y - rect.midY) / (rect.height / 2)
        return dx * dx + dy * dy <= 1
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
        return p.distance(to: CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t))
    }
}
