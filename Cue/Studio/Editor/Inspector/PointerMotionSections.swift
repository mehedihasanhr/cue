import SwiftUI
import TimelineKit

/// The arrow leaning into its travel — see `PointerSway`.
///
/// A section of its own rather than a toggle under Pointer, because it has a strength to go
/// with it and a condition to say out loud: it only acts on a pointer with a body to lean.
struct PointerSwaySection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var cursor: CursorStyle { model.timeline.cursor }

    var body: some View {
        let sway = cursor.sway
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Lean into movement", isOn: style.binding(\.cursor.sway.isEnabled, "Pointer Sway"))
                .help(note)
            InspectorSlider(model: model, "Strength", systemImage: "arrow.uturn.right",
                            value: style.binding(\.cursor.sway.strength, "Sway Strength"),
                            range: PointerSway.strengthRange,
                            defaultValue: style.factory(\.cursor.sway.strength),
                            format: { "\(Int(($0 * PointerSway.maximumAngle).rounded()))° at most" })
                .disabled(!sway.isEnabled)
            // Said in the panel, not only the tooltip: switched on with a dot, nothing
            // happens, and that looks like a fault.
            if sway.isEnabled, !hasBodyToLean {
                InspectorNote("The \(cursor.appearance.title) style has nothing to lean.")
            }
        }
        .disabled(!cursor.isVisible)
        .inspectorSection("Sway", systemImage: "wind")
    }

    private var hasBodyToLean: Bool {
        switch cursor.appearance {
        case .dot, .clicksOnly: false
        default: true
        }
    }

    private var note: String {
        switch cursor.appearance {
        case .dot, .clicksOnly:
            "The \(cursor.appearance.title) style has nothing to lean. Choose an arrow style to see it."
        default:
            "The arrow tilts a little the way it is travelling, like something being moved by a hand, and stands up again when it stops. An I-beam or a crosshair stays upright."
        }
    }
}

/// The pointer — and the camera — brought home over the last moments, for a video that is
/// played on a loop. See `PointerLoop`.
struct PointerLoopSection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var loop: PointerLoop { model.timeline.cursor.loop }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Loop the pointer position", isOn: style.binding(\.cursor.loop.isEnabled, "Loop Pointer"))
                .help(loop.isEnabled
                      ? "Over the last \(String(format: "%.1f", loop.duration)) seconds the pointer eases back to where it was on the first frame\(loop.bringsCameraBack ? ", and the zoom and pan with it" : ""), so a GIF or a looping video has no jump where it starts again."
                      : "For a GIF or a video that plays on a loop: the pointer ends where it started, so the loop has no seam.")
            Group {
                InspectorSlider(model: model, "Over", systemImage: "timer",
                                value: style.binding(\.cursor.loop.duration, "Loop Length"),
                                range: PointerLoop.durationRange,
                                defaultValue: style.factory(\.cursor.loop.duration),
                                format: { String(format: "last %.1fs", $0) })
                InspectorSwitch("Bring the camera back too",
                                isOn: style.binding(\.cursor.loop.bringsCameraBack, "Loop Camera"))
            }
            .disabled(!loop.isEnabled)
        }
        .disabled(!model.timeline.cursor.isVisible)
        .inspectorSection("Loop", systemImage: "repeat")
    }
}
