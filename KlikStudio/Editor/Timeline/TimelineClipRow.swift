import AppKit
import CoreMedia
import SwiftUI
import TimelineKit

/// The footage: what plays, for how long, and where it came from.
struct TimelineClipRow: View {
    let model: EditorModel
    let height: CGFloat

    @State private var trimOrigin: Clip?

    private var viewport: TimelineViewport { model.viewport }
    private let handleWidth: CGFloat = 10

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

    private func isSelected(_ clip: Clip) -> Bool { model.selection == .clip(clip.id) }

    // MARK: - A clip

    private func clipBody(_ clip: Clip, at index: Int) -> some View {
        let start = model.timeline.start(ofClipAt: index)
        let left = viewport.x(for: start)
        let width = max(4, clip.duration.seconds * viewport.pointsPerSecond)

        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.orange.opacity(isSelected(clip) ? 0.5 : 0.32))
            .overlay {
                if let peaks = model.waveform.peaks {
                    TimelineWaveform(model: model, peaks: peaks, height: height)
                        .mask {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .frame(width: width)
                                .offset(x: left)
                        }
                        .offset(x: -left)
                        .frame(width: width, alignment: .leading)
                        .clipped()
                }
            }
            .overlay { badge(clip, width: width) }
            .overlay { sourceTimes(clip, width: width) }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected(clip) ? 0.9 : 0), lineWidth: 1.5)
            }
            .frame(width: width, height: height)
            .offset(x: left)
            .contentShape(Rectangle())
            .onTapGesture { model.select(.clip(clip.id)) }
            .overlay {
                handle(clip, at: index, leading: true).offset(x: left)
                handle(clip, at: index, leading: false).offset(x: left + width - handleWidth)
            }
            .contextMenu { menu(clip, at: index) }
    }

    /// Length and speed, the way the reference puts them: one chip in the middle.
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
        .opacity(width > 110 ? 1 : 0)
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
        .padding(.horizontal, 6)
        .opacity(width > 150 ? 1 : 0)
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

    private func handle(_ clip: Clip, at index: Int, leading: Bool) -> some View {
        Rectangle()
            .fill(.white.opacity(0.001))
            .frame(width: handleWidth, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(trim(clip, at: index, leading: leading))
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
                model.document.endInteraction()
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
            .offset(x: x, y: (height - 26) / 2)
            .help(head ? "Put back \(Timecode.length(trimmed)) from the start"
                       : "Put back \(Timecode.length(trimmed)) from the end")
        }
    }

    private func trimmedAway(head: Bool, clip: Clip) -> CMTime? {
        head ? clip.sourceStart : model.timeline.sourceDuration - clip.sourceEnd
    }
}
