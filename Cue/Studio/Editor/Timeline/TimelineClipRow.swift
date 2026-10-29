import AppKit
import CoreMedia
import SwiftUI
import TimelineKit

/// The footage: what plays, for how long, and where it came from.
struct TimelineClipRow: View {
    let model: EditorModel
    let height: CGFloat

    @State private var trimOrigin: Clip?
    /// The whole timeline as the trim found it; every step of the drag is one trim of this.
    @State private var trimSnapshot: Timeline?
    /// Which handle the pointer is over, as "<clip id>-<side>".
    @State private var hoveredHandle: String?
    /// A clip being dragged to another place in the order, and how far it has come.
    @State private var reorder: Reorder?

    private struct Reorder: Equatable {
        let id: UUID
        let index: Int
        var offset: CGFloat
    }

    private var viewport: TimelineViewport { model.viewport }
    private let radius: CGFloat = TimelineChipBackground.radius

    fileprivate static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.timeline.clips.enumerated()), id: \.element.id) { index, clip in
                clipBody(clip, at: index)
            }
            transitionMarkers
            reorderSlot
            trimBubble(head: true)
            trimBubble(head: false)
        }
        .frame(height: height)
    }

    private func isSelected(_ clip: Clip) -> Bool { model.isSelected(.clip(clip.id)) }

    private func endMarks(width: CGFloat) -> some View {
        HStack {
            mark
            Spacer(minLength: 0)
            mark
        }
        .padding(.horizontal, 5)
        .frame(width: width, height: height)
        .opacity(width > 24 ? 1 : 0)
        .allowsHitTesting(false)
    }

    private var mark: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(.white.opacity(0.9))
            .frame(width: 2, height: min(14, height * 0.45))
    }

    // MARK: - A clip

    private func clipBody(_ clip: Clip, at index: Int) -> some View {
        let start = model.timeline.start(ofClipAt: index)
        let left = viewport.x(for: start)
        let width = max(4, clip.duration.seconds * viewport.pointsPerSecond)

        let isDragged = reorder?.id == clip.id
        return TimelineChipBackground(tint: StudioTheme.Surface.clip, isSelected: isSelected(clip), isPrimary: true)
            .overlay {
                // Footage says what it is, how long and how fast, as the reference's
                // does ("Clip" over "15s ⊘ 1×"); a title card says what it says.
                if let card = clip.title {
                    titleFace(card, width: width)
                } else {
                    TimelineChipLabel(title: clip.isFootage ? "Clip" : "Freeze", height: height, width: width) {
                        Text(Self.length(clip.duration.seconds))
                        Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 9.5, weight: .semibold))
                        Text(Self.speedLabel(clip.speed))
                    } compact: {
                        Text(Self.length(clip.duration.seconds))
                    }
                    .allowsHitTesting(false)
                }
            }
            // A short white bar inside each end, always: the ends are where a clip is
            // trimmed, and they say so before the pointer finds them.
            .overlay { endMarks(width: width) }
            .frame(width: width, height: height)
            // Its length and speed on hover, where the plain bar has nothing to say.
            .help(Timecode.length(clip.duration) + (clip.speed == 1 ? "" : " at \(clip.speed.formatted())×"))
            // A clip that holds has no in-point to move, only a length — so only its far
            // end has a grip, and that grip makes it longer or shorter.
            .overlay(alignment: .leading) {
                if clip.isFootage { handle(clip, at: index, leading: true, width: width) }
            }
            .overlay(alignment: .trailing) { handle(clip, at: index, leading: false, width: width) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            // Lifted while it is carried to another place in the order.
            .shadow(color: .black.opacity(isDragged ? 0.35 : 0), radius: 6, y: 2)
            .opacity(isDragged ? 0.92 : 1)
            .offset(x: isDragged ? reorder?.offset ?? 0 : 0)
            .zIndex(isDragged ? 1 : 0)
            .gesture(reorderGesture(clip, at: index))
            // ⌘ adds to the selection, for deleting or re-speeding several pieces of a
            // split at once. A clip is dragged on its own, to another place in the order,
            // never with the group — the sequence is contiguous by construction, so a clip
            // has no position of its own to slide, only a place between two others.
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

    /// A title's own words, in place of pictures of footage it has none of.
    private func titleFace(_ card: TitleCard, width: Double) -> some View {
        let words = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(words.isEmpty ? card.subtitle : words)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, TimelineHandle.target + 4)
            .frame(width: width, height: height, alignment: .bottomLeading)
            .padding(.bottom, 4)
            .opacity(width > 90 ? 1 : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func menu(_ clip: Clip, at index: Int) -> some View {
        Button("Split Here") { model.splitAtPlayhead() }
            .disabled(clip.isTitle)
        if clip.isFootage {
            Menu("Speed") {
                ForEach(Self.speeds, id: \.self) { speed in
                    Button(Self.speedLabel(speed)) { model.setSpeed(speed, of: clip.id) }
                }
            }
        }
        Button("Freeze Frame at Playhead") { model.freezeFrameAtPlayhead() }
            .disabled(!model.canFreezeFrame)
        Divider()
        Button("Move Clip Earlier") { model.moveClip(from: index, to: index - 1) }
            .disabled(index == 0)
        Button("Move Clip Later") { model.moveClip(from: index, to: index + 1) }
            .disabled(index >= model.timeline.clips.count - 1)
        if index > 0 {
            Menu("Transition In") { transitionMenu(clip) }
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

    /// A clip's length as the chip says it: "15s", "1.5s", "1:05".
    static func length(_ seconds: Double) -> String {
        if seconds >= 60 {
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return seconds < 10 && seconds != seconds.rounded() ? "\(seconds.formatted(.number.precision(.fractionLength(1))))s" : "\(Int(seconds.rounded()))s"
    }

    static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
    }

    // MARK: - Trimming

    /// A grabbable end of a clip — see `TimelineHandle`. It used to be invisible
    /// (`white.opacity(0.001)`), which made trimming footage a feature you had to be told
    /// about.
    private func handle(_ clip: Clip, at index: Int, leading: Bool, width: CGFloat) -> some View {
        let key = "\(clip.id)-\(leading)"
        let isHovered = hoveredHandle == key
        return TimelineHandle(leading: leading,
                              height: height,
                              chipWidth: width,
                              radius: radius,
                              isVisible: isSelected(clip) || isHovered,
                              isHovered: isHovered,
                              label: clip.isFootage
                                  ? (leading ? "Drag to trim the start of this clip"
                                             : "Drag to trim the end of this clip")
                                  : "Drag to make this \(clip.isTitle ? "title" : "freeze frame") longer or shorter")
            .onHover { inside in
                // See `TimelineRegionRow.edge` — hover is noise while a trim is running.
                guard !model.isGesturing else { return }
                hoveredHandle = inside ? key : (hoveredHandle == key ? nil : hoveredHandle)
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(trim(clip, at: index, leading: leading))
    }

    private func trim(_ clip: Clip, at index: Int, leading: Bool) -> some Gesture {
        // The window's coordinates, not the clip's — see `TimelineRegionRow.drag(_:grip:)`.
        // A trim moves the clip's own edge, so its local space moves under the gesture that
        // is driving it.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let origin = beginTrim(clip)
                let before = trimSnapshot ?? model.timeline
                // A freeze frame or a title: the far end is its length, in timeline time,
                // since there is no footage under it to measure in.
                if let hold = origin.hold {
                    let length = hold + CMTime(seconds: value.translation.width / viewport.pointsPerSecond,
                                               preferredTimescale: 600)
                    model.apply(Commands.FromSnapshot(Commands.SetHold(clipID: clip.id, to: length), on: before))
                    return
                }
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
                        let previous = before.clips[index - 1]
                        if abs((previous.sourceEnd - origin.sourceStart).seconds) < 0.001 {
                            head = max(head, previous.sourceEnd)
                        }
                    }
                    model.apply(Commands.FromSnapshot(Commands.TrimClip(clipID: clip.id, head: head), on: before))
                } else {
                    var tail = origin.sourceEnd + delta
                    if index < before.clips.count - 1, !NSEvent.modifierFlags.contains(.option) {
                        let next = before.clips[index + 1]
                        if abs((next.sourceStart - origin.sourceEnd).seconds) < 0.001 {
                            tail = min(tail, next.sourceStart)
                        }
                    }
                    model.apply(Commands.FromSnapshot(Commands.TrimClip(clipID: clip.id, tail: tail), on: before))
                }
            }
            .onEnded { _ in
                trimOrigin = nil
                trimSnapshot = nil
                model.finishInteraction()
            }
    }

    private func beginTrim(_ clip: Clip) -> Clip {
        if let trimOrigin { return trimOrigin }
        trimOrigin = clip
        trimSnapshot = model.timeline
        model.select(.clip(clip.id))
        model.document.beginInteraction(clip.isFootage ? "Trim" : "Change Length")
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
        // Only where the end of the edit is footage: a title or a freeze frame there has
        // nothing trimmed off it to put back.
        if let clip = head ? model.timeline.clips.first : model.timeline.clips.last, clip.isFootage,
           let trimmed = trimmedAway(head: head, clip: clip), trimmed.seconds > 0.05 {
            let x = head
                ? viewport.x(for: .zero) - 30
                : viewport.x(for: model.duration) + 6

            Button {
                model.apply(Commands.TrimClip(clipID: clip.id,
                                              head: head ? .zero : nil,
                                              tail: head ? nil : model.timeline.sourceDuration(of: clip)))
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "scissors").font(.system(size: 9, weight: .bold))
                    Text(Timecode.length(trimmed)).font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Color.yellow, in: StudioTheme.squircle(StudioTheme.Radius.regular))
                .contentShape(StudioTheme.squircle(StudioTheme.Radius.regular))
            }
            .buttonStyle(BarButtonStyle())
            .position(x: x + 13, y: height / 2)
            .help(head ? "Put back \(Timecode.length(trimmed)) from the start"
                       : "Put back \(Timecode.length(trimmed)) from the end")
        }
    }

    private func trimmedAway(head: Bool, clip: Clip) -> CMTime? {
        head ? clip.sourceStart : model.timeline.sourceDuration(of: clip) - clip.sourceEnd
    }
}

