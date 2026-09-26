import AppKit
import CoreMedia
import SwiftUI
import TimelineKit

/// The footage: what plays, for how long, and where it came from.
struct TimelineClipRow: View {
    let model: EditorModel
    let height: CGFloat

    @State private var trimOrigin: Clip?
    /// Which handle the pointer is over, as "<clip id>-<side>".
    @State private var hoveredHandle: String?

    private var viewport: TimelineViewport { model.viewport }
    private let handleWidth: CGFloat = 10
    private let radius: CGFloat = 6

    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.timeline.clips.enumerated()), id: \.element.id) { index, clip in
                clipBody(clip, at: index)
            }
            trimBubble(head: true)
            trimBubble(head: false)
        }
        .frame(height: height)
    }

    private func isSelected(_ clip: Clip) -> Bool { model.isSelected(.clip(clip.id)) }

    // MARK: - A clip

    private func clipBody(_ clip: Clip, at index: Int) -> some View {
        let start = model.timeline.start(ofClipAt: index)
        let left = viewport.x(for: start)
        let width = max(4, clip.duration.seconds * viewport.pointsPerSecond)

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.orange.opacity(isSelected(clip) ? 0.5 : 0.32))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected(clip) ? 0.9 : 0), lineWidth: 1.5)
            }
            .frame(width: width, height: height)
            .overlay(alignment: .leading) { badge(clip, width: width) }
            .overlay { sourceTimes(clip, width: width) }
            .overlay(alignment: .leading) { handle(clip, at: index, leading: true, width: width) }
            .overlay(alignment: .trailing) { handle(clip, at: index, leading: false, width: width) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            // ⌘ adds to the selection, for deleting or re-speeding several pieces of a
            // split at once. A clip cannot be *dragged* with the group — the sequence is
            // contiguous by construction, so a clip has no position of its own to slide.
            .onTapGesture {
                model.select(.clip(clip.id),
                             extending: NSEvent.modifierFlags.contains(.command))
            }
            .contextMenu { menu(clip, at: index) }
            // Placed, not drawn-offset. See `TimelineRegionRow.body(for:)` for what the
            // offset this replaces did to hit testing — here it meant that after a split
            // only the last piece could be clicked, because every piece's hit area was
            // stacked on the first one's.
            .position(x: left + width / 2, y: height / 2)
    }

    /// Length and speed, held against the clip's leading edge.
    ///
    /// It used to sit in the middle, which meant it slid for the whole of a trim: the
    /// clip's centre moves at half the speed of the edge being dragged, so the numbers
    /// drifted while the footage they describe stood still. See
    /// `TimelineRegionRow.label(_:width:)`.
    private func badge(_ clip: Clip, width: Double) -> some View {
        HStack(spacing: 6) {
            Text(Timecode.length(clip.duration))
            Menu {
                ForEach(Self.speeds, id: \.self) { speed in
                    Button(Self.speedLabel(speed)) { model.setSpeed(speed, of: clip.id) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "timer").font(.system(size: 9))
                    Text(Self.speedLabel(clip.speed))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.black.opacity(0.28), in: Capsule())
        .fixedSize()
        .padding(.leading, handleWidth + 5)
        // Faded rather than switched off: this changes mid-trim, and a badge blinking out
        // under the pointer reads as something breaking.
        .opacity(width > 130 ? 1 : 0)
        .animation(StudioMotion.state, value: width > 130)
    }

    /// Where this clip sits in the recording, at the ends where a trim moves it.
    private func sourceTimes(_ clip: Clip, width: Double) -> some View {
        HStack {
            Text(Timecode.short(clip.sourceStart))
            Spacer()
            Text(Timecode.short(clip.sourceEnd))
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.white.opacity(0.65))
        // Clear of the handles, and pinned to the two ends rather than centred, so each
        // number stays under the edge it describes while that edge is dragged.
        .padding(.horizontal, handleWidth + 4)
        .opacity(width > 190 ? 1 : 0)
        .animation(StudioMotion.state, value: width > 190)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func menu(_ clip: Clip, at index: Int) -> some View {
        Button("Split Here") { model.splitAtPlayhead() }
        Menu("Speed") {
            ForEach(Self.speeds, id: \.self) { speed in
                Button(Self.speedLabel(speed)) { model.setSpeed(speed, of: clip.id) }
            }
        }
        Divider()
        // The clipboard verbs, aimed at the clip under the pointer rather than at the
        // selection — the same choice `TimelineRegionRow`'s menu makes, and for the reason
        // given on `EditorModel.copyRegion(_:)`: a right-click must not quietly change what
        // the inspector is showing. Paste is the exception and takes no clip at all, because
        // pasting footage inserts it at the playhead; offering it here is only a shortcut to
        // the menu bar's item, in the place where the hand already is.
        Button("Cut") { model.cutRegion(.clip(clip.id)) }
            .disabled(model.timeline.clips.count < 2)
        Button("Copy") { model.copyRegion(.clip(clip.id)) }
        Button("Duplicate") { model.duplicateRegion(.clip(clip.id)) }
        Button("Paste at Playhead") { model.pasteAtPlayhead() }
            .disabled(!model.canPasteRegion)
        Divider()
        Button("Delete", role: .destructive) {
            model.select(.clip(clip.id))
            model.deleteSelection()
        }
        .disabled(model.timeline.clips.count < 2)
    }

    static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
    }

    // MARK: - Trimming

    /// A grabbable end of a clip, drawn the way a region's is: a solid bar in the lane's
    /// colour, full height, carrying the clip's corners on its outside.
    ///
    /// Shown on the selected clip and on whichever end the pointer is over. It used to be
    /// invisible everywhere — `white.opacity(0.001)` — which made trimming a thing you had
    /// to already know about.
    private func handle(_ clip: Clip, at index: Int, leading: Bool, width: CGFloat) -> some View {
        let key = "\(clip.id)-\(leading)"
        let isHovered = hoveredHandle == key
        let bar = max(2, min(handleWidth, width / 3))
        return UnevenRoundedRectangle(topLeadingRadius: leading ? radius : 0,
                                      bottomLeadingRadius: leading ? radius : 0,
                                      bottomTrailingRadius: leading ? 0 : radius,
                                      topTrailingRadius: leading ? 0 : radius,
                                      style: .continuous)
            .fill(Color.orange.opacity(isSelected(clip) ? (isHovered ? 1 : 0.85) : (isHovered ? 0.85 : 0)))
            .frame(width: bar, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                // See `TimelineRegionRow.edge` — hover is noise while a trim is running.
                guard !model.isGesturing else { return }
                hoveredHandle = inside ? key : (hoveredHandle == key ? nil : hoveredHandle)
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(trim(clip, at: index, leading: leading))
            .animation(StudioMotion.state, value: isHovered)
    }

    private func trim(_ clip: Clip, at index: Int, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = beginTrim(clip)
                // Points on the timeline are source seconds divided by speed, so a drag
                // has to be multiplied back up to reach the footage.
                let delta = CMTime(seconds: value.translation.width / viewport.pointsPerSecond * origin.speed,
                                   preferredTimescale: 600)
                if leading {
                    var head = origin.sourceStart + delta
                    // A clip in the middle may not trim back into footage the clip
                    // before it is already showing: legal in the model, but it silently
                    // plays the same seconds twice, which is never what a drag meant.
                    if index > 0, !NSEvent.modifierFlags.contains(.option) {
                        let previous = model.timeline.clips[index - 1]
                        if abs((previous.sourceEnd - origin.sourceStart).seconds) < 0.001 {
                            head = max(head, previous.sourceEnd)
                        }
                    }
                    model.apply(Commands.TrimClip(clipID: clip.id, head: head))
                } else {
                    var tail = origin.sourceEnd + delta
                    if index < model.timeline.clips.count - 1, !NSEvent.modifierFlags.contains(.option) {
                        let next = model.timeline.clips[index + 1]
                        if abs((next.sourceStart - origin.sourceEnd).seconds) < 0.001 {
                            tail = min(tail, next.sourceStart)
                        }
                    }
                    model.apply(Commands.TrimClip(clipID: clip.id, tail: tail))
                }
            }
            .onEnded { _ in
                trimOrigin = nil
                model.finishInteraction()
            }
    }

    private func beginTrim(_ clip: Clip) -> Clip {
        if let trimOrigin { return trimOrigin }
        trimOrigin = clip
        model.select(.clip(clip.id))
        model.document.beginInteraction("Trim")
        return clip
    }

    // MARK: - What was trimmed away

    /// The footage that exists in the recording but is not in the edit.
    ///
    /// Not a separate object: this *is* the first or last clip's trim, shown as a bubble
    /// because there is something behind it to get back. That is why the reference draws
    /// a pair of scissors in it.
    @ViewBuilder
    private func trimBubble(head: Bool) -> some View {
        if let clip = head ? model.timeline.clips.first : model.timeline.clips.last,
           let trimmed = trimmedAway(head: head, clip: clip), trimmed.seconds > 0.05 {
            let x = head
                ? viewport.x(for: .zero) - 30
                : viewport.x(for: model.duration) + 6

            Button {
                model.apply(Commands.TrimClip(clipID: clip.id,
                                              head: head ? .zero : nil,
                                              tail: head ? nil : model.timeline.sourceDuration))
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "scissors").font(.system(size: 9, weight: .bold))
                    Text(Timecode.length(trimmed)).font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Color.yellow, in: Circle())
            }
            .buttonStyle(BarButtonStyle())
            .position(x: x + 13, y: height / 2)
            .help(head ? "Put back \(Timecode.length(trimmed)) from the start"
                       : "Put back \(Timecode.length(trimmed)) from the end")
        }
    }

    private func trimmedAway(head: Bool, clip: Clip) -> CMTime? {
        head ? clip.sourceStart : model.timeline.sourceDuration - clip.sourceEnd
    }
}
