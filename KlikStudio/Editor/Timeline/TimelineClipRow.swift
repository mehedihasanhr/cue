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

    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8]

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

    // MARK: - A clip

    private func clipBody(_ clip: Clip, at index: Int) -> some View {
        let start = model.timeline.start(ofClipAt: index)
        let left = viewport.x(for: start)
        let width = max(4, clip.duration.seconds * viewport.pointsPerSecond)

        let isDragged = reorder?.id == clip.id
        return TimelineChipBackground(tint: TimelinePalette.clip, isSelected: isSelected(clip))
            .overlay {
                if let card = clip.title {
                    titleFace(card, width: width)
                } else {
                    filmstrip(clip, left: left, width: width)
                }
            }
            // The ruler's lines, only where there are no pictures to carry the eye: over
            // a filmstrip they are one more set of vertical lines among the pictures' own
            // edges.
            .overlay { if !model.thumbnails.isAvailable { marks(left: left, width: width) } }
            .frame(width: width, height: height)
            .overlay { badge(clip, width: width) }
            .overlay { sourceTimes(clip, width: width) }
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

    /// The clip's length and speed, as a small pill in its top-left corner.
    ///
    /// It was centred on the clip, a wide dark lozenge sitting in the middle of the
    /// pictures — the one place on the lane the eye goes to *see* the footage. In the corner
    /// it reads the way a zoom chip's scale does: a small fact about the piece, out of the
    /// way of the piece itself, and it stays put under a trim of the far end.
    ///
    /// Offered longest first, like every chip's words (see `TimelineChipLabel`): the length
    /// and the speed, then the length alone, then nothing — never a pill cut in half.
    private func badge(_ clip: Clip, width: Double) -> some View {
        let grip = TimelineLayout.gripBar(forChipWidth: width)
        let room = max(0, TimelineLayout.labelRoom(forChipWidth: width) - 4)
        return ViewThatFits(in: .horizontal) {
            pill { details(clip) }
            pill { Text(Timecode.length(clip.duration)) }
            Color.clear.frame(width: 0, height: 0)
        }
        .frame(width: room, alignment: .leading)
        .padding(.leading, grip + 4)
        .padding(.top, 4)
        .frame(width: width, height: height, alignment: .topLeading)
    }

    /// Dark glass and white type, the same on pictures, on a plain chip, and in either
    /// appearance — white on a white web page is nothing, so the words bring their own
    /// surface.
    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
            // The speed menu is a system control, and it draws its title in the window's
            // label colour whatever it is told: dark grey on this dark pill, in light mode.
            // Saying the pill is dark is what makes it draw light.
            .environment(\.colorScheme, .dark)
            .fixedSize()
    }

    /// The clip's length, and its speed as a menu — or, for a clip that holds, what it
    /// holds, since it has no speed to change.
    @ViewBuilder
    private func details(_ clip: Clip) -> some View {
        if !clip.isFootage {
            HStack(spacing: 4) {
                Image(systemName: clip.isTitle ? "textformat" : "snowflake")
                    .font(.system(size: 9, weight: .semibold))
                Text(clip.isTitle ? "Title" : "Freeze")
                Text(Timecode.length(clip.duration))
            }
        } else {
            HStack(spacing: 5) {
                Text(Timecode.length(clip.duration))
                // A hairline between the two facts, so "34s" and "1×" do not run together
                // into one number.
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 1, height: 9)
                Menu {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Button(Self.speedLabel(speed)) { model.setSpeed(speed, of: clip.id) }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "timer").font(.system(size: 9, weight: .semibold))
                        Text(Self.speedLabel(clip.speed))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Playback speed")
            }
        }
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

    /// Pictures of what the clip shows, one every so often along it.
    ///
    /// Inside a frame of the clip's own colour, so it still reads as the orange clip it
    /// is, and under a shade that deepens towards the bottom, where the times sit. Only
    /// the pictures on screen are drawn or asked for.
    private func filmstrip(_ clip: Clip, left: Double, width: Double) -> some View {
        // A clip of a movie brought in shows that movie's pictures.
        let thumbnails = model.thumbnails(for: clip)
        let inset = 2.0
        let slot = max(24, (height - inset * 2) * thumbnails.aspect)
        let pointsPerSecond = viewport.pointsPerSecond
        let visibleWidth = viewport.width
        // Read here rather than inside the canvas, so a picture arriving redraws this.
        let version = thumbnails.version
        return Canvas { context, size in
            _ = version
            let from = max(0, -left)
            let to = min(width, visibleWidth - left)
            guard to > from, pointsPerSecond > 0 else { return }
            let spacing = slot / pointsPerSecond * clip.speed
            let frame = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            context.clip(to: Path(roundedRect: frame, cornerRadius: max(2, radius - inset), style: .continuous))
            for index in Int(from / slot)...Int(to / slot) {
                let x = inset + Double(index) * slot
                guard x < size.width - inset else { break }
                // The picture from the middle of the stretch it stands for — which, for a
                // freeze frame, is the one frame it holds.
                let middle = min(width, x + slot / 2)
                let source = clip.isStill
                    ? clip.sourceStart.seconds
                    : clip.sourceStart.seconds + middle / pointsPerSecond * clip.speed
                let latest = clip.isStill ? source : clip.sourceEnd.seconds - 0.05
                guard let image = thumbnails.image(near: min(source, latest),
                                                   every: max(spacing, 0.05)) else { continue }
                context.draw(Image(decorative: image, scale: 2),
                             in: CGRect(x: x, y: inset, width: slot, height: size.height - inset * 2))
            }
            context.fill(Path(frame), with: .linearGradient(
                Gradient(colors: [.black.opacity(0.12), .black.opacity(0.55)]),
                startPoint: CGPoint(x: 0, y: inset), endPoint: CGPoint(x: 0, y: size.height - inset)))
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// A faint line at every mark on the ruler, carried down into the footage so a cut
    /// can be lined up against the time above it without reading the numbers.
    ///
    /// Only the marks on screen are built, as one path: a clip zoomed far in is hundreds of
    /// thousands of points wide, and it is the part in view that needs lines.
    private func marks(left: Double, width: Double) -> some View {
        let step = TimelineRuler.step(forPointsPerSecond: viewport.pointsPerSecond)
        let visible = viewport.visibleSeconds
        let from = max(viewport.seconds(at: left), visible.lowerBound)
        let to = min(viewport.seconds(at: left + width), visible.upperBound)
        let path = Path { path in
            guard to > from else { return }
            var second = (from / step).rounded(.up) * step
            while second < to {
                let x = viewport.x(forSeconds: second) - left
                if x > 1, x < width - 1 {
                    path.addRect(CGRect(x: x, y: 0, width: 1, height: height))
                }
                second += step
            }
        }
        return path
            .fill(.white.opacity(0.13))
            .frame(width: width, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    /// Where this clip sits in the recording, at the ends where a trim moves it — or, for a
    /// clip of a movie brought in, in that movie, with the movie's name so the two cannot
    /// be read as the same clock.
    private func sourceTimes(_ clip: Clip, width: Double) -> some View {
        let file = model.mediaName(of: clip).map { "\($0) · " } ?? ""
        return HStack {
            if clip.isStill {
                Text("\(file)Holds \(Timecode.short(clip.sourceStart))")
                    .lineLimit(1)
                Spacer()
            } else if clip.isFootage {
                Text(file + Timecode.short(clip.sourceStart))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text(Timecode.short(clip.sourceEnd))
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
        // Clear of the handles, and pinned to the two ends rather than centred, so each
        // number stays under the edge it describes while that edge is dragged.
        .padding(.horizontal, TimelineHandle.target + 3)
        // Along the bottom, below the badge. On the badge's own line the start time was
        // drawn straight through the clip's length, and "0:00" under "12s" read as "0:12s".
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
        .opacity(width > 190 ? 1 : 0)
        .animation(StudioMotion.state, value: width > 190)
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
                .background(Color.yellow, in: Circle())
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
