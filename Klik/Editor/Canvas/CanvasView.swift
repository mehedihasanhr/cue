import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The drawing surface. Flipped, so view coordinates equal output-space points and
/// the renderer's top-left origin needs no conversion. Zooming is done by the
/// enclosing scroll view's magnification.
final class CanvasView: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    let model: EditorViewModel
    private let renderer: AnnotationRenderer
    private var trackingArea: NSTrackingArea?
    private var textEditor: NSTextView?
    private var textEditorID: UUID?
    private var observationActive = false

    init(model: EditorViewModel) {
        self.model = model
        renderer = AnnotationRenderer(effects: model.effects)
        super.init(frame: CGRect(origin: .zero, size: model.document.outputSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Redraw whenever anything observable in the model changes.
    private func observe() {
        withObservationTracking {
            _ = model.document.annotations
            _ = model.document.crop
            _ = model.document.background
            _ = model.draft
            _ = model.selectedID
            _ = model.cropDraft
            _ = model.editingTextID
            _ = model.tool
            _ = model.hoverHandle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.modelDidChange()
                self.observe()
            }
        }
    }

    private func modelDidChange() {
        let size = model.document.outputSize
        if frame.size != size {
            setFrameSize(size)
            (enclosingScrollView as? CanvasScrollView)?.documentSizeChanged()
        }
        syncTextEditor()
        needsDisplay = true
    }

    // MARK: - Coordinates

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var tolerance: CGFloat { 6 / magnification }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return local - model.document.contentOffset
    }

    private func viewRect(_ imageRect: CGRect) -> CGRect {
        imageRect.offsetBy(dx: model.document.contentOffset.x, dy: model.document.contentOffset.y)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var document = model.document
        // The text field editor is axis-aligned, so the text under it is shown that way too.
        if let id = model.editingTextID, let index = document.annotations.firstIndex(where: { $0.id == id }) {
            document.annotations[index].rotation = 0
        }
        drawBackdrop(document, context: context)
        renderer.drawContent(document, context: context)
        renderer.drawAnnotations(document, draft: model.draft, context: context)

        let lineScale = 1 / magnification

        if model.tool == .crop, let crop = model.cropDraft {
            drawCropOverlay(crop, context: context, lineScale: lineScale)
        } else if let selected = model.selected, model.editingTextID == nil {
            drawSelection(selected, context: context, lineScale: lineScale)
        }
    }

    // MARK: Backdrop cache

    private struct BackdropKey: Equatable {
        let background: Klik.BackgroundStyle
        let size: CGSize
        let card: CGRect
    }

    private var backdrop: (key: BackdropKey, image: CGImage)?

    /// Gradients, blurred wallpapers and the card's soft shadow are slow to draw at full
    /// resolution and change only when the background settings do, yet a drag or a hover
    /// redraws the whole view many times a second. They are rendered once into a bitmap
    /// — capped at ~2K, which is invisible for such low-frequency content — and blitted.
    /// The image, inset and annotations stay live so nothing sharp goes through the cache.
    private func drawBackdrop(_ document: EditorDocument, context: CGContext) {
        guard let background = document.background else { return }
        let layout = document.layout
        let key = BackdropKey(background: background, size: layout.size, card: layout.card)
        let image: CGImage
        if let backdrop, backdrop.key == key {
            image = backdrop.image
        } else {
            guard let rendered = renderBackdrop(document, size: layout.size) else {
                renderer.drawBackdrop(document, context: context)
                return
            }
            backdrop = (key, rendered)
            image = rendered
        }
        let frame = CGRect(origin: .zero, size: layout.size)
        context.saveGState()
        // The view is flipped (y down); CGImage draws y-up, so flip around the frame.
        context.translateBy(x: 0, y: frame.maxY + frame.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: frame)
        context.restoreGState()
    }

    private func renderBackdrop(_ document: EditorDocument, size: CGSize) -> CGImage? {
        let maxPixels: CGFloat = 2048
        let scale = min(document.scale, maxPixels / max(size.width, size.height, 1))
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Match the renderer's flipped, point-based coordinate space.
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: scale, y: -scale)
        renderer.drawBackdrop(document, context: bitmap)
        return bitmap.makeImage()
    }

    private func drawSelection(_ annotation: Annotation, context: CGContext, lineScale: CGFloat) {
        context.saveGState()
        context.translateBy(x: model.document.contentOffset.x, y: model.document.contentOffset.y)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(lineScale)

        if annotation.hasEndpoints {
            let (a, b) = model.endpoints(of: annotation)
            // A soft accent band along the stroke shows what is selected without hiding it.
            let path = CGMutablePath()
            let width: CGFloat
            switch annotation.kind {
            case .arrow(_, _, let bend, let style, _):
                path.move(to: a)
                if bend == .zero { path.addLine(to: b) } else { path.addQuadCurve(to: b, control: ArrowGeometry.control(start: a, end: b, bend: bend)) }
                width = style.width
            case .line(_, _, let style):
                path.move(to: a); path.addLine(to: b)
                width = style.width
            default:
                width = 2
            }
            context.saveGState()
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(width + 10 * lineScale)
            context.setLineCap(.round)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()

            for point in [a, b] {
                drawHandle(at: point, context: context, lineScale: lineScale, fill: .controlAccentColor, stroke: .white)
            }
            if let middle = model.bendHandle(of: annotation) {
                drawHandle(at: middle, context: context, lineScale: lineScale, radius: 4, fill: .systemPink, stroke: .white)
            }
        } else {
            // The frame, handles and rotation knob turn with the shape.
            if annotation.rotation != 0 {
                let center = annotation.center
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: annotation.rotation)
                context.translateBy(x: -center.x, y: -center.y)
            }
            let bounds = annotation.bounds.insetBy(dx: -2 * lineScale, dy: -2 * lineScale)
            context.setLineDash(phase: 0, lengths: [4 * lineScale, 3 * lineScale])
            context.stroke(bounds)
            context.setLineDash(phase: 0, lengths: [])
            if annotation.isResizable {
                for handle in ResizeHandle.allCases {
                    drawHandle(at: handle.point(in: annotation.bounds), context: context, lineScale: lineScale)
                }
            }
            if annotation.canRotate, model.editingTextID == nil {
                let knob = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.minY - tolerance * 4)
                context.setLineWidth(lineScale)
                context.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
                context.addLine(to: CGPoint(x: knob.x, y: knob.y + 4.5 * lineScale))
                context.strokePath()
                drawHandle(at: knob, context: context, lineScale: lineScale, radius: 4.5, fill: .controlAccentColor, stroke: .white)
            }
        }
        context.restoreGState()
    }

    private func drawHandle(at point: CGPoint, context: CGContext, lineScale: CGFloat, radius: CGFloat = 4.5,
                            fill: NSColor = .white, stroke: NSColor = .controlAccentColor) {
        let radius = radius * lineScale
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1.5 * lineScale)
        context.strokeEllipse(in: rect)
    }

    private func drawCropOverlay(_ crop: CGRect, context: CGContext, lineScale: CGFloat) {
        let rect = viewRect(crop)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.addRect(bounds)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(lineScale)
        context.stroke(rect)
        // Rule-of-thirds guides.
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            context.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        context.strokePath()
        for handle in ResizeHandle.allCases {
            drawHandle(at: handle.point(in: rect), context: context, lineScale: lineScale)
        }
        context.restoreGState()

        let label = "\(Int(crop.width)) × \(Int(crop.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * lineScale, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let pill = CGRect(x: rect.midX - size.width / 2 - 6 * lineScale, y: rect.maxY + 8 * lineScale,
                          width: size.width + 12 * lineScale, height: size.height + 6 * lineScale)
        context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 5 * lineScale, cornerHeight: 5 * lineScale, transform: nil))
        context.fillPath()
        label.draw(at: CGPoint(x: pill.minX + 6 * lineScale, y: pill.minY + 3 * lineScale), withAttributes: attributes)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard model.mode == .edit else { return }
        let point = imagePoint(from: event)
        model.mouseDown(at: point, clickCount: event.clickCount, shift: event.modifierFlags.contains(.shift), tolerance: tolerance)
        isDragging = true
        updateCursor(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.mode == .edit else { return }
        model.mouseDragged(to: imagePoint(from: event), shift: event.modifierFlags.contains(.shift))
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard model.mode == .edit else { return }
        model.mouseUp(at: imagePoint(from: event))
        isDragging = false
        updateCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    /// The cursor for the current tool/hover, declared through cursor rects so AppKit
    /// doesn't keep flipping back to the arrow between our updates (which showed as
    /// the pointer jumping while moving).
    private var desiredCursor: NSCursor = .arrow {
        didSet {
            guard desiredCursor !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if isDragging { desiredCursor.set() } // cursor rects don't update mid-drag
        }
    }
    private var isDragging = false

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: desiredCursor)
    }

    private func updateCursor(for event: NSEvent) {
        desiredCursor = cursor(for: imagePoint(from: event))
    }

    private func cursor(for point: CGPoint) -> NSCursor {
        guard model.mode == .edit else { return .arrow }
        if isDragging, let held = model.dragCursor { return held }
        switch model.tool {
        case .select, .background:
            if let selected = model.selected {
                if let knob = model.rotationHandle(of: selected, tolerance: tolerance), point.distance(to: knob) <= tolerance * 2 {
                    return .rotate
                }
                if selected.isResizable, let handle = model.handle(at: selected.localPoint(point), in: selected.bounds, tolerance: tolerance) {
                    return handle.cursor
                }
                if selected.hasEndpoints {
                    let (a, b) = model.endpoints(of: selected)
                    if point.distance(to: a) <= tolerance * 2 || point.distance(to: b) <= tolerance * 2 { return .crosshair }
                    if let middle = model.bendHandle(of: selected), point.distance(to: middle) <= tolerance * 2 { return .crosshair }
                }
            }
            return model.hitTest(point, tolerance: tolerance) != nil ? .openHand : .arrow
        case .crop:
            let crop = model.cropDraft ?? model.document.imageRect
            if let handle = model.handle(at: point, in: crop, tolerance: tolerance) { return handle.cursor }
            return crop.contains(point) ? .openHand : .crosshair
        case .pencil, .highlighter:
            return .crosshair
        default:
            if let selected = model.selected {
                if let knob = model.rotationHandle(of: selected, tolerance: tolerance), point.distance(to: knob) <= tolerance * 2 { return .rotate }
                if selected.isResizable, let handle = model.handle(at: selected.localPoint(point), in: selected.bounds, tolerance: tolerance) { return handle.cursor }
            }
            if model.hitTest(point, tolerance: tolerance) != nil { return .openHand }
            return model.tool == .text ? .iBeam : .crosshair
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if model.mode == .preview {
            if Int(event.keyCode) == kVK_Escape { window?.performClose(nil) } else { super.keyDown(with: event) }
            return
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelected()
        case kVK_Escape:
            if model.tool == .crop { model.tool = .select } else { model.select(nil) }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.tool == .crop { model.applyCrop() }
        case kVK_LeftArrow: model.nudgeSelected(dx: -step, dy: 0)
        case kVK_RightArrow: model.nudgeSelected(dx: step, dy: 0)
        case kVK_UpArrow: model.nudgeSelected(dx: 0, dy: -step)
        case kVK_DownArrow: model.nudgeSelected(dx: 0, dy: step)
        default:
            guard flags.isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first,
                  let tool = EditorTool.allCases.first(where: { $0.key == character })
            else { super.keyDown(with: event); return }
            model.tool = tool
        }
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func delete(_ sender: Any?) { model.deleteSelected() }
    override func selectAll(_ sender: Any?) {}

    @objc func duplicate(_ sender: Any?) { model.duplicateSelected() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): model.canUndo
        case #selector(redo(_:)): model.canRedo
        case #selector(delete(_:)), #selector(duplicate(_:)): model.selectedID != nil
        default: true
        }
    }

    // MARK: - Inline text editing

    private func syncTextEditor() {
        guard let id = model.editingTextID, let annotation = model.document.annotation(id: id),
              case .text(_, let text, let style) = annotation.kind
        else {
            if let textEditor {
                textEditor.removeFromSuperview()
                self.textEditor = nil
                textEditorID = nil
                window?.makeFirstResponder(self)
            }
            return
        }

        let editor: NSTextView
        if let existing = textEditor, textEditorID == id {
            editor = existing
        } else {
            // A different text box (e.g. the previous one was abandoned empty and a new
            // one placed in the same click): start from a fresh editor so no text carries over.
            textEditor?.removeFromSuperview()
            textEditorID = id
            editor = NSTextView()
            editor.delegate = self
            editor.isRichText = false
            editor.drawsBackground = false
            editor.isFieldEditor = false
            editor.textContainerInset = TextMetrics.padding
            editor.textContainer?.lineFragmentPadding = 0
            editor.textContainer?.widthTracksTextView = false
            editor.textContainer?.containerSize = CGSize(width: 4000, height: 4000)
            editor.isHorizontallyResizable = true
            editor.isVerticallyResizable = true
            editor.string = text
            addSubview(editor)
            textEditor = editor
            window?.makeFirstResponder(editor)
            editor.selectAll(nil)
        }
        editor.font = TextMetrics.font(for: style)
        editor.textColor = style.background == .solid ? (style.color.isLight ? .black : .white) : style.color.nsColor
        editor.insertionPointColor = editor.textColor ?? .white
        editor.frame = viewRect(annotation.bounds)
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor else { return }
        model.updateEditingText(editor.string)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            model.endTextEditing()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // ⌘↩ / plain ↩ finishes; ⇧↩ inserts a line break.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                model.endTextEditing()
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Scroll view

/// Centres the canvas when it is smaller than the viewport and provides zoom commands.
final class CanvasScrollView: NSScrollView {
    let canvas: CanvasView

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = canvas
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 8
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        scrollerStyle = .overlay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func documentSizeChanged() {
        contentView.needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Fit once the view has a real size; the first layout pass may run at zero bounds.
    private var needsInitialFit = true
    var onMagnificationChange: (() -> Void)?

    override func layout() {
        super.layout()
        if needsInitialFit, contentView.bounds.width > 120, contentView.bounds.height > 120 {
            needsInitialFit = false
            zoomToFit()
            onMagnificationChange?()
        }
    }

    func zoomToFit() {
        let available = contentView.bounds.size
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0, available.width > 80, available.height > 80 else { return }
        let scale = min((available.width - 40) / size.width, (available.height - 40) / size.height, 1)
        setMagnification(max(minMagnification, scale), centeredAt: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    func apply(_ command: ZoomCommand) {
        let centre = CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)
        switch command {
        case .fit: zoomToFit()
        case .actualSize: setMagnification(1, centeredAt: centre)
        case .zoomIn: setMagnification(min(maxMagnification, magnification * 1.25), centeredAt: centre)
        case .zoomOut: setMagnification(max(minMagnification, magnification / 1.25), centeredAt: centre)
        }
    }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let documentFrame = document.frame
        if documentFrame.width < rect.width {
            rect.origin.x = (documentFrame.width - rect.width) / 2
        }
        if documentFrame.height < rect.height {
            rect.origin.y = (documentFrame.height - rect.height) / 2
        }
        return rect
    }
}

// MARK: - SwiftUI bridge

struct CanvasRepresentable: NSViewRepresentable {
    let model: EditorViewModel

    func makeNSView(context: Context) -> CanvasScrollView {
        let scrollView = CanvasScrollView(canvas: CanvasView(model: model))
        scrollView.onMagnificationChange = { model.zoom = scrollView.magnification }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { _ in
            MainActor.assumeIsolated { model.zoom = scrollView.magnification }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: CanvasScrollView, context: Context) {
        if let command = model.zoomCommand {
            scrollView.apply(command)
            DispatchQueue.main.async {
                model.zoom = scrollView.magnification
                model.zoomCommand = nil
            }
        }
    }
}
