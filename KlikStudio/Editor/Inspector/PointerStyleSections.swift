import AppKit
import BackgroundKit
import RenderKit
import SwiftUI
import TimelineKit

/// What the pointer is drawn as: five tiles, each showing the drawing it makes.
///
/// Tiles rather than a pop-up because the choice is a picture. The previews come from the
/// renderer's own drawings, so a tile shows what the export will.
struct PointerStyleSection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var cursor: CursorStyle { model.timeline.cursor }

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(CursorStyle.Appearance.allCases, id: \.self) { appearance in
                    tile(appearance)
                }
            }
            if cursor.appearance == .dot {
                ColorPicker("Dot colour", selection: dotColour, supportsOpacity: false)
            }
            Text(cursor.isVisible ? note : "Turn on Show pointer to choose how it is drawn.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .disabled(!cursor.isVisible)
        .inspectorSection("Style", systemImage: "cursorarrow.square")
    }

    private func tile(_ appearance: CursorStyle.Appearance) -> some View {
        VStack(spacing: 4) {
            SwatchTile(isSelected: cursor.appearance == appearance, title: appearance.title) {
                style.set(\.cursor.appearance, to: appearance, "Pointer Style")
            } content: {
                ZStack {
                    // Half light, half dark, so a tile shows how the drawing reads on both.
                    LinearGradient(colors: [Color(white: 0.86), Color(white: 0.86), Color(white: 0.22), Color(white: 0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    preview(appearance)
                }
            }
            Text(appearance.title)
                .font(.system(size: 10.5))
                .foregroundStyle(cursor.appearance == appearance ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
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

    private var note: String {
        switch cursor.appearance {
        case .asRecorded: "The pointer the recording had: its own picture where one was kept, and its shape — arrow, text, hand — throughout."
        case .largeArrow: "A large arrow throughout, whatever the pointer turned into."
        case .dot: "A dot with a soft ring, like a presentation pointer. Its size is the Size above."
        case .minimal: "A small outlined arrow that stays out of the way."
        case .clicksOnly: "No pointer. Clicks are still marked, and still heard if click sounds are on."
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
        let key = appearance == .dot ? "dot \(color.r) \(color.g) \(color.b)" : appearance.rawValue
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

    var body: some View {
        let spotlight = cursor.spotlight
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Darken all but the pointer", isOn: style.binding(\.cursor.spotlight.isEnabled, "Spotlight"))
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
                              effect: "The background and the recording darken outside a soft circle round the pointer. Captions, notes, keys and the camera stay bright.",
                              menuItem: "Spotlight Pointer over Selection")
        }
        .font(.system(size: 12))
        .disabled(!cursor.isVisible)
        .inspectorSection("Spotlight", systemImage: "circle.dashed.inset.filled")
    }
}

/// A round, magnified view round the pointer.
struct PointerMagnifierSection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var cursor: CursorStyle { model.timeline.cursor }

    var body: some View {
        let magnifier = cursor.magnifier
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Magnify round the pointer", isOn: style.binding(\.cursor.magnifier.isEnabled, "Magnifier"))
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
                              effect: "A round lens shows what is under the pointer, taken from the full recording so small text stays sharp. Near an edge it moves in rather than being cut off.",
                              menuItem: "Magnify Pointer over Selection")
        }
        .font(.system(size: 12))
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
        InspectorField(title: "Where") {
            InspectorPicker(selection: StyleBinding(model: model).binding(scope, "\(name) Where"),
                            options: PointerEffectScope.allCases,
                            title: \.title)
        }
    }
}

/// What an effect does, or why it is not doing it.
private struct PointerEffectNote: View {
    let model: EditorModel
    let isEnabled: Bool
    let scope: PointerEffectScope
    let isMarked: (CursorRegion) -> Bool
    let effect: String
    let menuItem: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        let cursor = model.timeline.cursor
        guard cursor.isVisible else { return "Turn on Show pointer to use this. It follows the pointer." }
        guard isEnabled else { return effect }
        if scope == .markedStretches, !model.timeline.cursorRegions.contains(where: isMarked) {
            return "No stretch asks for it yet. Select a stretch on the Pointer lane and turn it on there, or choose Edit ▸ \(menuItem)."
        }
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