// MARK: - The speed on a clip's pill

/// A clip's speed, as a word on its pill that opens the kit's list of speeds.
///
/// It was a system `Menu` in its borderless style, which draws its title in the window's
/// label colour whatever it is told — dark grey on the dark pill in light mode — and opens
/// the system's own menu, the one list in the editor not drawn in the kit's hand. This is
/// the same word in the pill's white, brightening under the pointer, opening the list the
/// inspector's pop-ups open, with a check against the speed the clip plays at now.
private struct SpeedMenu: View {
    let model: EditorModel
    let clip: Clip

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "timer").font(.system(size: 9, weight: .semibold))
                Text(TimelineClipRow.speedLabel(clip.speed))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(isHovering || isPresented ? 1 : 0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hover, value: isHovering)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StudioMenuList(sections: [
                .init(title: nil, rows: TimelineClipRow.speeds.map { speed in
                    .init(title: TimelineClipRow.speedLabel(speed),
                          systemImage: nil,
                          thumbnail: nil,
                          isChecked: speed == clip.speed,
                          isEnabled: true) { model.setSpeed(speed, of: clip.id) }
                })
            ], showsChecks: true)
        }
        .fixedSize()
        .help("Playback speed")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(TimelineClipRow.speedLabel(clip.speed))
    }
}

