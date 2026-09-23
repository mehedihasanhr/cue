import SwiftUI
import TimelineKit

/// What the recording sits on and inside: background, blur, and the shape of the frame.
///
/// Everything here is applied at render time, so every one of them is instant and
/// reversible — which is why they are sliders rather than a "render" button.
struct FrameInspector: View {
    let model: EditorModel
    let state: InspectorState
    @Environment(StudioSettings.self) private var settings

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BackgroundPicker(model: model, state: state)

            InspectorSlider(model: model, "Amount", systemImage: "circle.lefthalf.filled",
                            value: style.binding(\.style.backgroundBlur, "Background Blur"),
                            range: 0...0.04)
                .inspectorSection("Background blur", systemImage: "drop")

            shape
            if model.timeline.style.crop != nil { crop }
        }
    }

    // MARK: - Shape

    private var shape: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Shape", selection: style.binding(\.style.aspect, "Shape")) {
                ForEach(AspectPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .font(.system(size: 12))

            InspectorSlider(model: model, "Padding", systemImage: "square.dashed.inset.filled",
                            value: style.binding(\.style.padding, "Padding"), range: 0...0.2)
            InspectorSlider(model: model, "Corners", systemImage: "rectangle.roundedtop",
                            value: style.binding(\.style.cornerRadius, "Corners"), range: 0...0.08)
            InspectorSlider(model: model, "Shadow", systemImage: "shadow",
                            value: style.binding(\.style.shadowOpacity, "Shadow"), range: 0...1)
            InspectorSlider(model: model, "Softness", systemImage: "aqi.medium",
                            value: style.binding(\.style.shadowRadius, "Shadow Softness"), range: 0...0.08)

            HStack {
                Spacer()
                Button("Reset") {
                    // Back to *your* defaults, not to a table of constants: what a new
                    // project looks like and what Reset gives you are one idea, and two
                    // sets of numbers would drift apart within a release.
                    let defaults = settings
                    model.apply(Commands.Restyle("Reset Shape") { timeline in
                        defaults.resetShape(&timeline)
                    })
                }
                .controlSize(.small)
                .help("Put padding, corners and shadow back to your defaults")
            }
        }
        .inspectorSection("Shape", systemImage: "square.on.square")
    }

    // MARK: - Crop

    /// Shown only while there is a crop, and showing the numbers, because area is
    /// preserved against the *cropped* picture: cropping hard means a smaller export,
    /// and that is worth saying out loud rather than discovering later.
    private var crop: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Crop") {
                Text("\(Int(model.croppedVideoSize.width)) × \(Int(model.croppedVideoSize.height))")
                    .monospacedDigit()
            }
            LabeledContent("Output") {
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                    .monospacedDigit()
            }
            HStack {
                Button(model.tool == .crop ? "Done" : "Adjust…") {
                    model.tool = model.tool == .crop ? .frame : .crop
                }
                Spacer()
                Button("Reset") { model.setCrop(nil) }
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .inspectorSection("Crop", systemImage: "crop")
    }
}
