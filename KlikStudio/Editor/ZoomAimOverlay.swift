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

    private let handle: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A catcher under the box: a drag on empty picture frames a new area from
            // scratch, the way the blur tool draws a new rectangle.
            Color.clear
                .contentShape(Rectangle())
                .gesture(frameFromScratch)

            if let zoom {
                let rect = geometry.view(blur: model.zoomArea(of: zoom))
                shade(around: rect)
                box(rect, zoom: zoom)
            }
            hint
        }
        // Escape leaves the tool, as it does on the other canvas tools. The zoom stays
        // selected, so the inspector is still showing what was just framed.
        .onExitCommand { model.tool = .frame }
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
                .strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
                .background(Color.accentColor.opacity(0.06))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .contentShape(Rectangle())
                .gesture(move(from: zoom))
                .onHover { NSCursor.openHand.set(); if !$0 { NSCursor.arrow.set() } }

            // The scale, on the box, because it is the number the box is setting.
            Text("\(zoom.scale, format: .number.precision(.fractionLength(0...1)))×")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .offset(x: rect.minX + 6, y: rect.minY + 6)
                .allowsHitTesting(false)

            ForEach(Corner.allCases, id: \.self) { corner in
                grip(corner, of: rect, zoom: zoom)
            }
        }
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

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
            case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private func grip(_ corner: Corner, of rect: CGRect, zoom: ZoomRegion) -> some View {
        let point = corner.point(in: rect)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.white)
            .frame(width: handle, height: handle)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(x: point.x - handle / 2, y: point.y - handle / 2)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(resize(corner, from: zoom))
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
                model.setZoomArea(zoom.id,
                                  to: start.offsetBy(dx: delta.width, dy: delta.height),
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
                // The side follows the horizontal drag: a zoom is one number, so the box
                // stays the picture's shape and the width is the half the user is steering.
                let side = max(0.05, anchor.x ? start.width - delta.width : start.width + delta.width)
                let x = anchor.x ? start.maxX - side : start.minX
                let y = anchor.y ? start.maxY - side : start.minY
                model.setZoomArea(zoom.id,
                                  to: CGRect(x: x, y: y, width: side, height: side),
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
                let side = max(0.05, abs(b.x - a.x))
                model.setZoomArea(zoom.id,
                                  to: CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                             width: side, height: side),
                                  name: "Frame Zoom")
            }
            .onEnded { _ in end() }
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
    }
}
