import AppKit
import BackgroundKit
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

    @State private var coalescer = InteractionCoalescer()

    var body: some View {
        // Nothing of its own between the sections: each one already carries its padding
        // and the rule that closes it. Adding a stack gap on top of that put 26 points
        // under every rule and none above it, which is the lopsided gap this column had.
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            // No Look section: looks are applied and saved from the Frame menu, and the
            // panel opens on the background.
            BackgroundPicker(model: model, state: state)

            shape
            if model.timeline.style.crop != nil { crop }

            // Set once and left: behind one heading, so the panel opens on the three
            // things nearly every edit touches.
            InspectorAdvancedGroup("frame", contents: ["Window", "Border", "Zoom", "Perspective", "Colour"]) {
                window
                finish
                WholeVideoZoomSection(model: model)
                PerspectiveSection(model: model)
                ColorGradeSection(model: model)
            }
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
            // The typed numbers, only while Custom is the shape: two fields under a
            // pop-up that says "Wide 16:9" would be two fields that do nothing.
            if model.timeline.style.aspect == .custom {
                CustomAspectFields(model: model)
            }
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorSlider(model: model, "Padding", systemImage: "square.dashed.inset.filled",
                                value: style.binding(\.style.padding, "Padding"), range: 0...0.2,
                                defaultValue: style.factory(\.style.padding))
                InspectorSlider(model: model, "Corners", systemImage: "rectangle.roundedtop",
                                value: style.binding(\.style.cornerRadius, "Corners"), range: 0...0.08,
                                defaultValue: style.factory(\.style.cornerRadius))
                InspectorSlider(model: model, "Shadow", systemImage: "shadow",
                                value: style.binding(\.style.shadowOpacity, "Shadow"), range: 0...1,
                                defaultValue: style.factory(\.style.shadowOpacity))
            }
        }
        .inspectorSection("Shape", systemImage: "square.on.square") {
            InspectorPicker(selection: style.binding(\.style.aspect, "Shape"),
                            options: AspectPreset.menuOrder) { $0.displayName }
        }
    }

    // MARK: - Window

    /// A window drawn round the picture: which kind, and whether its bar is light or dark —
    /// or a phone or tablet, and its finish, which way up it is held and its camera.
    ///
    /// The kind is on the heading, like the shape is on Shape's. What is under it is only
    /// what that kind has: a device has no title bar to be light or dark, and a window no
    /// rim to be silver.
    private var window: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            if model.windowChrome.kind.isDevice {
                device
            } else if model.windowChrome.isVisible {
                InspectorRow("Title bar") {
                    InspectorTabs(selection: Binding(get: { model.windowChrome.appearance },
                                                     set: { model.setWindowAppearance($0) }),
                                  items: WindowChrome.Appearance.allCases) { $0.title }
                        .frame(width: 120)
                }
                .help("The picture is made a little smaller so the window fits inside the padding.")
            }
            // No window: nothing under the heading. The pop-up on it says None, and its
            // tooltip says what the choices draw.
        }
        .inspectorSection("Window", systemImage: "macwindow") {
            InspectorPicker(selection: Binding(get: { model.windowChrome.kind },
                                               set: { model.setWindowChrome($0) }),
                            options: WindowChrome.Kind.allCases) { $0.title }
                .accessibilityLabel("Window frame")
                .help("Draw a title bar above the picture, or an iPhone or iPad round it")
        }
    }

    /// A phone's or a tablet's settings: its rim, which way up, and its camera.
    @ViewBuilder
    private var device: some View {
        let chrome = model.windowChrome
        InspectorRow("Finish") {
            InspectorPicker(selection: Binding(get: { model.windowChrome.finish },
                                               set: { model.setDeviceFinish($0) }),
                            options: WindowChrome.Finish.allCases) { $0.title }
        }
        .help("The recording is fitted to the screen, with black either side where its shape differs. The border is not drawn on a device.")
        InspectorRow("Held") {
            InspectorPicker(selection: Binding(get: { model.windowChrome.orientation },
                                               set: { model.setDeviceOrientation($0) }),
                            options: WindowChrome.Orientation.allCases) { $0.title }
        }
        .help("Auto holds the device the way the recording is shaped")
        InspectorSwitch(chrome.kind == .iPhone ? "Camera cut-out" : "Camera", isOn: Binding(
            get: { model.windowChrome.showsCamera },
            set: { model.setDeviceCamera($0) }
        ))
        .help(chrome.kind == .iPhone ? "The pill across the top of the screen, over the picture"
                                     : "The lens in the bezel")
    }

    // MARK: - Border

    /// How the shadow falls and the line round the picture: the finishing touches, under
    /// Advanced, beside the window.
    private var finish: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSlider(model: model, "Shadow softness", systemImage: "aqi.medium",
                            value: style.binding(\.style.shadowRadius, "Shadow Softness"), range: 0...0.08,
                            defaultValue: style.factory(\.style.shadowRadius))
            border
        }
        .inspectorSection("Border", systemImage: "square.dashed")
    }

    /// A line round the picture, outside its edge. Zero is off, and it starts off.
    private var border: some View {
        let hasBorder = model.timeline.style.borderWidth > 0
        return VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSlider(model: model, "Border", systemImage: "square",
                            value: style.binding(\.style.borderWidth, "Border"),
                            range: FrameStyle.borderWidthRange,
                            defaultValue: style.factory(\.style.borderWidth))
            // "Colour" alone, directly under the Border slider: the label column is
            // narrow, and "Border colour" would be cut short in it.
            InspectorRow("Border colour") {
                InspectorColorWell(title: "Border colour", selection: borderColour, supportsOpacity: true)
            }
            .disabled(!hasBorder)
            .help(hasBorder ? "The border's colour" : "No border yet. Raise Border to draw one.")
        }
    }

    /// The one control with no "editing ended" of its own — see `InteractionCoalescer`.
    private var borderColour: Binding<Color> {
        Binding {
            model.timeline.style.borderColor.color
        } set: { colour in
            let value = RGBA(NSColor(colour)).colorValue
            coalescer.touch("Border Colour", model: model)
            model.apply(Commands.Restyle("Border Colour") { $0.style.borderColor = value })
        }
    }

    // MARK: - Crop

    /// Shown only while there is a crop, and showing the numbers, because area is
    /// preserved against the *cropped* picture: cropping hard means a smaller export,
    /// and that is worth saying out loud rather than discovering later.
    private var crop: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow(title: "Kept",
                         value: "\(Int(model.croppedVideoSize.width)) × \(Int(model.croppedVideoSize.height))")
            InspectorRow(title: "Exported",
                         value: "\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
            Button(model.tool == .crop ? "Done" : "Adjust Crop") {
                model.tool = model.tool == .crop ? .frame : .crop
            }
            .buttonStyle(.studio(.secondary, size: .small))
        }
        .inspectorSection("Crop", systemImage: "crop") {
            SectionButton(title: "Reset") { model.setCrop(nil) }
                .help("Show the whole recording again")
        }
    }
}
