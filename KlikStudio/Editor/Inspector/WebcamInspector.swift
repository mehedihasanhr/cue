import AppKit
import BackgroundKit
import RecordKit
import SwiftUI
import TimelineKit

/// The camera bubble: whether it is there, where it sits, and what shape it is.
///
/// Named for the webcam and not for "the camera", because this editor already has a camera
/// and it is a different thing: `CameraControls`, inside the zoom inspector, tunes how the *zoomed* camera
/// follows the pointer. One panel is about a lens pointed at a face, the other is about a
/// crop drifting over a screenshot, and the two being one word apart is how somebody ends
/// up tuning steadiness to stop a bubble wobbling.
///
/// Every control here writes through `StyleBinding`, so each one is an ordinary undoable
/// style edit named for the thing it changed — the same as padding or pointer size. Nothing
/// on this panel is a preference: the bubble travels in the project, because it changes the
/// exported file.
struct WebcamInspector: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var webcam: WebcamSettings { model.timeline.webcam }

    @State private var coalescer = InteractionCoalescer()

    /// Whether this recording has a camera in it at all.
    ///
    /// Read from the manifest, which is what the manifest's track list is for. It changes
    /// what this panel *says* and not what it lets you do: the settings are part of the
    /// document either way, so a project opened from a take with no camera must not quietly
    /// throw them away — somebody may be building a template.
    private var hasFootage: Bool { model.hasTrack(.webcam) }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                // First when there is no camera, because it is the reason for everything
                // under it. At the foot of the panel it was read last, after a column of
                // controls that appeared to do nothing.
                if !hasFootage { note }

                Toggle("Show camera", isOn: style.binding(\.webcam.isEnabled, "Camera Bubble"))

                Group {
                    corners

                    InspectorSlider(model: model, "Size", systemImage: "arrow.up.left.and.arrow.down.right",
                                    value: style.binding(\.webcam.size, "Camera Size"), range: 0.08...0.5)
                    InspectorSlider(model: model, "Roundness", systemImage: "circle",
                                    value: style.binding(\.webcam.roundness, "Camera Roundness"), range: 0...1)
                    InspectorSlider(model: model, "Shadow", systemImage: "shadow",
                                    value: style.binding(\.webcam.shadowOpacity, "Camera Shadow"), range: 0...1)

                    Toggle("Mirror", isOn: style.binding(\.webcam.isMirrored, "Mirror Camera"))
                    Toggle("Grow while zoomed", isOn: style.binding(\.webcam.reactsToZoom, "Grow While Zoomed"))
                }
                // Dimmed rather than removed when the bubble is off, so the panel does not
                // change height as the toggle is flicked — and so the settings are visibly
                // still there rather than looking lost. The switch itself stays bright: it
                // is the way back.
                .disabled(!webcam.isEnabled)
                .opacity(webcam.isEnabled ? 1 : 0.5)

                if hasFootage { note }
            }
            .font(.system(size: 12))
            .inspectorSection("Camera", systemImage: "person.crop.square")

            Group {
                layout
                framing
                border
                background
            }
            .font(.system(size: 12))
            .disabled(!webcam.isEnabled)
            .opacity(webcam.isEnabled ? 1 : 0.5)
        }
    }

    // MARK: - Layout over time

    /// The layout at the playhead, and the way to give a stretch a different one.
    ///
    /// The lane is where the stretches are moved and trimmed; this is where somebody looking
    /// at the camera's settings finds that it can do more than sit in a corner.
    private var layout: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            if let region = model.activeCameraLayout {
                InspectorTabs(selection: Binding(get: { region.layout },
                                                 set: { model.setCameraLayout(region.id, to: $0) }),
                              items: CameraLayout.allCases) { $0.title }
                Text("This stretch, \(Timecode.short(region.start)) to \(Timecode.short(region.end)), on the Camera lane.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The bubble, here. Give a stretch its own layout — the camera alone, side by side with the screen, or hidden — from the playhead, or over a selected range.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Menu("Add at Playhead") {
                ForEach(CameraLayout.allCases) { layout in
                    Button(layout.title) { model.addCameraLayout(layout) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!hasFootage)
            .accessibilityLabel("Add camera layout at playhead")
        }
        .inspectorSection("Layout", systemImage: "person.crop.rectangle")
    }

    // MARK: - Framing

    /// Which part of the camera's picture the bubble shows.
    private var framing: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSlider(model: model, "Zoom", systemImage: "plus.magnifyingglass",
                            value: style.binding(\.webcam.crop.zoom, "Camera Zoom"),
                            range: WebcamCrop.zoomRange,
                            format: { String(format: "%.1f×", $0) })
            InspectorSlider(model: model, "Across", systemImage: "arrow.left.and.right",
                            value: offset(\.x, "Camera Framing"), range: -1...1,
                            format: { Self.direction($0, less: "Left", more: "Right") })
            InspectorSlider(model: model, "Up and down", systemImage: "arrow.up.and.down",
                            value: offset(\.y, "Camera Framing"), range: -1...1,
                            format: { Self.direction($0, less: "Up", more: "Down") })
            Text("Zoom in on the face, then slide to frame it. Unzoomed, a wide camera can still slide across; a square one has nowhere to go.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .inspectorSection("Framing", systemImage: "crop") {
            SectionButton(title: "Reset") { model.resetCameraCrop() }
                .disabled(webcam.crop == WebcamCrop())
        }
    }

    /// One axis of the crop's offset, as a slider. Its own binding because the model's
    /// point is `CGFloat` and the slider's value is `Double`.
    private func offset(_ axis: WritableKeyPath<CGPoint, CGFloat> & Sendable, _ name: String) -> Binding<Double> {
        Binding {
            Double(model.timeline.webcam.crop.offset[keyPath: axis])
        } set: { value in
            model.apply(Commands.Restyle(name) { $0.webcam.crop.offset[keyPath: axis] = CGFloat(value) })
        }
    }

    private static func direction(_ value: Double, less: String, more: String) -> String {
        let percent = Int((abs(value) * 100).rounded())
        guard percent > 0 else { return "Centre" }
        return "\(value < 0 ? less : more) \(percent)%"
    }

    // MARK: - Border

    /// A line round the camera, inside its edge. Zero is off, and it starts off.
    private var border: some View {
        let hasBorder = webcam.borderWidth > 0
        return VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSlider(model: model, "Width", systemImage: "circle",
                            value: style.binding(\.webcam.borderWidth, "Camera Border"),
                            range: WebcamSettings.borderWidthRange)
            InspectorField(title: "Colour") {
                ColorPicker("Camera border colour", selection: borderColour, supportsOpacity: true)
                    .fixedSize()
            }
            .disabled(!hasBorder)
            .help("The border's colour")
            if !hasBorder {
                Text("No border yet. Raise Width to draw one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .inspectorSection("Border", systemImage: "circle.dashed")
    }

    /// The one control with no "editing ended" of its own — see `InteractionCoalescer`.
    private var borderColour: Binding<Color> {
        Binding {
            model.timeline.webcam.borderColor.color
        } set: { colour in
            let value = RGBA(NSColor(colour)).colorValue
            coalescer.touch("Camera Border Colour", model: model)
            model.apply(Commands.Restyle("Camera Border Colour") { $0.webcam.borderColor = value })
        }
    }

    // MARK: - Background

    /// What happens to the room behind the person.
    private var background: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorTabs(selection: Binding(get: { webcam.background },
                                             set: { model.setCameraBackground($0) }),
                          items: WebcamSettings.Background.allCases) { $0.shortTitle }
            if webcam.background == .blur {
                InspectorSlider(model: model, "Blur", systemImage: "drop",
                                value: style.binding(\.webcam.backgroundBlur, "Camera Background Blur"),
                                range: 0...1)
            }
            Text(backgroundNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .inspectorSection("Background", systemImage: "person.and.background.dotted")
    }

    private var backgroundNote: String {
        switch webcam.background {
        case .keep:
            "The camera as it was filmed."
        case .blur:
            "The room behind you is softened; you stay sharp. Found frame by frame, so it follows you as you move."
        case .remove:
            "The room behind you is taken away, and whatever is behind the bubble shows through — the screen, or the background in Camera Only."
        }
    }

    /// The four corners, plus the state a drag on the picture puts it in.
    ///
    /// `.custom` is offered as a *reading* rather than as a choice: picking it from a menu
    /// would leave the bubble wherever it already was with no hint of what to do next, so
    /// the row shows it selected when it applies and the note below says how to get there.
    private var corners: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text("Corner")
                .frame(width: 74, alignment: .leading)
            Picker("", selection: cornerSelection) {
                ForEach(WebcamSettings.Corner.pickable, id: \.self) { corner in
                    Image(systemName: corner.symbol).tag(corner)
                }
                if webcam.corner == .custom {
                    Image(systemName: "hand.draw").tag(WebcamSettings.Corner.custom)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Writes through a command so the change is undoable and named, like every other
    /// control here. A `Binding` straight at the model would skip the undo stack.
    private var cornerSelection: Binding<WebcamSettings.Corner> {
        Binding { webcam.corner } set: { style.set(\.webcam.corner, to: $0, "Camera Corner") }
    }

    /// What the panel cannot do anything about: no camera in the take, or a bubble parked
    /// somewhere by hand.
    @ViewBuilder
    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hasFootage {
                Text("This recording has no camera in it, so there is nothing to draw. Turn the camera on in the recorder bar before the take.")
            } else if webcam.corner == .custom {
                Text("The bubble is where you put it. Drag it on the picture to move it, or pick a corner above to park it.")
            } else {
                Text("Drag the bubble on the picture to put it anywhere. The camera is cropped to the middle of its shot, so a wide camera keeps a face centred rather than squashed.")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension WebcamSettings.Background {
    /// Short enough for a row of three chips in the panel. The menu uses the long `title`.
    var shortTitle: String {
        switch self {
        case .keep: "None"
        case .blur: "Blur"
        case .remove: "Remove"
        }
    }
}

extension WebcamSettings.Corner {
    /// The four that can be chosen from a row of buttons. `.custom` is not one of them —
    /// it is what a drag produces, and it has no button because "put it somewhere
    /// unspecified" is not an instruction anybody can follow.
    static var pickable: [WebcamSettings.Corner] { [.topLeft, .topRight, .bottomLeft, .bottomRight] }

    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left.square"
        case .topRight: "arrow.up.right.square"
        case .bottomLeft: "arrow.down.left.square"
        case .bottomRight: "arrow.down.right.square"
        case .custom: "hand.draw"
        }
    }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .custom: "Where you put it"
        }
    }
}
