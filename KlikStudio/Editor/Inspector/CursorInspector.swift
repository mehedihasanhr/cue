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

                // Everything about how the pointer looks, which is nothing to set while
                // there is no pointer. The switch above stays live, or there would be no
                // way back.
                Group {
                    InspectorSlider(model: model, "Size", systemImage: "arrow.up.left.and.arrow.down.right",
                                    value: style.binding(\.cursor.scale, "Pointer Size"), range: 0.5...3,
                                    format: { String(format: "%.1f×", $0) })
                    InspectorSlider(model: model, "Smoothing", systemImage: "scribble",
                                    value: style.binding(\.cursor.smoothing, "Smoothing"), range: 0...1)

                    // Only offered when the recording actually kept one. A switch that says
                    // "use the real pointer" on a recording that has no picture of one is a
                    // switch that does nothing, and the user would have no way to tell.
                    if model.hasRecordedPointer {
                        Toggle("Use the pointer from the recording",
                               isOn: style.binding(\.cursor.usesRecordedArtwork, "Recorded Pointer"))
                            .disabled(model.timeline.cursor.appearance != .asRecorded)
                            .help("Only for the As recorded style. The other styles are drawings of their own.")
                    }
                    Toggle("Motion blur", isOn: style.binding(\.cursor.motionBlur, "Motion Blur"))
                    Toggle("Keep size while zoomed",
                           isOn: style.binding(\.cursor.sizeIsIndependentOfZoom, "Pointer Zoom"))
                }
                .disabled(!model.timeline.cursor.isVisible)
            }
            .font(.system(size: 12))
            .inspectorSection("Pointer", systemImage: "cursorarrow.rays")

            PointerStyleSection(model: model)
            shape
            rest
            clicks
            clickSound
            PointerSwaySection(model: model)
            PointerSpotlightSection(model: model)
            PointerMagnifierSection(model: model)
            PointerLoopSection(model: model)
            overTime
        }
    }

    /// Which pointer is drawn.
    @ViewBuilder
    private var shape: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Always the arrow", isOn: style.binding(\.cursor.alwaysArrow, "Pointer Shape"))
            Toggle("Ignore a shape held for an instant",
                   isOn: style.binding(\.cursor.steadiesShape, "Pointer Shape"))
                // Nothing to steady when there is only ever one shape.
                .disabled(model.timeline.cursor.alwaysArrow)
            Text(model.timeline.cursor.appearance.followsRecordedShape
                 ? "Crossing a toolbar turns the pointer into a hand and back within a moment. At video size that is a flicker."
                 : "Only for the As recorded style. The \(model.timeline.cursor.appearance.title) style is one drawing throughout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .disabled(!model.timeline.cursor.isVisible || !model.timeline.cursor.appearance.followsRecordedShape)
        .inspectorSection("Shape", systemImage: "cursorarrow")
    }

    /// What the pointer does when it is left alone.
    @ViewBuilder
    private var rest: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Hide while it is still", isOn: style.binding(\.cursor.hidesWhenIdle, "Hide Idle Pointer"))
            InspectorSlider(model: model, "After", systemImage: "timer",
                            value: style.binding(\.cursor.idleDelay, "Idle Delay"),
                            range: CursorStyle.idleDelayRange,
                            format: { String(format: "%.1fs", $0) })
                .disabled(!model.timeline.cursor.hidesWhenIdle)
            Text("It fades away once it has stopped moving, and is back before it moves again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .disabled(!model.timeline.cursor.isVisible)
        .inspectorSection("At rest", systemImage: "moon.zzz")
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
            InspectorField(title: "Style") {
                InspectorPicker(selection: style.binding(\.cursor.clickStyle, "Click Style"),
                                options: CursorStyle.ClickStyle.allCases,
                                title: \.title)
            }
            .disabled(!model.timeline.cursor.clickHighlight)
            InspectorSlider(model: model, "Size", systemImage: "circle.dashed",
                            value: style.binding(\.cursor.clickSize, "Click Size"),
                            range: 0.03...0.16)
                .disabled(!model.timeline.cursor.clickHighlight)
            ColorPicker("Colour", selection: clickColour, supportsOpacity: false)
                .disabled(!model.timeline.cursor.clickHighlight)
            Toggle("Pointer swells on click", isOn: style.binding(\.cursor.clickEffect, "Click Effect"))
            Text(clickNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .disabled(!model.timeline.cursor.isVisible)
        .inspectorSection("Clicks", systemImage: "cursorarrow.click")
    }

    /// A click heard as well as seen.
    ///
    /// A section of its own rather than more of Clicks: the marks are about the picture
    /// and this is about the soundtrack, and it has to say so, because it adds a sound
    /// the recording never had.
    @ViewBuilder
    private var clickSound: some View {
        let isOn = model.timeline.cursor.clickSound
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Play a sound on each click", isOn: style.binding(\.cursor.clickSound, "Click Sound"))
            Group {
                InspectorField(title: "Sound") {
                    InspectorPicker(selection: style.binding(\.cursor.clickSoundKind, "Click Sound"),
                                    options: CursorStyle.ClickSound.allCases,
                                    title: \.title)
                }
                InspectorSlider(model: model, "Volume", systemImage: "speaker.wave.2",
                                value: style.binding(\.cursor.clickSoundVolume, "Click Volume"),
                                range: 0...1)
            }
            .disabled(!isOn)
            Text(isOn
                 ? "Heard while you edit and in the export. Not where the pointer is hidden."
                 : "Adds a click to the soundtrack wherever a click is seen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .disabled(!model.timeline.cursor.isVisible)
        .inspectorSection("Click Sound", systemImage: "speaker.wave.1")
    }

    /// What the chosen mark does, in a sentence.
    private var clickNote: String {
        switch model.timeline.cursor.clickStyle {
        case .ring: "A ring spreads from the spot that was clicked. Right-clicks get a second ring inside it."
        case .ripple: "Rings spread from the spot one after another, like a drop in water. Right-clicks get one more."
        case .glow: "A soft light swells at the spot and fades. Quieter than a ring on a busy screen."
        }
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
