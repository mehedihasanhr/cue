import AppKit
import BackgroundKit
import RenderKit
import SwiftUI
import TimelineKit

/// What the pointer is drawn as: a grid of small tiles, each showing the drawing it makes.
///
/// Tiles rather than a pop-up because the choice is a picture — small ones, four to a row
/// at the panel's width, with the chosen style's name on the heading. One fixed row of
/// five ran off the right edge of the panel, and there are seventeen styles now. The
/// previews come from the renderer's own drawings, so a tile shows what the export will;
/// what each style does is its tooltip.
struct PointerStyleSection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var cursor: CursorStyle { model.timeline.cursor }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 36, maximum: 56), spacing: 8), count: 6),
                      spacing: 8) {
                ForEach(CursorStyle.Appearance.allCases, id: \.self) { appearance in
                    tile(appearance)
                }
            }
            if cursor.appearance.usesColour {
                InspectorRow("Colour") {
                    InspectorColorWell(title: "Pointer colour", selection: dotColour)
                }
            }
        }
        .disabled(!cursor.isVisible)
        .help(cursor.isVisible ? "" : "Turn on Show pointer to choose how it is drawn.")
        .inspectorSection("Style", systemImage: "cursorarrow.square") {
            Text(cursor.appearance.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ appearance: CursorStyle.Appearance) -> some View {
        SwatchTile(isSelected: cursor.appearance == appearance, title: appearance.title,
                   tooltip: "\(appearance.title): \(note(appearance))") {
            style.set(\.cursor.appearance, to: appearance, "Pointer Style")
        } content: {
            ZStack {
                // One calm mid-tone, like a desktop: dark enough for a white pointer to
                // stand out on and light enough for a black one. A hard diagonal of light
                // and dark showed both, but read as a bevelled button.
                // Neutral rather than slate blue: a column of tinted tiles was the loudest
                // thing in a grey panel.
                LinearGradient(colors: [Color(white: 0.46), Color(white: 0.38)],
                               startPoint: .top, endPoint: .bottom)
                preview(appearance)
            }
        }
        .frame(maxWidth: 56)
    }

    @ViewBuilder
    private func preview(_ appearance: CursorStyle.Appearance) -> some View {
        if let image = PointerTilePreviews.image(appearance, color: cursor.dotColor) {
            // At the drawing's own pixels, two to a point: the tiles keep the styles'
            // sizes against each other, which is part of what is being chosen.
            Image(decorative: image, scale: 2)
        } else {
            // Nothing is drawn for the pointer, and a click still is.
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 3.5))
                .frame(width: 18, height: 18)
        }
    }

    private func note(_ appearance: CursorStyle.Appearance) -> String {
        switch appearance {
        case .asRecorded: "The pointer the recording had: its own picture where one was kept, and its shape — arrow, text, hand — throughout."
        case .largeArrow: "A large arrow throughout, whatever the pointer turned into."
        case .dot: "A dot with a soft ring, like a presentation pointer. Its size is the Size above."
        case .minimal: "A small outlined arrow that stays out of the way."
        case .clicksOnly: "No pointer. Clicks are still marked, and still heard if click sounds are on."
        case .macOS26: "The pointer macOS 26 draws — and its hand, I-beam and the rest when the pointer changes shape — sharp at any size."
        case .macOS14: "The classic macOS pointer, as drawn up to macOS 15, in each of its shapes."
        case .macOS26White: "macOS 26's pointer in white with a black outline. Clearest on dark pages."
        case .macOS14White: "The classic pointer in white with a black outline. Clearest on dark pages."
        case .macOS26Colour: "macOS 26's pointer filled with the colour you choose and outlined in white, as Accessibility can set it."
        case .classicKlik: "Klik's own classic arrow and pointing hand, crisp black and white, sharp at any size."
        case .dart: "A modern, tailless arrowhead with soft points: a pearl body in a thick white rim, with a soft shadow."
        case .dartBlack: "The dart in solid black with a white rim. Clearest on light pages."
        case .dartColour: "The dart in the colour you choose, with a white rim."
        case .gradient: "macOS 26's pointer filled with a gradient from the colour you choose, with a soft glow of it underneath."
        case .neon: "A dark pointer with a glowing outline in the colour you choose. Strongest on dark pages."
        case .frost: "A frosted, icy-white pointer with a crisp dark outline. Clean on any page."
        }
    }

    private var dotColour: Binding<Color> {
        Binding {
            Color(model.timeline.cursor.dotColor.rgba.nsColor)
        } set: { colour in
            style.set(\.cursor.dotColor, to: RGBA(NSColor(colour)).colorValue, "Dot Colour")
        }
    }
}

