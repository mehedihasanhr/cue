import CoreMedia
import SwiftUI
import TimelineKit

/// One stretch of the camera lane: which layout it shows, and when.
///
/// The Webcam panel is the camera as a whole. This is a single stretch on its lane,
/// reached by clicking its chip: what it does, where it begins and ends. Delete is the
/// panel's own button under this, and moving it is a drag on the lane.
struct CameraLayoutInspector: View {
    let model: EditorModel
    let id: UUID

    private var region: CameraLayoutRegion? { model.timeline.cameraLayouts.first { $0.id == id } }

    var body: some View {
        if let region {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
                layout(region)
                timing(region)
            }
        }
    }

    // MARK: - What it shows

    private func layout(_ region: CameraLayoutRegion) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorTabs(selection: Binding(get: { region.layout },
                                             set: { model.setCameraLayout(id, to: $0) }),
                          items: CameraLayout.allCases) { $0.title }
            Text(note(region.layout))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.timeline.webcam.isEnabled {
                Text("The camera is switched off for the whole video, so this stretch shows nothing of it. Turn it on in the Webcam panel or the Camera menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .inspectorSection("Layout", systemImage: "person.crop.rectangle")
    }

    /// What the chosen layout does, in a sentence.
    private func note(_ layout: CameraLayout) -> String {
        switch layout {
        case .bubble:
            "The screen, with the camera in its bubble where the Webcam panel puts it."
        case .cameraOnly:
            "The camera fills the frame inside the padding, and the screen and the pointer are hidden."
        case .sideBySide:
            "The screen and the camera beside each other. The camera takes the side its bubble is parked on."
        case .hidden:
            "The screen alone. The bubble keeps its place for when it comes back."
        }
    }

    // MARK: - When

    private func timing(_ region: CameraLayoutRegion) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow(title: "Starts", value: Timecode.short(region.start))
            InspectorRow(title: "Ends", value: Timecode.short(region.end))
            InspectorRow(title: "Lasts", value: Timecode.length(region.duration))
            Text("The change takes a third of a second, inside the stretch at each end. Drag it along the lane to move it, or take an edge to change when it starts or ends.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .inspectorSection("Timing", systemImage: "clock") {
            SectionButton(title: "Go to Start") { model.scrub(to: region.start) }
        }
    }
}
