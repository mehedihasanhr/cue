import SwiftUI
import TimelineKit

/// What the recording sits on and inside: background, blur, and the shape of the frame.
///
/// Everything here is applied at render time, so every one of them is instant and
/// reversible — which is why they are sliders rather than a "render" button.
struct FrameInspector: View {
    let model: EditorModel
    let state: InspectorState

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        // Nothing of its own between the sections: each one already carries its padding
        // and the rule that closes it. Adding a stack gap on top of that put 26 points
        // under every rule and none above it, which is the lopsided gap this column had.
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            BackgroundPicker(model: model, state: state)

            shape
            if model.timeline.style.crop != nil { crop }
        }
    }

    // MARK: - Shape

    /// The frame's proportions.
    ///
    /// The aspect is on the heading, where "Shape: Shape" used to be — the section is
    /// already called Shape, so the field's own label was the word said twice.
    ///
    /// No Reset: four sliders that each show their value and move on a drag are their
    /// own undo, and ⌘Z puts back anything they got wrong.
    private var shape: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorSlider(model: model, "Padding", systemImage: "square.dashed.inset.filled",
                                value: style.binding(\.style.padding, "Padding"), range: 0...0.2)
                InspectorSlider(model: model, "Corners", systemImage: "rectangle.roundedtop",
                                value: style.binding(\.style.cornerRadius, "Corners"), range: 0...0.08)
                InspectorSlider(model: model, "Shadow", systemImage: "shadow",
                                value: style.binding(\.style.shadowOpacity, "Shadow"), range: 0...1)
                InspectorSlider(model: model, "Softness", systemImage: "aqi.medium",
                                value: style.binding(\.style.shadowRadius, "Shadow Softness"), range: 0...0.08)
            }
        }
        .inspectorSection("Shape", systemImage: "square.on.square") {
            InspectorPicker(selection: style.binding(\.style.aspect, "Shape"),
                            options: AspectPreset.allCases) { $0.displayName }
        }
    }

    // MARK: - Crop

    /// Shown only while there is a crop, and showing the numbers, because area is
    /// preserved against the *cropped* picture: cropping hard means a smaller export,
    /// and that is worth saying out loud rather than discovering later.
    private var crop: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorRow(title: "Crop",
                         value: "\(Int(model.croppedVideoSize.width)) × \(Int(model.croppedVideoSize.height))")
            InspectorRow(title: "Output",
                         value: "\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
            Button(model.tool == .crop ? "Done" : "Adjust…") {
                model.tool = model.tool == .crop ? .frame : .crop
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .inspectorSection("Crop", systemImage: "crop") {
            SectionButton(title: "Reset") { model.setCrop(nil) }
                .help("Show the whole recording again")
        }
    }
}
