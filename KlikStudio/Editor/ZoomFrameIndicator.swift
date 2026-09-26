import RenderKit
import SwiftUI
import TimelineKit

/// Where the selected zoom is pointed, drawn on the picture.
///
/// Selecting a zoom on the timeline used to tell you everything about it except the one
/// thing a zoom *is*: which part of the screen it looks at. That lived behind the Aim
/// tool, which flattens the preview and is a mode you have to decide to enter — so the
/// ordinary act of clicking a chip to see what it does showed a panel of numbers and an
/// unchanged picture.
///
/// This is the answer to "what is this one?", not a way to change it. Aiming is still a
/// tool, and still the thing that flattens the preview so a framing box can be dragged
/// against the recording rather than against the zoom's own output. Clicking this goes
/// there.
///
/// **It fades out as the camera arrives.** The box is drawn in the frame's coordinates
/// and then mapped through whatever the camera is doing at the playhead, so while the
/// playhead is outside the zoom it shows exactly where the shot will go, and as the zoom
/// comes in it grows towards the edges of the frame — because by then the frame *is* the
/// shot. A border sitting on the edge of the picture saying nothing would be worse than
/// no border, so it leaves as it becomes true.
struct ZoomFrameIndicator: View {
    let model: EditorModel
    /// Where the picture is, in this view's coordinates.
    let stage: CGRect

    private var zoom: ZoomRegion? {
        guard case .zoom(let id) = model.selection else { return nil }
        return model.timeline.zooms.first { $0.id == id }
    }

    var body: some View {
        if let zoom, zoom.isEnabled {
            let fade = opacity(of: zoom)
            if let rect = framed(zoom), fade > 0.05 {
                ZStack(alignment: .topLeading) {
                    shade(around: rect)
                    Rectangle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .overlay(alignment: .topLeading) { badge(zoom, rect: rect) }
                }
                .opacity(fade)
                .contentShape(Rectangle())
                // One click into the tool that can change it, from the thing that shows it.
                .onTapGesture { model.aimSelectedZoom() }
                .help("This zoom's shot. Click to aim it on the picture")
            } else {
                // The camera has arrived, so the shot *is* the picture and a box around it
                // would be a border saying nothing. Selecting a chip has to answer
                // something either way, so this says which zoom you are inside and offers
                // the one thing you would want next.
                arrived(zoom)
            }
        }
    }

    /// What to show when the picture already *is* the zoom.
    private func arrived(_ zoom: ZoomRegion) -> some View {
        Button {
            model.aimSelectedZoom()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dot.scope").font(.system(size: 10, weight: .semibold))
                Text("You are inside this zoom · \(zoom.scale, format: .number.precision(.fractionLength(0...1)))×")
                Text("Aim it").foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .help("Move the playhead outside this zoom to see where it points, or aim it on the picture")
    }

    // MARK: - Where it lands

    /// The zoom's shot, in view coordinates, after the camera at the playhead has had its
    /// say.
    ///
    /// Two transforms, and they have to be in this order. The zoom's own area is a square
    /// of the *whole* frame; what is on screen is whatever square the camera is currently
    /// showing. So the first is mapped into the second, and only then into points.
    private func framed(_ zoom: ZoomRegion) -> CGRect? {
        guard stage.width > 1, stage.height > 1, let scene = model.scene else { return nil }
        let area = model.zoomArea(of: zoom)

        // What the camera is showing right now, as a square of the frame. No scene yet
        // means no camera, which the guard above reads as nothing to draw.
        let half = 0.5 / max(1, scene.zoom)
        let shown = CGRect(x: scene.zoomCenter.x - half,
                           y: scene.zoomCenter.y - half,
                           width: half * 2, height: half * 2)
        guard shown.width > 0, shown.height > 0 else { return nil }

        let u = (area.minX - shown.minX) / shown.width
        let v = (area.minY - shown.minY) / shown.height
        return CGRect(x: stage.minX + u * stage.width,
                      y: stage.minY + v * stage.height,
                      width: area.width / shown.width * stage.width,
                      height: area.height / shown.height * stage.height)
    }

    /// Full while the camera is out, gone by the time it has arrived.
    private func opacity(of zoom: ZoomRegion) -> Double {
        guard zoom.scale > 1, let scene = model.scene else { return 0 }
        let progress = (scene.zoom - 1) / (zoom.scale - 1)
        return 1 - min(1, max(0, progress))
    }

    // MARK: - Chrome

    /// Everything outside the shot, dimmed a little — enough to read the box as a framing
    /// rather than as a rectangle lying on the picture, and not so much that the part of
    /// the recording being framed *out* becomes unreadable. This is not the aiming tool:
    /// the user is still looking at the whole picture.
    private func shade(around rect: CGRect) -> some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(rect)
            context.fill(path, with: .color(.black.opacity(0.22)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    /// What it is, on the box. The scale because that is the number the box stands for,
    /// and the pointer glyph because a zoom that follows the pointer will not stay here —
    /// which is the one thing about the drawing that would otherwise be a lie.
    private func badge(_ zoom: ZoomRegion, rect: CGRect) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 9, weight: .semibold))
            Text("\(zoom.scale, format: .number.precision(.fractionLength(0...1)))×")
            if zoom.followsCursor {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.85)
                    .accessibilityLabel("Follows the pointer")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: Capsule())
        .fixedSize()
        .padding(6)
        .allowsHitTesting(false)
        .opacity(rect.width > 70 ? 1 : 0)
    }
}
