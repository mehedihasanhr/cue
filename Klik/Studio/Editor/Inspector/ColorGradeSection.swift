import SwiftUI
import TimelineKit

/// Colour correction for the recording: a preset on the heading, five sliders, and a
/// `.cube` table with how much of it to use.
struct ColorGradeSection: View {
    let model: EditorModel

    private enum Choice: Hashable {
        case preset(ColorGrade.Preset)
        case custom

        var title: String {
            switch self {
            case .preset(let preset): preset.title
            case .custom: "Custom"
            }
        }
    }

    private var grade: ColorGrade { model.colorGrade }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            slider("Brightness", \.brightness, systemImage: "sun.max")
            slider("Contrast", \.contrast, systemImage: "circle.lefthalf.filled")
            slider("Saturation", \.saturation, systemImage: "drop")
            slider("Temperature", \.temperature, systemImage: "thermometer.medium")
            slider("Tint", \.tint, systemImage: "paintpalette")
            lut
        }
        .inspectorSection("Colour", systemImage: "camera.filters") {
            InspectorPicker(selection: choice, options: choices) { $0.title }
                .accessibilityLabel("Colour preset")
                .help("Changes the recording only — not the background, the window, the camera or anything drawn on top.")
        }
    }

    // MARK: - The table

    @ViewBuilder
    private var lut: some View {
        if let table = grade.lut {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorRow(title: "LUT", value: table.name)
                HStack(spacing: 8) {
                    Button("Replace…") { model.loadLUT() }
                    Button("Remove") { model.removeLUT() }
                }
                .buttonStyle(.studio(.secondary, size: .small))
                slider("Intensity", \.lutIntensity, range: 0...1, systemImage: "slider.horizontal.below.rectangle")
            }
        } else {
            InspectorRow("LUT") {
                Button("Load…") { model.loadLUT() }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .help("A 3D .cube file. It is copied into the recording.")
            }
        }
    }

    // MARK: - Controls

    private var choices: [Choice] {
        let presets = ColorGrade.Preset.allCases.map(Choice.preset)
        return grade.preset == nil ? presets + [.custom] : presets
    }

    private var choice: Binding<Choice> {
        Binding {
            grade.preset.map(Choice.preset) ?? .custom
        } set: { chosen in
            guard case .preset(let preset) = chosen else { return }
            model.applyColorPreset(preset)
        }
    }

    /// −1…1 read as −100…+100, with nought as it was recorded.
    private func slider(_ title: String, _ path: WritableKeyPath<ColorGrade, Double>,
                        range: ClosedRange<Double> = ColorGrade.range, systemImage: String) -> some View {
        InspectorSlider(model: model, title, systemImage: systemImage,
                        value: Binding {
                            grade[keyPath: path]
                        } set: { value in
                            var changed = grade
                            changed[keyPath: path] = value
                            model.setColorGrade(changed, name: title)
                        },
                        range: range,
                        format: range.lowerBound < 0
                            ? { value in
                                let whole = Int((value * 100).rounded())
                                return whole > 0 ? "+\(whole)" : "\(whole)"
                            }
                            : nil)
    }
}
