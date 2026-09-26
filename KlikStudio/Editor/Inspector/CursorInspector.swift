import SwiftUI
import TimelineKit

/// How the pointer is drawn.
///
/// None of this would be possible from a recording with the cursor burned in, which is
/// why the recorder writes cursor positions as data and leaves the video clean.
struct CursorInspector: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Show pointer", isOn: style.binding(\.cursor.isVisible, "Pointer"))

            InspectorSlider(model: model, "Size", systemImage: "arrow.up.left.and.arrow.down.right",
                            value: style.binding(\.cursor.scale, "Pointer Size"), range: 0.5...3,
                            format: { String(format: "%.1f×", $0) })
            InspectorSlider(model: model, "Smoothing", systemImage: "scribble",
                            value: style.binding(\.cursor.smoothing, "Smoothing"), range: 0...1)

            Toggle("Click effect", isOn: style.binding(\.cursor.clickEffect, "Click Effect"))
            Toggle("Motion blur", isOn: style.binding(\.cursor.motionBlur, "Motion Blur"))
            Toggle("Keep size while zoomed",
                   isOn: style.binding(\.cursor.sizeIsIndependentOfZoom, "Pointer Zoom"))
        }
        .font(.system(size: 12))
        .disabled(!model.timeline.cursor.isVisible && false)
        .inspectorSection("Pointer", systemImage: "cursorarrow.rays")
    }
}
