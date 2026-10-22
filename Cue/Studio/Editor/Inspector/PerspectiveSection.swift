import SwiftUI
import TimelineKit

/// The picture turned in space: a preset on the heading, the three angles, the depth
/// shadow, and whether zooming in turns it square-on.
///
/// The preset is on the heading, like the shape is on Shape's: it is the one choice most
/// people make here, and the sliders under it are for the ones who want something between.
struct PerspectiveSection: View {
    let model: EditorModel

    /// What the heading's pop-up shows: a preset, or Custom once the sliders have moved
    /// off every preset.
    private enum Choice: Hashable {
        case preset(FramePerspective.Preset)
        case custom

        var title: String {
            switch self {
            case .preset(let preset): preset.title
            case .custom: "Custom"
            }
        }
    }

    private var perspective: FramePerspective { model.perspective }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSlider(model: model, "Turn", systemImage: "rotate.3d",
                            value: angle(\.turn, "Turn"), range: FramePerspective.turnRange,
                            format: Self.degrees)
            InspectorSlider(model: model, "Lean", systemImage: "rotate.3d",
                            value: angle(\.lean, "Lean"), range: FramePerspective.leanRange,
                            format: Self.degrees)
            InspectorSlider(model: model, "Rotate", systemImage: "rotate.right",
                            value: angle(\.rotation, "Rotate"), range: FramePerspective.rotationRange,
                            format: Self.degrees)
            InspectorSlider(model: model, "Depth shadow", systemImage: "shadow",
                            value: angle(\.depthShadow, "Depth Shadow"), range: 0...1)
                .disabled(perspective.isFlat || model.timeline.style.shadowOpacity <= 0)
                .help(perspective.isFlat
                      ? "The picture is flat. Choose a preset or move Turn or Lean to tilt it."
                      : model.timeline.style.shadowOpacity <= 0
                        ? "No depth shadow while Shadow is off."
                        : "The shadow the tilted picture casts")
            InspectorSwitch("Straighten while zoomed in", isOn: Binding(
                get: { perspective.straightensWhenZoomed },
                set: { model.setStraightensWhenZoomed($0) }
            ))
            .help("Turn the picture square-on while the camera is zoomed in, and back as it zooms out")
            .disabled(perspective.isFlat)
        }
        .inspectorSection("Perspective", systemImage: "rotate.3d") {
            InspectorPicker(selection: choice, options: choices) { $0.title }
                .accessibilityLabel("Perspective preset")
                .help("The pointer, clicks and annotations turn with the picture. Captions, keys and the camera stay upright.")
        }
    }

    private var choices: [Choice] {
        let presets = FramePerspective.Preset.allCases.map(Choice.preset)
        return perspective.preset == nil ? presets + [.custom] : presets
    }

    private var choice: Binding<Choice> {
        Binding {
            perspective.preset.map(Choice.preset) ?? .custom
        } set: { chosen in
            guard case .preset(let preset) = chosen else { return }
            model.applyPerspectivePreset(preset)
        }
    }

    /// One of the numbers, set through the whole perspective so the command holds it to
    /// its range.
    private func angle(_ path: WritableKeyPath<FramePerspective, Double>, _ name: String) -> Binding<Double> {
        Binding {
            perspective[keyPath: path]
        } set: { value in
            var changed = perspective
            changed[keyPath: path] = value
            model.setPerspective(changed, name: name)
        }
    }

    private static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }
}
