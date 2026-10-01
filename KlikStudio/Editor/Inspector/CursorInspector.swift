import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// How the pointer is drawn.
///
/// None of this would be possible from a recording with the cursor burned in, which is
/// why the recorder writes cursor positions as data and leaves the video clean.
///
/// Every section is rows and switches, with what each one does in its tooltip. The panel
/// used to carry a sentence under nearly every control — eleven sections, most of them
/// with a paragraph — and the one sentence that mattered in any of them was lost among
/// the rest.
struct CursorInspector: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorSwitch("Show pointer", isOn: style.binding(\.cursor.isVisible, "Pointer"))

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
                        InspectorSwitch("Use the recorded pointer",
                                        isOn: style.binding(\.cursor.usesRecordedArtwork, "Recorded Pointer"))
                            .disabled(model.timeline.cursor.appearance != .asRecorded)
                            .help("Use the pointer from the recording. Only for the As recorded style. The other styles are drawings of their own.")
                    }
                    InspectorSwitch("Motion blur", isOn: style.binding(\.cursor.motionBlur, "Motion Blur"))
                    InspectorSwitch("Keep size while zoomed",
                                    isOn: style.binding(\.cursor.sizeIsIndependentOfZoom, "Pointer Zoom"))
                }
                .disabled(!model.timeline.cursor.isVisible)
            }
            .inspectorSection("Pointer", systemImage: "cursorarrow.rays")

            PointerStyleSection(model: model)
            shape
            rest
            clicks
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
        let followsShape = model.timeline.cursor.appearance.followsRecordedShape
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Always the arrow", isOn: style.binding(\.cursor.alwaysArrow, "Pointer Shape"))
            InspectorSwitch("Ignore brief shape changes",
                            isOn: style.binding(\.cursor.steadiesShape, "Pointer Shape"))
                // Nothing to steady when there is only ever one shape.
                .disabled(model.timeline.cursor.alwaysArrow)
                .help("Ignore a shape held for an instant. Crossing a toolbar turns the pointer into a hand and back within a moment. At video size that is a flicker.")
        }
        .disabled(!model.timeline.cursor.isVisible || !followsShape)
        .help(followsShape
              ? ""
              : "Only for the As recorded, macOS, Classic Klik, Gradient, Neon and Frost styles. The \(model.timeline.cursor.appearance.title) style is one drawing throughout.")
        .inspectorSection("Shape", systemImage: "cursorarrow")
    }

    /// What the pointer does when it is left alone.
    @ViewBuilder
    private var rest: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Hide while it is still", isOn: style.binding(\.cursor.hidesWhenIdle, "Hide Idle Pointer"))
                .help("It fades away once it has stopped moving, and is back before it moves again.")
            InspectorSlider(model: model, "After", systemImage: "timer",
                            value: style.binding(\.cursor.idleDelay, "Idle Delay"),
                            range: CursorStyle.idleDelayRange,
                            format: { String(format: "%.1fs", $0) })
                .disabled(!model.timeline.cursor.hidesWhenIdle)
        }
        .disabled(!model.timeline.cursor.isVisible)
        .inspectorSection("At Rest", systemImage: "moon.zzz")
    }

    /// What a click looks like, and sounds like.
    ///
    /// Its own section because a screen recording is watched without sound and this is
    /// the only thing in the whole editor that says a click happened. The swell says *the
    /// pointer* did something, the mark says *this spot* was clicked, and the sound — under
    /// a subheading, because it adds something to the soundtrack the recording never had —
    /// says it to the ear.
    @ViewBuilder
    private var clicks: some View {
        let marks = model.timeline.cursor.clickHighlight
        let sound = model.timeline.cursor.clickSound
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Mark where clicks happen", isOn: style.binding(\.cursor.clickHighlight, "Click Marks"))
            Group {
                InspectorRow("Style") {
                    InspectorPicker(selection: style.binding(\.cursor.clickStyle, "Click Style"),
                                    options: CursorStyle.ClickStyle.allCases,
                                    title: \.title)
                }
                .help(clickNote)
                InspectorSlider(model: model, "Size", systemImage: "circle.dashed",
                                value: style.binding(\.cursor.clickSize, "Click Size"),
                                range: 0.03...0.16)
                InspectorRow("Colour") {
                    InspectorColorWell(title: "Click colour", selection: clickColour)
                }
            }
            .disabled(!marks)
            InspectorSwitch("Pointer swells on click", isOn: style.binding(\.cursor.clickEffect, "Click Effect"))

            InspectorSubheading("Sound")
                .padding(.top, SidebarSpacing.betweenGroups - SidebarSpacing.betweenControls)
            InspectorSwitch("Play a sound on each click", isOn: style.binding(\.cursor.clickSound, "Click Sound"))
                .help(sound
                      ? "Heard while you edit and in the export. Not where the pointer is hidden."
                      : "Adds a click to the soundtrack wherever a click is seen.")
            Group {
                InspectorRow("Sound") {
                    InspectorPicker(selection: style.binding(\.cursor.clickSoundKind, "Click Sound"),
                                    options: CursorStyle.ClickSound.allCases,
                                    title: \.title)
                }
                InspectorSlider(model: model, "Volume", systemImage: "speaker.wave.2",
                                value: style.binding(\.cursor.clickSoundVolume, "Click Volume"),
                                range: 0...1)
            }
            .disabled(!sound)
        }
        .disabled(!model.timeline.cursor.isVisible)
        .inspectorSection("Clicks", systemImage: "cursorarrow.click")
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
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorNote("Everything above is for the whole recording.")
                Button("Hide Pointer over Selection") { model.hidePointerOverSelection() }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .help("A stretch can override the settings above — hidden while a face is on screen, calmed through one bad flick, held still while something is being read.")
            }
            .inspectorSection("Pointer over Time", systemImage: "cursorarrow.slash")
        }
    }
}
