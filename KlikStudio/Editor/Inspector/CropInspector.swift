import SwiftUI
import TimelineKit

/// Choosing the part of the recording that makes it into the frame.
///
/// The crop itself is made on the picture — drag an edge or a corner — and it applies as
/// you let go, so there is nothing here to press to make it happen. What is here is the
/// other half of a mode: what the crop costs in pixels, and the two ways out of it.
/// Without them, turning the crop tool on left somebody holding a set of handles with no
/// visible way to keep or undo what they had done.
struct CropInspector: View {
    let model: EditorModel

    private var hasCrop: Bool { model.timeline.style.crop != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
            size
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Done") { model.tool = .frame }
                    .studioProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .help("Keep this crop and put the frame back the way it will export")
            }
            .controlSize(.small)
        }
    }

    /// What the crop leaves, and what comes out the other end.
    ///
    /// Shown because area is preserved against the *cropped* picture: cropping hard means
    /// a smaller export, and that is worth saying while the handles are still in the hand
    /// rather than discovering it in the finished file.
    private var size: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorRow(title: "Kept",
                         value: "\(Int(model.croppedVideoSize.width)) × \(Int(model.croppedVideoSize.height))")
            InspectorRow(title: "Exported",
                         value: "\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
            Text(hasCrop
                 ? "Drag an edge or a corner on the picture. ⌥-click it to take the whole frame back."
                 : "Drag an edge or a corner on the picture to choose what to keep.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .inspectorSection("Crop", systemImage: "crop") {
            SectionButton(title: "Reset") { model.setCrop(nil) }
                .disabled(!hasCrop)
                .help("Take the whole recording back")
        }
    }
}
