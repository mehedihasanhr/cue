import CoreMedia
import SwiftUI
import TimelineKit

/// Pointing a zoom at something, on the picture rather than at two numbers.
///
/// `ZoomRegion.center` has always been in the model and there has never been a way to set
/// it: a zoom that follows the cursor works its own centre out every frame, and a fixed one
/// sat wherever it was put — the middle, for anything placed by hand. Two normalised
/// coordinates in the inspector would have been the cheap answer and the wrong one, because
/// nobody knows where 0.38, 0.71 is. What they know is which window they want in shot.
///
/// The crosshair is drawn through `CanvasGeometry`, the same mapping the blur overlay uses,
/// and for the same reason: a zoom's centre is normalised to the *recording*, so it has to
/// be measured against where the recording landed inside the finished frame — which, once
/// this very zoom is in force, is a rect larger than the picture you can see. Deriving that
/// layout a second time here is how the handles end up somewhere the renderer is not.
///
/// A click aims; a drag aims continuously and lands as one undo entry, which is what
/// `beginInteraction` is for — otherwise nudging the crosshair across the window would fill
/// the undo stack with fifty identical-looking steps.
struct ZoomAimOverlay: View {
    let model: EditorModel
    /// Where the picture is, in this view's coordinates.
    let stage: CGRect

    @State private var isDragging = false

    private var geometry: CanvasGeometry {
        CanvasGeometry(stage: stage, scene: model.scene)
    }

    /// The zoom being aimed. The overlay is only ever reached from one, but a delete or an
    /// undo can take it away while the tool is still on.
    private var zoom: ZoomRegion? {
        guard case .zoom(let id) = model.selection else { return nil }
        return model.timeline.zooms.first { $0.id == id }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(aim)
                .onTapGesture { place(at: $0) }

            if let zoom {
                crosshair(at: point(of: zoom))
            }
            hint
        }
        // Escape leaves the tool, as it does on the other canvas tools. The zoom stays
        // selected, so the inspector is still showing what was just aimed.
        .onExitCommand { model.tool = .frame }
    }

    // MARK: - The crosshair

    /// Where the zoom's centre falls on screen.
    ///
    /// Through the blur mapping on a rectangle with no size: a centre and a blur's origin are
    /// the same kind of point — a fraction of the recording — and one tested conversion is
    /// better than a second one that agrees with it on a good day.
    private func point(of zoom: ZoomRegion) -> CGPoint {
        geometry.view(blur: CGRect(origin: zoom.center, size: .zero)).origin
    }

    private func crosshair(at point: CGPoint) -> some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                .background(Circle().fill(Color.accentColor.opacity(0.25)))
                .frame(width: 26, height: 26)
            // Arms past the ring, so the crosshair reads as an aim rather than as a dot on
            // the picture — over a busy frame a ring alone disappears.
            Rectangle().fill(.white.opacity(0.9)).frame(width: 1.5, height: 44)
            Rectangle().fill(.white.opacity(0.9)).frame(width: 44, height: 1.5)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 3)
        .frame(width: 44, height: 44)
        .offset(x: point.x - 22, y: point.y - 22)
        .allowsHitTesting(false)
        .animation(isDragging ? nil : .easeOut(duration: 0.15), value: point)
    }

    /// What this tool is for, and — when it is — why the picture is not obeying it.
    @ViewBuilder
    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(zoom == nil
                 ? "Pick a zoom on the timeline to aim it"
                 : "Click the picture to say what this zoom should look at")
            if let zoom, zoom.followsCursor {
                Text("It follows the pointer at the moment — aiming it will stop that.")
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

    // MARK: - Aiming

    private var aim: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    model.document.beginInteraction("Aim Zoom")
                }
                place(at: value.location)
            }
            .onEnded { _ in
                isDragging = false
                model.document.endInteraction()
            }
    }

    private func place(at location: CGPoint) {
        guard let zoom else { return }
        model.aimZoom(zoom.id, at: geometry.blur(view: CGRect(origin: location, size: .zero)).origin)
    }
}
