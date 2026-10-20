import SwiftUI
import TimelineKit

/// Dragging the camera bubble around the picture.
///
/// `WebcamSettings.position` has been in the model from the start and there has never been a
/// way to set it: four corners covered most cases and the fifth, `.custom`, could only be
/// reached by hand-editing a project file. Two normalised numbers in the inspector would
/// have been the cheap answer and the wrong one, for the reason `ZoomFramingOverlay` gives about
/// aiming a zoom — nobody knows where 0.38, 0.71 is, but everybody knows they want their
/// face out of the way of the sidebar.
///
/// The measurement is simpler than the zoom overlay's on purpose. A zoom's centre is
/// normalised to the *recording*, which sits inside the finished frame wherever the camera
/// put it, so aiming one has to go through `CanvasGeometry`'s video mapping. A bubble is
/// normalised to the **output**, because it is a fixture of the finished video rather than
/// something attached to the footage — so this is `CanvasGeometry.annotation(view:)`, the
/// same mapping an annotation uses, and for the same reason.
///
/// A drag lands as one undo entry. Without the interaction bracket, nudging the bubble
/// across the window would fill the undo stack with fifty steps that all look alike.
struct WebcamBubbleOverlay: View {
    let model: EditorModel
    /// Where the picture is, in this view's coordinates.
    let stage: CGRect

    @State private var isDragging = false
    /// Where the bubble's centre was when the drag began, in view coordinates.
    ///
    /// Kept so the bubble moves *with* the pointer rather than jumping its centre onto it:
    /// grabbing a large bubble near its edge and having it snap so the grab point is the
    /// middle is the small wrongness that makes a drag feel broken.
    @State private var grabbedCentre: CGPoint?

    private var geometry: CanvasGeometry {
        CanvasGeometry(stage: stage, scene: model.scene)
    }

    /// The bubble as the renderer placed it, in this view's coordinates. `nil` when the
    /// camera is off or there is nothing to draw — an undo can take it away while the tool
    /// is still on.
    private var bubble: CGRect? {
        guard let rect = model.webcamRect else { return nil }
        return geometry.view(annotation: rect)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let bubble {
                // Only the bubble takes the drag. A transparent full-stage catcher — which is
                // what the zoom overlay wants, because a click anywhere means "aim here" —
                // would mean a click on the far side of the picture teleported somebody's face
                // to the cursor, which is not what a click on a picture means.
                Color.clear
                    .frame(width: bubble.width, height: bubble.height)
                    .contentShape(Rectangle())
                    .offset(x: bubble.minX, y: bubble.minY)
                    .gesture(drag)

                outline(bubble)
            }
            hint
        }
        // Escape leaves the tool, as it does on the other overlays.
        .onExitCommand { model.tool = .frame }
    }

    /// A ring around the bubble, so it is obvious which thing is draggable.
    ///
    /// Drawn as a rectangle rather than following the bubble's own roundness: the handle is
    /// the *region* being moved, and a circle traced exactly around a circular bubble
    /// disappears into its own edge.
    private func outline(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(isDragging ? 0.95 : 0.7), lineWidth: 2)
            .frame(width: rect.width + 6, height: rect.height + 6)
            .shadow(color: .black.opacity(0.45), radius: 3)
            .offset(x: rect.minX - 3, y: rect.minY - 3)
            .allowsHitTesting(false)
            .animation(isDragging ? nil : .easeOut(duration: 0.15), value: rect)
    }

    @ViewBuilder
    private var hint: some View {
        Text(model.timeline.webcam.isEnabled
             ? "Drag the bubble to move it. Pick a corner in the panel to park it again."
             : "The camera is off. Turn it on in the panel to place the bubble.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var drag: some Gesture {
        // The window's coordinates: this gesture moves the very view it is attached to, so
        // its own local space would move under it. See `TimelineRegionRow.drag(_:grip:)`.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    grabbedCentre = bubble.map { CGPoint(x: $0.midX, y: $0.midY) }
                    model.document.beginInteraction("Move Camera")
                }
                // The translation from where it started, applied to where the bubble started
                // — not the pointer's absolute position. Measured against the remembered
                // centre rather than the live one, so the arithmetic cannot compound as the
                // preview re-renders under the drag.
                guard let start = grabbedCentre else { return }
                let centre = CGPoint(x: start.x + value.translation.width,
                                     y: start.y + value.translation.height)
                model.moveWebcam(to: geometry.annotation(view: CGRect(origin: centre, size: .zero)).origin)
            }
            .onEnded { _ in
                isDragging = false
                grabbedCentre = nil
                model.finishInteraction()
            }
    }
}
