import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// One mask, selected: what kind it is, and the one or two numbers that kind has.
///
/// The kind is a pop-up rather than a row of segments for the reason `InspectorTabs`
/// gives: four titles side by side ask for more width than the settings column has.
struct MaskInspector: View {
    let model: EditorModel
    let id: UUID

    @State private var coalescer = InteractionCoalescer()

    private var mask: BlurRegion? { model.timeline.blurs.first { $0.id == id } }

    var body: some View {
        if let mask {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                switch mask.style {
                case .gaussian, .pixelate:
                    InspectorSlider(model: model, "Strength", systemImage: "drop",
                                    value: number(\.radius, "Mask Strength"), range: 4...80)
                case .cover:
                    InspectorRow("Colour") {
                        InspectorColorWell(title: "Cover colour", selection: colour, supportsOpacity: true)
                    }
                case .spotlight:
                    InspectorSlider(model: model, "Dimming", systemImage: "circle.lefthalf.filled",
                                    value: number(\.dimming, "Dimming"), range: 0...1)
                    InspectorSlider(model: model, "Edge softness", systemImage: "aqi.medium",
                                    value: number(\.softness, "Edge Softness"), range: 0...0.08)
                }

                InspectorSlider(model: model, "Corners", systemImage: "rectangle.roundedtop",
                                value: number(\.cornerRadius, "Mask Corners"), range: 0...0.5)

                MaskFollowControls(model: model, mask: mask)
            }
            .inspectorSection("Mask", systemImage: mask.style.symbol) {
                // What the kind does is the pop-up's tooltip: the sentence used to open
                // the panel, above the one or two controls it was describing.
                InspectorPicker(selection: kind, options: BlurRegion.Style.allCases, title: \.title)
                    .help(mask.style.hint)
            }
        }
    }

    private var kind: Binding<BlurRegion.Style> {
        Binding {
            mask?.style ?? .gaussian
        } set: { style in
            model.restyleMask(id, "Mask Kind") { $0.style = style }
        }
    }

    private func number(_ path: WritableKeyPath<BlurRegion, Double> & Sendable, _ name: String) -> Binding<Double> {
        Binding {
            mask?[keyPath: path] ?? 0
        } set: { value in
            model.restyleMask(id, name) { $0[keyPath: path] = value }
        }
    }

    /// The one control with no "editing ended" of its own — see `InteractionCoalescer`.
    private var colour: Binding<Color> {
        Binding {
            Color((mask?.color ?? .black).rgba.nsColor)
        } set: { colour in
            let value = RGBA(NSColor(colour)).colorValue
            coalescer.touch("Cover Colour", model: model)
            model.restyleMask(id, "Cover Colour") { $0.color = value }
        }
    }
}

/// What the Mask tool offers while nothing is selected: which kind the next drag makes,
/// and a way to add one without drawing.
struct MaskToolControls: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow("Kind") {
                InspectorPicker(selection: Binding(get: { model.newMaskStyle },
                                                   set: { model.newMaskStyle = $0 }),
                                options: BlurRegion.Style.allCases, title: \.title)
            }
            .help(model.newMaskStyle.hint)
            Button {
                model.addMask(model.newMaskStyle)
            } label: {
                Label("Add \(model.newMaskStyle.title) at Playhead", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Put one in the middle of the picture, to drag where it belongs")
        }
    }
}

extension BlurRegion.Style {
    /// The glyph for a kind, where the panel's heading wants one.
    var symbol: String {
        switch self {
        case .gaussian: "drop.halffull"
        case .pixelate: "checkerboard.rectangle"
        case .cover: "rectangle.fill"
        case .spotlight: "flashlight.on.fill"
        }
    }
}
