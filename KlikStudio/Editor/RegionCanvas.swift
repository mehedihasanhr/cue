import AppKit
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

    private var geometry: CanvasGeometry {
        CanvasGeometry(stage: stage, scene: model.scene)
    }

    private var isBlurring: Bool { model.tool == .blur }

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
        ZStack(alignment: .topLeading) {
            outline(kind: kind, isSelected: isSelected)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .contentShape(Rectangle())
                .onTapGesture { select(id: id, kind: kind) }
                .gesture(moveDrag(id: id, kind: kind))

            if isSelected {
                ForEach(Corner.allCases) { corner in
                    handle(corner, of: rect, id: id, kind: kind)
                }
            }
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
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.35),
                              lineWidth: isSelected ? 2 : 1)
                .overlay(alignment: .topLeading) {
                    if case .text(let string) = item.kind, string.isEmpty {
                        Text("Double-click to type")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(4)
                    }
                }
        }
    }

    private func select(id: UUID, kind: Kind) {
        switch kind {
        case .blur: model.select(.blur(id))
        case .annotation: model.select(.annotation(id))
        }
    }

    // MARK: - Handles

    private enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var movesLeft: Bool { self == .topLeft || self == .bottomLeft }
        var movesTop: Bool { self == .topLeft || self == .topRight }
    }

    private func handle(_ corner: Corner, of rect: CGRect, id: UUID, kind: Kind) -> some View {
        let point = CGPoint(x: corner.movesLeft ? rect.minX : rect.maxX,
                            y: corner.movesTop ? rect.minY : rect.maxY)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.4), radius: 2)
            // Slop around the drawn handle, for the same reason the crop handles have it:
            // ten points of white is a hairline to aim at.
            .contentShape(Rectangle().inset(by: -8))
            .position(point)
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(resizeDrag(corner, id: id, kind: kind))
    }

    // MARK: - Gestures

    /// Dragging on empty picture makes a new region.
    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 4)
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
                    model.addAnnotation(.text(""), rect: geometry.annotation(view: drawn))
                }
            }
    }

    private func moveDrag(id: UUID, kind: Kind) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = begin(id: id, kind: kind)
                var moved = start
                moved.origin.x += value.translation.width
                moved.origin.y += value.translation.height
                store(moved, id: id, kind: kind)
            }
            .onEnded { _ in end() }
    }

    private func resizeDrag(_ corner: Corner, id: UUID, kind: Kind) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = begin(id: id, kind: kind)
                var rect = start
                if corner.movesLeft {
                    let x = min(value.location.x, start.maxX - 8)
                    rect = CGRect(x: x, y: rect.minY, width: start.maxX - x, height: rect.height)
                } else {
                    rect.size.width = max(8, value.location.x - start.minX)
                }
                if corner.movesTop {
                    let y = min(value.location.y, start.maxY - 8)
                    rect = CGRect(x: rect.minX, y: y, width: rect.width, height: start.maxY - y)
                } else {
                    rect.size.height = max(8, value.location.y - start.minY)
                }
                store(rect, id: id, kind: kind)
            }
            .onEnded { _ in end() }
    }

    /// Opens one undo entry for a whole gesture, however many commands it applies.
    private func begin(id: UUID, kind: Kind) -> CGRect {
        if let gestureOrigin { return gestureOrigin }
        let rect: CGRect = switch kind {
        case .blur:
            geometry.view(blur: model.timeline.blurs.first { $0.id == id }?.rect ?? .zero)
        case .annotation:
            geometry.view(annotation: model.timeline.annotations.first { $0.id == id }?.rect ?? .zero)
        }
        gestureOrigin = rect
        select(id: id, kind: kind)
        model.document.beginInteraction("Move")
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
        model.document.endInteraction()
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

    func view(annotation rect: CGRect) -> CGRect {
        CGRect(x: stage.minX + rect.minX * stage.width,
               y: stage.minY + rect.minY * stage.height,
               width: rect.width * stage.width,
               height: rect.height * stage.height)
    }

    func annotation(view rect: CGRect) -> CGRect {
        guard stage.width > 0, stage.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - stage.minX) / stage.width,
                      y: (rect.minY - stage.minY) / stage.height,
                      width: rect.width / stage.width,
                      height: rect.height / stage.height)
    }

    // MARK: - Blurs: normalised to the recording

    /// Where the recording sits inside the finished frame, normalised, top-left origin.
    ///
    /// `transformedVideoFrame` is in output *pixels* with a bottom-left origin, which is
    /// Core Image's convention and not SwiftUI's — hence the flip. When there is no
    /// scene yet the whole stage stands in, so an overlay that draws a frame early puts
    /// its handles somewhere sane rather than at zero.
    private var videoInOutput: CGRect {
        guard let scene, scene.outputSize.width > 0, scene.outputSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let frame = scene.transformedVideoFrame
        return CGRect(x: frame.minX / scene.outputSize.width,
                      y: 1 - frame.maxY / scene.outputSize.height,
                      width: frame.width / scene.outputSize.width,
                      height: frame.height / scene.outputSize.height)
    }

    func view(blur rect: CGRect) -> CGRect {
        let video = videoInOutput
        return view(annotation: CGRect(x: video.minX + rect.minX * video.width,
                                       y: video.minY + rect.minY * video.height,
                                       width: rect.width * video.width,
                                       height: rect.height * video.height))
    }

    func blur(view rect: CGRect) -> CGRect {
        let video = videoInOutput
        guard video.width > 0, video.height > 0 else { return .zero }
        let output = annotation(view: rect)
        return CGRect(x: (output.minX - video.minX) / video.width,
                      y: (output.minY - video.minY) / video.height,
                      width: output.width / video.width,
                      height: output.height / video.height)
    }
}
