import AppKit
import BackgroundKit
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
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                Toggle("Show pointer", isOn: style.binding(\.cursor.isVisible, "Pointer"))

                InspectorSlider(model: model, "Size", systemImage: "arrow.up.left.and.arrow.down.right",
                                value: style.binding(\.cursor.scale, "Pointer Size"), range: 0.5...3,
                                format: { String(format: "%.1f×", $0) })
                InspectorSlider(model: model, "Smoothing", systemImage: "scribble",
                                value: style.binding(\.cursor.smoothing, "Smoothing"), range: 0...1)

                Toggle("Motion blur", isOn: style.binding(\.cursor.motionBlur, "Motion Blur"))
                Toggle("Keep size while zoomed",
                       isOn: style.binding(\.cursor.sizeIsIndependentOfZoom, "Pointer Zoom"))
            }
            .font(.system(size: 12))
            .disabled(!model.timeline.cursor.isVisible && false)
            .inspectorSection("Pointer", systemImage: "cursorarrow.rays")

            clicks
            overTime
        }
    }

    /// What a click looks like.
    ///
    /// Its own section rather than two more toggles in the list above, because a screen
    /// recording is watched without sound and this is the only thing in the whole editor
    /// that says a click happened. Two settings, and they are not the same one: the swell
    /// says *the pointer* did something, the ring says *this spot* was clicked.
    @ViewBuilder
    private var clicks: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Mark where clicks happen", isOn: style.binding(\.cursor.clickHighlight, "Click Marks"))
            InspectorSlider(model: model, "Size", systemImage: "circle.dashed",
                            value: style.binding(\.cursor.clickSize, "Click Size"),
                            range: 0.03...0.16)
                .disabled(!model.timeline.cursor.clickHighlight)
            ColorPicker("Colour", selection: clickColour, supportsOpacity: false)
                .disabled(!model.timeline.cursor.clickHighlight)
            Toggle("Pointer swells on click", isOn: style.binding(\.cursor.clickEffect, "Click Effect"))
            Text("A ring spreads from the spot that was clicked. Right-clicks get a second ring inside it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .disabled(!model.timeline.cursor.isVisible)
        .inspectorSection("Clicks", systemImage: "cursorarrow.click")
    }

    private var clickColour: Binding<Color> {
        Binding {
            Color(model.timeline.cursor.clickColor.rgba.nsColor)
        } set: { colour in
            style.set(\.cursor.clickColor, to: RGBA(NSColor(colour)).colorValue, "Click Colour")
        }
    }

    /// The stretch under the playhead, or the offer to make one.
    ///
    /// Here as well as under a timeline selection, because this panel is where someone
    /// wondering "can I hide the pointer just for this bit?" will already be looking, and a
    /// panel about the pointer that cannot answer that sends them hunting through menus.
    @ViewBuilder
    private var overTime: some View {
        if case .cursorRegion(let id) = model.selection {
            CursorRegionInspector(model: model, id: id)
        } else if let region = model.cursorRegionAtPlayhead {
            CursorRegionInspector(model: model, id: region.id)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("The settings above are for the whole recording. A stretch can override them — hidden while a face is on screen, calmed through one bad flick, held still while something is being read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Hide Pointer over Selection") { model.hidePointerOverSelection() }
                    .controlSize(.small)
            }
            .inspectorSection("Pointer over time", systemImage: "cursorarrow.slash")
        }
    }
}