// MARK: - Moving a clip, and the cuts between clips

extension TimelineClipRow {
    /// Carrying a clip to another place in the order.
    ///
    /// The clip follows the pointer, the others stay where they are, and a line shows the
    /// cut it will land in; letting go is one `MoveClip`, so one step to undo, with what
    /// was placed on the clip going along with it. A drag that ends where it started does
    /// nothing, and is not an edit.
    private func reorderGesture(_ clip: Clip, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard model.timeline.clips.count > 1 else { return }
                if reorder == nil { model.select(.clip(clip.id)) }
                reorder = Reorder(id: clip.id, index: index, offset: value.translation.width)
            }
            .onEnded { value in
                defer { reorder = nil }
                guard let reorder, reorder.id == clip.id else { return }
                let target = destination(of: reorder.index, offset: value.translation.width)
                guard target != reorder.index else { return }
                model.moveClip(from: reorder.index, to: target)
            }
    }

    /// Where a clip dropped at `offset` from its place goes: after every other clip whose
    /// middle it has passed. An index among the clips once it has been taken out, which is
    /// what `ClipSequence.move` asks for.
    private func destination(of index: Int, offset: CGFloat) -> Int {
        let clips = model.timeline.clips
        guard clips.indices.contains(index) else { return index }
        let middle = viewport.x(for: model.timeline.start(ofClipAt: index))
            + clips[index].duration.seconds * viewport.pointsPerSecond / 2 + offset
        return clips.indices.filter { other in
            guard other != index else { return false }
            let start = viewport.x(for: model.timeline.start(ofClipAt: other))
            return start + clips[other].duration.seconds * viewport.pointsPerSecond / 2 < middle
        }.count
    }

    /// The cut a carried clip will land in, drawn between the clips it will land between.
    @ViewBuilder
    private var reorderSlot: some View {
        if let reorder, reorder.offset != 0 {
            let target = destination(of: reorder.index, offset: reorder.offset)
            let others = model.timeline.clips.indices.filter { $0 != reorder.index }
            // The edge after the last clip it has passed, or before the first.
            let x: Double = if target == 0, let first = others.first {
                viewport.x(for: model.timeline.start(ofClipAt: first))
            } else if others.indices.contains(target - 1) {
                viewport.x(for: model.timeline.start(ofClipAt: others[target - 1])
                           + model.timeline.clips[others[target - 1]].duration)
            } else {
                viewport.x(for: model.duration)
            }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: height + 6)
                .position(x: x, y: height / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Transitions

    /// A mark on every cut that has a transition, saying which.
    ///
    /// Clicking it selects the clip that arrives through it, where the inspector has the
    /// transition's controls; its menu changes the transition without going there.
    private var transitionMarkers: some View {
        ForEach(Array(model.timeline.clips.enumerated()), id: \.element.id) { index, clip in
            if let transition = model.timeline.transition(into: index) {
                let x = viewport.x(for: model.timeline.start(ofClipAt: index))
                let width = max(10, transition.duration.seconds * viewport.pointsPerSecond)
                Image(systemName: Self.symbol(for: transition.style))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(Color.white, in: Circle())
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                    // The stretch the transition takes, under the mark, so its length can
                    // be read off the lane against the ruler.
                    .background {
                        Capsule()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: width, height: 4)
                    }
                    .contentShape(Circle())
                    .onTapGesture { model.select(.clip(clip.id)) }
                    .contextMenu { transitionMenu(clip) }
                    .help("\(transition.style.title), \(Self.seconds(transition.duration.seconds)) — click to edit")
                    .accessibilityElement()
                    .accessibilityLabel("\(transition.style.title) into clip \(index + 1)")
                    .accessibilityAddTraits(.isButton)
                    .position(x: x, y: 11)
            }
        }
    }

    /// The choices for how a clip arrives: the kinds, and how long it takes.
    @ViewBuilder
    func transitionMenu(_ clip: Clip) -> some View {
        Button {
            model.setTransitionStyle(clip.id, nil)
        } label: {
            if clip.transition == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
        }
        ForEach(ClipTransition.Style.allCases, id: \.self) { style in
            Button {
                model.setTransitionStyle(clip.id, style)
            } label: {
                if clip.transition?.style == style {
                    Label(style.title, systemImage: "checkmark")
                } else {
                    Text(style.title)
                }
            }
        }
        if let transition = clip.transition {
            Divider()
            Menu("Length") {
                ForEach(Self.transitionLengths, id: \.self) { seconds in
                    Button(Self.seconds(seconds)) {
                        model.setTransition(clip.id, ClipTransition(transition.style,
                                                                    duration: CMTime(seconds: seconds,
                                                                                     preferredTimescale: 600)))
                    }
                }
            }
        }
    }

    static let transitionLengths: [Double] = [0.2, 0.4, 0.6, 1, 1.5, 2]

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    static func symbol(for style: ClipTransition.Style) -> String {
        switch style {
        case .crossfade: "circle.lefthalf.filled"
        case .dipToBlack: "circle.fill"
        case .dipToBackground: "circle.dashed"
        }
    }
}