/// The tiles' pictures, made once per style and colour rather than on every redraw.
@MainActor
private enum PointerTilePreviews {
    private static var made: [String: CGImage] = [:]

    static func image(_ appearance: CursorStyle.Appearance, color: ColorValue) -> CGImage? {
        guard appearance.drawsPointer else { return nil }
        let key = appearance.usesColour ? "\(appearance.rawValue) \(color.r) \(color.g) \(color.b)" : appearance.rawValue
        if let image = made[key] { return image }
        // The pointer size a 1080p frame draws at the default setting, halved for the tile.
        guard let image = PointerStylePreview.image(appearance, size: 34, color: color) else { return nil }
        if made.count > 16 { made.removeAll() }
        made[key] = image
        return image
    }
}

/// The picture darkened except round the pointer.
struct PointerSpotlightSection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var cursor: CursorStyle { model.timeline.cursor }

    private static let effect = "The background and the recording darken outside a soft circle round the pointer. Captions, notes, keys and the camera stay bright."

    var body: some View {
        let spotlight = cursor.spotlight
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Darken all but the pointer", isOn: style.binding(\.cursor.spotlight.isEnabled, "Spotlight"))
                .help(PointerEffectNote.tooltip(model: model, effect: Self.effect))
            Group {
                InspectorSlider(model: model, "Size", systemImage: "circle",
                                value: style.binding(\.cursor.spotlight.radius, "Spotlight Size"),
                                range: PointerSpotlight.radiusRange)
                InspectorSlider(model: model, "Darkness", systemImage: "circle.lefthalf.filled",
                                value: style.binding(\.cursor.spotlight.dimming, "Spotlight Darkness"),
                                range: PointerSpotlight.dimmingRange,
                                format: { "\(Int(($0 * 100).rounded()))%" })
                PointerEffectScopeField(model: model, scope: \.cursor.spotlight.scope, name: "Spotlight")
            }
            .disabled(!spotlight.isEnabled)
            PointerEffectNote(model: model,
                              isEnabled: spotlight.isEnabled,
                              scope: spotlight.scope,
                              isMarked: { $0.spotlights },
                              menuItem: "Spotlight Pointer over Selection")
        }
        .disabled(!cursor.isVisible)
        .inspectorSection("Spotlight", systemImage: "circle.dashed.inset.filled")
    }
}

/// A round, magnified view round the pointer.
struct PointerMagnifierSection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var cursor: CursorStyle { model.timeline.cursor }

    private static let effect = "A round lens shows what is under the pointer, taken from the full recording so small text stays sharp. Near an edge it moves in rather than being cut off."

    var body: some View {
        let magnifier = cursor.magnifier
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Magnify round the pointer", isOn: style.binding(\.cursor.magnifier.isEnabled, "Magnifier"))
                .help(PointerEffectNote.tooltip(model: model, effect: Self.effect))
            Group {
                InspectorSlider(model: model, "Zoom", systemImage: "plus.magnifyingglass",
                                value: style.binding(\.cursor.magnifier.factor, "Magnifier Zoom"),
                                range: PointerMagnifier.factorRange,
                                format: { String(format: "%.1f×", $0) })
                InspectorSlider(model: model, "Size", systemImage: "circle",
                                value: style.binding(\.cursor.magnifier.diameter, "Magnifier Size"),
                                range: PointerMagnifier.diameterRange)
                PointerEffectScopeField(model: model, scope: \.cursor.magnifier.scope, name: "Magnifier")
            }
            .disabled(!magnifier.isEnabled)
            PointerEffectNote(model: model,
                              isEnabled: magnifier.isEnabled,
                              scope: magnifier.scope,
                              isMarked: { $0.magnifies },
                              menuItem: "Magnify Pointer over Selection")
        }
        .disabled(!cursor.isVisible)
        .inspectorSection("Magnifier", systemImage: "magnifyingglass.circle")
    }
}

