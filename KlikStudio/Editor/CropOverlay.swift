import AppKit
import CoreMedia
import SwiftUI
import TimelineKit

/// Choosing the part of the recording that makes it into the frame.
///
/// Works because crop mode renders the *source* frame rather than the composite: the
/// preview is one aspect-fit of the recording, so a point on screen maps to a point in
/// the footage with no padding, corner radius or camera in the way.
struct CropOverlay: View {
    let model: EditorModel
    /// Where the picture is, in this view's coordinates.
    let stage: CGRect

    @State private var origin: CGRect?
    @State private var isDragging = false

    private var crop: CGRect {
        model.timeline.style.crop?.rect ?? CropRect.full.rect
    }

    /// The crop in view coordinates.
    private var box: CGRect {
        CGRect(x: stage.minX + crop.minX * stage.width,
               y: stage.minY + crop.minY * stage.height,
               width: crop.width * stage.width,
               height: crop.height * stage.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimming
            border
            if isDragging { thirds }
            ForEach(Handle.allCases) { handle in
                self.handle(handle)
            }
        }
        .contentShape(Rectangle())
        .gesture(bodyDrag)
        .onTapGesture {
            // ⌥-click is the fastest way back to the whole frame, and it is the one
            // gesture that cannot be mistaken for starting a new crop.
            if NSEvent.modifierFlags.contains(.option) { model.setCrop(nil) }
        }
        .onExitCommand { model.tool = .frame }
    }

    // MARK: - Chrome

    /// Everything outside the crop, darkened. One path with an even-odd fill rather than
    /// four rectangles or a mask, so the hole is exact at every size.
    private var dimming: some View {
        Path { path in
            path.addRect(stage)
            path.addRect(box)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var border: some View {
        Rectangle()
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
            .allowsHitTesting(false)
    }

    private var thirds: some View {
        Path { path in
            for step in 1...2 {
                let x = box.minX + box.width * Double(step) / 3
                let y = box.minY + box.height * Double(step) / 3
                path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    // MARK: - Handles

    private enum Handle: String, CaseIterable, Identifiable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var id: String { rawValue }

        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: true
            default: false
            }
        }

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        var cursor: NSCursor {
            switch self {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            default: .crosshair
            }
        }
    }

    private func position(of handle: Handle) -> CGPoint {
        CGPoint(x: handle.movesLeft ? box.minX : (handle.movesRight ? box.maxX : box.midX),
                y: handle.movesTop ? box.minY : (handle.movesBottom ? box.maxY : box.midY))
    }

    private func handle(_ handle: Handle) -> some View {
        let point = position(of: handle)
        let size: CGSize = handle.isCorner
            ? CGSize(width: 18, height: 18)
            : (handle.movesLeft || handle.movesRight ? CGSize(width: 4, height: 28) : CGSize(width: 28, height: 4))

        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.4), radius: 2)
            // A grab ring wider than the drawn handle: eighteen points of white is a
            // hairline to aim at, and the slop is what makes it feel solid.
            .contentShape(Rectangle().inset(by: -10))
            .position(point)
            .onHover { inside in
                if inside { handle.cursor.push() } else { NSCursor.pop() }
            }
            .gesture(drag(handle))
    }

    // MARK: - Gestures

    private func normalised(_ point: CGPoint) -> CGPoint {
        guard stage.width > 0, stage.height > 0 else { return .zero }
        return CGPoint(x: (point.x - stage.minX) / stage.width,
                       y: (point.y - stage.minY) / stage.height)
    }

    private func drag(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = begin()
                let point = normalised(value.location)
                var rect = start

                if handle.movesLeft { rect = resized(rect, minX: point.x) }
                if handle.movesRight { rect = resized(rect, maxX: point.x) }
                if handle.movesTop { rect = resized(rect, minY: point.y) }
                if handle.movesBottom { rect = resized(rect, maxY: point.y) }

                if handle.isCorner, NSEvent.modifierFlags.contains(.shift) {
                    rect = lockingAspect(of: start, to: rect, handle: handle)
                }
                model.setCrop(CropRect(rect: rect))
            }
            .onEnded { _ in end() }
    }

    private var bodyDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = begin()
                let from = normalised(value.startLocation)
                let to = normalised(value.location)
                var rect = start
                rect.origin.x = min(1 - rect.width, max(0, start.minX + to.x - from.x))
                rect.origin.y = min(1 - rect.height, max(0, start.minY + to.y - from.y))
                model.setCrop(CropRect(rect: rect))
            }
            .onEnded { _ in end() }
    }

    /// Opens one undo entry for the whole gesture, however many commands it applies.
    private func begin() -> CGRect {
        if let origin { return origin }
        let rect = crop
        origin = rect
        isDragging = true
        model.document.beginInteraction("Crop")
        return rect
    }

    private func end() {
        origin = nil
        isDragging = false
        model.document.endInteraction()
    }

    // MARK: - Geometry

    private func resized(_ rect: CGRect, minX: Double) -> CGRect {
        let x = min(rect.maxX - CropRect.minimumSide, max(0, minX))
        return CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height)
    }

    private func resized(_ rect: CGRect, maxX: Double) -> CGRect {
        let x = max(rect.minX + CropRect.minimumSide, min(1, maxX))
        return CGRect(x: rect.minX, y: rect.minY, width: x - rect.minX, height: rect.height)
    }

    private func resized(_ rect: CGRect, minY: Double) -> CGRect {
        let y = min(rect.maxY - CropRect.minimumSide, max(0, minY))
        return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.maxY - y)
    }

    private func resized(_ rect: CGRect, maxY: Double) -> CGRect {
        let y = max(rect.minY + CropRect.minimumSide, min(1, maxY))
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: y - rect.minY)
    }

    /// Shift keeps the crop's current shape, growing from the corner opposite the one
    /// being dragged.
    private func lockingAspect(of original: CGRect, to proposed: CGRect, handle: Handle) -> CGRect {
        guard original.height > 0 else { return proposed }
        let ratio = original.width / original.height
        var rect = proposed
        // Whichever edge moved further decides; the other follows it.
        if proposed.width / max(0.0001, proposed.height) > ratio {
            rect.size.height = proposed.width / ratio
        } else {
            rect.size.width = proposed.height * ratio
        }
        if handle.movesLeft { rect.origin.x = original.maxX - rect.width }
        if handle.movesTop { rect.origin.y = original.maxY - rect.height }
        return rect
    }
}
