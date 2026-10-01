import CoreMedia
import SwiftUI
import TimelineKit

/// Following, on the Mask panel: start it, watch it, stop it, and see where it gave up.
struct MaskFollowControls: View {
    let model: EditorModel
    let mask: BlurRegion

    private var job: MaskFollowingJob { model.following }
    private var isFollowingThis: Bool { job.maskID == mask.id }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            if isFollowingThis {
                running
            } else {
                follow
                if mask.follows { following }
            }
        }
        .font(.system(size: 12))
    }

    /// The button, and — when it cannot be pressed — why, written beside it.
    private var follow: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.withinControl) {
            Button {
                model.followSelectedMask()
            } label: {
                Label(mask.follows ? "Follow Again from Here" : "Follow Content",
                      systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(!model.canFollowSelectedMask)
            .help("Keep the mask on what is under it while it moves or scrolls. Moves the mask with what is under it, from the playhead to both ends.")

            // Only why it cannot: a dimmed button with no reason beside it looks broken.
            if let why = model.whyMaskCannotFollow {
                InspectorNote(why)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: job.progress)
                    .controlSize(.small)
                Text("\(Int((job.progress * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Following…")
                    .foregroundStyle(.secondary)
                Spacer()
                SectionButton(title: "Cancel") { model.cancelFollowing() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Following content")
    }

    /// What a following mask says about itself.
    private var following: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                InspectorLabel("Follows its content")
                Spacer()
                SectionButton(title: "Stop Following") { model.stopFollowingSelectedMask() }
            }
            ForEach(model.selectedMaskLosses, id: \.seconds) { moment in
                HStack {
                    Label("Lost it at \(Timecode.precise(moment))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    SectionButton(title: "Show") { model.scrub(to: moment) }
                }
                .help("From here the mask holds still. Check that it still covers what it should.")
            }
        }
    }
}

/// Follow and Stop Following, in a mask's menu on the picture.
struct MaskFollowMenu: View {
    let model: EditorModel
    let id: UUID

    var body: some View {
        // Selected first: both act on the selected mask, as the Mask menu does.
        Button("Follow Content") {
            model.select(.blur(id))
            model.followSelectedMask()
        }
        .disabled(model.following.isRunning || !(model.timeline.blurs.first { $0.id == id }?.contains(model.playhead) ?? false))
        if model.timeline.blurs.first(where: { $0.id == id })?.follows == true {
            Button("Stop Following") {
                model.select(.blur(id))
                model.stopFollowingSelectedMask()
            }
        }
    }
}

/// The mark on a following mask's outline: that it follows, or that at this moment it has
/// lost what it was following and is holding still.
struct MaskFollowBadge: View {
    let isLost: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isLost ? "exclamationmark.triangle.fill" : "scope")
            if isLost { Text("Lost") }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(isLost ? Color.orange : Color.black.opacity(0.55), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityLabel(isLost ? "Lost what it was following" : "Follows its content")
    }
}