/// Whole video, or only the stretches marked on the Pointer lane.
private struct PointerEffectScopeField: View {
    let model: EditorModel
    let scope: WritableKeyPath<Timeline, PointerEffectScope> & Sendable
    let name: String

    var body: some View {
        InspectorRow("Where") {
            InspectorPicker(selection: StyleBinding(model: model).binding(scope, "\(name) Where"),
                            options: PointerEffectScope.allCases,
                            title: \.title)
        }
    }
}

/// Why an effect that is switched on is not showing anywhere — and nothing otherwise.
///
/// The one case worth a line in the panel: the effect is on, limited to marked stretches,
/// and no stretch is marked, so it does nothing at all. What the effect does is the
/// switch's tooltip.
private struct PointerEffectNote: View {
    let model: EditorModel
    let isEnabled: Bool
    let scope: PointerEffectScope
    let isMarked: (CursorRegion) -> Bool
    let menuItem: String

    var body: some View {
        if model.timeline.cursor.isVisible, isEnabled, scope == .markedStretches,
           !model.timeline.cursorRegions.contains(where: isMarked) {
            InspectorNote("No stretch asks for it yet.")
                .help("No stretch asks for it yet. Select a stretch on the Pointer lane and turn it on there, or choose Edit ▸ \(menuItem).")
        }
    }

    /// What the effect does, with the one condition that changes it.
    static func tooltip(model: EditorModel, effect: String) -> String {
        let cursor = model.timeline.cursor
        guard cursor.isVisible else { return "Turn on Show pointer to use this. It follows the pointer." }
        if cursor.hidesWhenIdle {
            return effect + " It fades with the pointer when the pointer hides while still."
        }
        return effect
    }
}

extension EditorModel {
    /// Marks the selected stretch — or a few seconds at the playhead — for the spotlight,
    /// and limits the spotlight to marked stretches. One undo step.
    @discardableResult
    func spotlightPointerOverSelection() -> UUID? {
        markPointerStretch("Spotlight Pointer over Selection",
                           region: { $0.spotlights = true },
                           style: {
                               $0.cursor.spotlight.isEnabled = true
                               $0.cursor.spotlight.scope = .markedStretches
                           })
    }

    /// The same, for the magnifier.
    @discardableResult
    func magnifyPointerOverSelection() -> UUID? {
        markPointerStretch("Magnify Pointer over Selection",
                           region: { $0.magnifies = true },
                           style: {
                               $0.cursor.magnifier.isEnabled = true
                               $0.cursor.magnifier.scope = .markedStretches
                           })
    }

    /// A pointer stretch made the way "Hide Pointer over Selection" makes one, then turned
    /// from a hide into this effect — all inside one interaction, so undo takes back the
    /// stretch and the setting together.
    private func markPointerStretch(_ name: String,
                                    region change: @escaping @Sendable (inout CursorRegion) -> Void,
                                    style: @escaping @Sendable (inout Timeline) -> Void) -> UUID? {
        document.beginInteraction(name)
        defer { finishInteraction() }
        guard let id = hidePointerOverSelection() else { return nil }
        restyleCursorRegion(id, name) { region in
            region.isHidden = false
            change(&region)
        }
        apply(Commands.Restyle(name, style))
        return id
    }
}
