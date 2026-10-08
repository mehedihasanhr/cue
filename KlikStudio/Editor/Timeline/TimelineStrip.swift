import CoreMedia
import SwiftUI
import TimelineKit

/// The edit, seen sideways: the ruler, and under it the lanes with the playhead across all
/// of them.
///
/// Scrub in the ruler or on empty background; click a row to select, drag it to move.
/// Everything that moves snaps to the cuts and to the other regions, in points rather
/// than seconds, so it feels the same however far the timeline is zoomed — up to the
/// point where the whole recording is on screen, where the tolerance is capped in time
/// so free positioning is still possible.
///
/// The lanes are described once, by `Lane`: which rows there are, how tall each is and
/// what colour it reads as — a question `height(for:)` asks before anything is drawn.
struct TimelineStrip: View {
    let model: EditorModel

    private var viewport: TimelineViewport { model.viewport }

    private static let rulerHeight: CGFloat = 30
    private static let clipHeight: CGFloat = 42
    /// Shorter than the clips and taller than a region lane: the sound is a thing you
    /// read rather than a chip you read the label off, and a waveform squeezed into 28
    /// points is a smear.
    private static let soundHeight: CGFloat = 30
    /// Tall enough for a chip's two lines — what it is, and what it says.
    private static let regionHeight: CGFloat = 24
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 4
    /// The room either side of the lanes, so the first clip does not sit on the rail.
    private static let sideInset: CGFloat = 8
    /// The lanes' own coordinate space.
    ///
    /// Named because two gestures need a frame of reference that does not move: the ruler,
    /// which scrolls with the viewport, and the playhead, which is dragged by the very
    /// gesture that moves it. Measuring either in its own local space is measuring against
    /// something the gesture is steering.
    static let space = "timeline-lanes"

    /// How wide the playhead's grab column is. The line is 1.5 points; this is what you
    /// can actually hit.
    private static let playheadGrab: CGFloat = 18

    // MARK: - What rows there are

    /// One row of the timeline: what it is, and therefore what it is called, how tall it
    /// is and what colour it reads as.
    ///
    /// An enum rather than a list of views because the gutter and the lanes have to agree
    /// about it, and because "which rows does this edit have" is a question two other
    /// places ask — `height(for:)`, so the window can size the strip before it draws, and
    /// the strip itself.
    enum Lane: Identifiable, Hashable {
        /// The footage. Called Video because that is what it is to the person editing,
        /// whatever the model calls it.
        case clips
        /// The recording's sound as one undifferentiated thing — a take made before the
        /// sources were captured separately.
        case recordedSound
        /// One of the recording's own sources: the screen, a microphone.
        case source(UUID)
        case zooms
        case pointer
        /// Sound from outside the recording: music, an imported voiceover.
        case addedSound
        case blurs
        case annotations
        /// What is said, a line at a time.
        case captions
        /// What was pressed, a shortcut at a time.
        case keys
        /// Where the camera and the screen go, a stretch at a time.
        case camera

        var id: String {
            switch self {
            case .clips: "clips"
            case .recordedSound: "sound"
            case .source(let id): "source-\(id)"
            case .zooms: "zooms"
            case .pointer: "pointer"
            case .addedSound: "added"
            case .blurs: "blurs"
            case .annotations: "annotations"
            case .captions: "captions"
            case .keys: "keys"
            case .camera: "camera"
            }
        }

        /// As tall as its busiest moment: a lane whose regions can overlap — notes, masks —
        /// stacks the ones that do. See `RegionStacking`.
        func height(in timeline: Timeline) -> CGFloat {
            switch self {
            case .clips: clipHeight
            case .recordedSound, .source: soundHeight
            case .annotations: stackedHeight(rows: min(stackLimit, RegionStacking.rowCount(of: timeline.annotations)))
            case .blurs: stackedHeight(rows: min(stackLimit, RegionStacking.rowCount(of: timeline.blurs)))
            case .zooms, .pointer, .addedSound, .captions, .keys, .camera: regionHeight
            }
        }

        /// The kind of thing on this row, in the words the person editing would use.
        func title(in timeline: Timeline) -> String {
            switch self {
            case .clips: "Video"
            case .recordedSound: "Audio"
            case .source(let id): timeline.soundTrack(id)?.name ?? "Audio"
            case .zooms: "Zoom"
            case .pointer: "Pointer"
            case .addedSound: "Sound"
            case .blurs: "Masks"
            case .annotations: "Notes"
            case .captions: "Captions"
            case .keys: "Keys"
            case .camera: "Camera"
            }
        }

        func symbol(in timeline: Timeline) -> String {
            switch self {
            case .clips: "film"
            case .recordedSound: "waveform"
            case .source(let id): timeline.soundTrack(id)?.symbol ?? "waveform"
            case .zooms: "plus.magnifyingglass"
            case .pointer: "cursorarrow.rays"
            case .addedSound: "music.note"
            case .blurs: "drop.halffull"
            case .annotations: "textformat"
            case .captions: "captions.bubble"
            case .keys: "keyboard"
            case .camera: "person.crop.rectangle"
            }
        }

        /// The same colour the row's own contents are drawn in, so the heading reads as
        /// belonging to what is beside it rather than as a list of its own.
        func tint(in timeline: Timeline) -> Color {
            switch self {
            case .clips: TimelinePalette.clip
            case .recordedSound: .green
            case .source(let id): timeline.soundTrack(id)?.source == .systemAudio ? .blue : .green
            case .zooms: TimelinePalette.zoom
            case .pointer: TimelinePalette.pointer
            case .addedSound: .green
            case .blurs: .teal
            case .annotations: .pink
            case .captions: .indigo
            case .keys: TimelineStrip.keysTint
            case .camera: TimelineStrip.cameraTint
            }
        }
    }

    /// The gap between stacked rows of one lane: less than between lanes, so a lane's rows
    /// still read as one lane.
    static let stackGap: CGFloat = 3

    /// The most rows a stacked lane shows at once. Past it the lane scrolls its rows, so a
    /// busy moment does not push the picture up the window one row at a time.
    static let stackLimit = 3

    static func stackedHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * regionHeight + CGFloat(max(0, rows - 1)) * stackGap
    }

    /// The Keys lane's colour, in one place: the heading, the chips and the inspector's
    /// list all draw in it.
    static let keysTint: Color = .mint

    /// The Camera lane's colour: the heading and the chips.
    static let cameraTint: Color = .purple

    /// The rows this edit has, top to bottom.
    ///
    /// - Parameter hasSound: whether the recording's sound can be drawn at all. Only
    ///   consulted for a recording with no separate sources — with sources there is a lane
    ///   per source, and each knows whether it has anything to draw.
    static func lanes(for timeline: Timeline, hasSound: Bool = true) -> [Lane] {
        var lanes: [Lane] = [.clips]
        if timeline.hasSeparateSound {
            lanes += timeline.soundTracks.map { .source($0.id) }
        } else if hasSound {
            lanes.append(.recordedSound)
        }
        lanes.append(.zooms)                                  // always shown
        // The rest appear only when there is something in them: five permanently empty
        // lanes would be most of the strip's height spent on features nothing has added to.
        if !timeline.cursorRegions.isEmpty { lanes.append(.pointer) }
        // Under the pointer lane, beside the other lanes about how the picture is framed.
        if !timeline.cameraLayouts.isEmpty { lanes.append(.camera) }
        if !timeline.audio.isEmpty { lanes.append(.addedSound) }
        if !timeline.blurs.isEmpty { lanes.append(.blurs) }
        if !timeline.annotations.isEmpty { lanes.append(.annotations) }
        if !timeline.captions.isEmpty { lanes.append(.captions) }
        if !timeline.keyCues.isEmpty { lanes.append(.keys) }
        return lanes
    }

    /// Tall enough for the rows this edit actually has.
    static func height(for timeline: Timeline, hasSound: Bool = true) -> CGFloat {
        padding * 2 + rulerHeight + spacing
            + lanes(for: timeline, hasSound: hasSound)
                .reduce(0) { $0 + $1.height(in: timeline) + spacing }
            - spacing
    }

    private var lanes: [Lane] {
        Self.lanes(for: model.timeline, hasSound: model.waveform.state != .unavailable)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            // No gutter of lane names: each lane is told apart by its colour, and its
            // name is on every chip's tooltip. The lanes get the whole width.
            let laneWidth = max(0, proxy.size.width - Self.sideInset * 2)
            lanesColumn
                .frame(width: laneWidth, alignment: .topLeading)
                .padding(.horizontal, Self.sideInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { Color.clear.studioSurface() }
            .onAppear { viewport.setWidth(laneWidth, duration: model.duration) }
            // The viewport measures the lanes, not the window: it maps seconds to points
            // inside the part of the strip that shows the edit, and handing it the whole
            // width would put every cut a gutter's worth to the right of where it is drawn.
            .onChange(of: laneWidth) { _, width in
                viewport.setWidth(width, duration: model.duration)
            }
            .onChange(of: model.duration) { _, duration in
                // Not mid-drag: a trim being dragged would rescale under the pointer.
                guard !model.isGesturing else { return }
                viewport.durationChanged(duration)
            }
            .onChange(of: model.isGesturing) { _, gesturing in
                if !gesturing { viewport.durationChanged(model.duration) }
            }
        }
        .background { Color.clear.studioSurface() }
    }

    // MARK: - The lanes

    private var lanesColumn: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            TimelineRuler(model: model, height: Self.rulerHeight)
            ForEach(lanes) { lane in
                content(lane)
            }
        }
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // Clicking past the end of everything clears the selection, which is the
            // only way out of one that does not involve the Escape key.
            Color.clear
                .studioSurface()
                .overlay(alignment: .topLeading) { beyondEnd }
                .contentShape(Rectangle())
                .onTapGesture { model.clearSelection() }
        }
        .overlay(alignment: .topLeading) { playhead }
        .overlay { events }
        .clipped()
        .coordinateSpace(.named(Self.space))
    }

    @ViewBuilder
    private func content(_ lane: Lane) -> some View {
        switch lane {
        case .clips:
            TimelineClipRow(model: model, height: Self.clipHeight)
        case .recordedSound:
            TimelineSoundRow(model: model, height: Self.soundHeight)
        case .source(let id):
            if let track = model.timeline.soundTrack(id) {
                TimelineSoundRow(model: model, height: Self.soundHeight, track: track)
            }
        case .zooms:
            zoomRow
        case .pointer:
            cursorRow
        case .addedSound:
            addedSoundRow
        case .blurs:
            blurRow
        case .annotations:
            annotationRow
        case .captions:
            captionRow
        case .keys:
            keyRow
        case .camera:
            cameraRow
        }
    }

    /// The shortcuts, each chip labelled with the keys it shows: "⌘⇧K", "⌘Z ×3".
    ///
    /// Every cue is on the lane, including the ones the picture leaves out — a hidden
    /// one, or Return on its own while the style says not to show those. Faded and marked,
    /// so a chip that draws nothing says why rather than vanishing from the one place it
    /// can be selected and switched back on.
    private var keyRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.keyCues,
                          tint: Self.keysTint,
                          title: "Shortcut",
                          symbol: "",
                          height: Self.regionHeight,
                          selection: Selection.keyCue) { cue in
            HStack(spacing: 5) {
                if !model.timeline.isShown(cue) {
                    Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold))
                }
                Text(cue.isEmpty ? "Empty shortcut" : cue.title)
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(cue.isEmpty ? 0.6 : 1)
            }
            .opacity(model.timeline.isShown(cue) ? 1 : 0.45)
        }
    }

    /// Stretches where the camera sits somewhere other than its bubble, each labelled with
    /// the layout it shows.
    ///
    /// Faded while the camera is switched off for the whole video: the stretches keep their
    /// places, and a faded chip says why the picture is not doing what it says.
    private var cameraRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.cameraLayouts,
                          tint: Self.cameraTint,
                          title: "Camera",
                          symbol: "",
                          height: Self.regionHeight,
                          selection: Selection.cameraLayout) { region in
            HStack(spacing: 5) {
                Image(systemName: region.layout.symbol).font(.system(size: 9, weight: .semibold))
                Text(region.layout.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .opacity(model.timeline.webcam.isEnabled ? 1 : 0.45)
        }
    }

    /// The captions, each one a line you can move, trim and select.
    ///
    /// The words themselves are the label. A lane of chips that all say "Caption" tells
    /// you only that there are captions; the reason to look at this lane is to find the
    /// line that is early, and that means reading them.
    private var captionRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.captions,
                          tint: .indigo,
                          title: "Caption",
                          symbol: "",
                          height: Self.regionHeight,
                          selection: Selection.caption,
                          fitsWords: true) { cue in
            Text(cue.text.isEmpty ? "Empty caption" : cue.text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(cue.text.isEmpty ? 0.6 : 1)
        }
    }

    /// Music and voiceover: sound that is free to sit where it likes, so it gets the
    /// ordinary region lane with its dragging and resizing.
    private var addedSoundRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.audio,
                          tint: .green,
                          title: "Sound",
                          symbol: "music.note",
                          height: Self.regionHeight,
                          selection: Selection.audio,
                          waveform: { region in
                              model.regionWaveforms.peaks(forPath: region.path)
                                  .map { ($0, [TimelineWaveform.Span(region)]) }
                          },
                          fades: { $0.heardFades }) { region in
            Text((region.path as NSString).lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private var zoomRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.zooms,
                          tint: TimelinePalette.zoom,
                          title: "Zoom",
                          symbol: "plus.magnifyingglass",
                          height: Self.regionHeight,
                          selection: Selection.zoom,
                          // The scale on its own, for a chip too short for its glyphs: on a
                          // fitted take most auto-zooms are, and the scale is the part worth
                          // reading off them.
                          compact: { zoom in
                              AnyView(Text(Self.scale(zoom))
                                  .opacity(zoom.isEnabled ? 1 : 0.45))
                          }) { zoom in
            HStack(spacing: 6) {
                // Which zooms are off, at a glance down the lane. A switched-off zoom keeps
                // its place and its framing, so without a mark on it the lane shows a zoom
                // where the picture does not move and there is nothing to explain why.
                if !zoom.isEnabled {
                    Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold))
                }
                Text(Self.scale(zoom))
                // What asked for this zoom. A suggestion somebody can see the reason for is
                // one they adjust; one that appeared from nowhere is one they delete. The
                // glyph rather than the word, because the word is on the tooltip and the
                // chip is often forty points wide.
                if let source = zoom.source, source != .manual {
                    Image(systemName: Self.symbol(for: source))
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.8)
                        .accessibilityLabel("Suggested by \(source.title.lowercased())")
                }
                // A padlock rather than a different tint: the chip already carries selection
                // in its tint, and a lock is the reason a drag is about to appear to fail —
                // which is exactly the moment somebody looks at the chip to find out why.
                if zoom.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                }
                // The glyph without the word. "Auto" beside a pointer said the same thing
                // twice and was the part that ran under the chip's trailing edge on a short
                // zoom — and a label cut off mid-word is worse than no label. The sentence
                // is on the chip's tooltip, where there is room for it.
                if zoom.followsCursor {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.85)
                        .accessibilityLabel("Follows the pointer")
                }
            }
            // Faded, not hidden: it is still a thing on the timeline you can select, move
            // and switch back on.
            .opacity(zoom.isEnabled ? 1 : 0.45)
        }
    }

    /// A zoom's scale as its chip prints it: "1.8×", "2×".
    private static func scale(_ zoom: ZoomRegion) -> String {
        "\(zoom.scale.formatted(.number.precision(.fractionLength(0...1))))×"
    }

    /// What asked for a zoom, as one glyph.
    private static func symbol(for source: ZoomRegion.Source) -> String {
        switch source {
        case .manual: "hand.point.up.left"
        case .click: "cursorarrow.click"
        case .typing: "keyboard"
        case .field: "character.cursor.ibeam"
        case .window: "macwindow"
        case .application: "square.on.square"
        }
    }

    /// Stretches where the pointer does something other than what the Pointer panel says:
    /// hidden, calmed, held still.
    ///
    /// Directly under the zoom lane, because the two are read together — the pointer is
    /// what a following zoom is aimed at, and "hidden here" is usually an answer to what a
    /// zoom is showing.
    private var cursorRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.cursorRegions,
                          tint: TimelinePalette.pointer,
                          title: "Pointer",
                          symbol: "cursorarrow.slash",
                          height: Self.regionHeight,
                          selection: Selection.cursorRegion) { region in
            Text(region.title)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private var blurRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.blurs,
                          tint: .teal,
                          title: "Mask",
                          symbol: "drop.halffull",
                          height: Self.regionHeight,
                          selection: Selection.blur,
                          stacks: true) { blur in
            // The kind, by name: a chip that said "Blur" over a spotlight would be lying.
            Text(blur.title)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private var annotationRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.annotations,
                          tint: .pink,
                          title: "Note",
                          // Each chip draws its own kind's glyph instead.
                          symbol: "",
                          height: Self.regionHeight,
                          selection: Selection.annotation,
                          stacks: true,
                          menu: { item in AnyView(AnnotationMenu(model: model, item: item)) }) { item in
            HStack(spacing: 5) {
                // What kind it is, as a glyph of its own: the lane's "Aa" says only that
                // this row is annotations, and three chips that all read "Aa" say nothing.
                Image(systemName: Self.symbol(for: item.kind))
                    .font(.system(size: 9, weight: .semibold))
                Text(Self.label(for: item.kind))
                    .font(.system(size: 11, weight: .semibold))
                if item.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                }
                if item.isHidden {
                    Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold))
                }
            }
            // Faded, not removed, like a switched-off zoom: still on the lane to select,
            // move and show again.
            .opacity(item.isHidden ? 0.45 : 1)
        }
    }

    private static func symbol(for kind: AnnotationItem.Kind) -> String {
        switch kind {
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .image: "photo"
        case .ellipse, .loop, .line, .highlight, .step, .callout: kind.name.symbol
        }
    }

    private static func label(for kind: AnnotationItem.Kind) -> String {
        switch kind {
        case .text(let text): text.isEmpty ? "Text" : text
        case .arrow: "Arrow"
        case .rectangle: "Box"
        case .image: "Image"
        case .ellipse, .loop, .line, .highlight, .step, .callout: kind.label
        }
    }

    // MARK: - Chrome

    /// Past the end of the edit, a shade lighter, so where it stops is plain at any zoom.
    private var beyondEnd: some View {
        GeometryReader { proxy in
            let x = max(0, viewport.x(for: model.duration))
            StudioTheme.Surface.beyondEnd
                .frame(width: max(0, proxy.size.width - x + Self.sideInset))
                .offset(x: x)
        }
        .allowsHitTesting(false)
    }

    private var playhead: some View {
        let x = viewport.x(for: model.playhead)
        return ZStack(alignment: .top) {
            // A column of nothing either side of the line, so the playhead can be taken
            // hold of anywhere down the timeline. A 1.5-point line is not a target; this is.
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    guard !model.isGesturing else { return }
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(scrubbing)

            Rectangle()
                .fill(StudioTheme.Surface.playhead)
                .frame(width: 1.5)
                .allowsHitTesting(false)

            // The time it is at, on a pill at the top in the ruler: the playhead says
            // where it is without a trip to the transport bar.
            Text(Self.playheadLabel(model.playhead.seconds))
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(minWidth: 34, minHeight: 20)
                .background(StudioTheme.Surface.playhead, in: Capsule())
                .padding(.top, 5)
                .allowsHitTesting(false)
        }
        // The width is stated rather than left to whichever child happens to be widest,
        // and everything in the stack centres in it — so the offset below places the *line*
        // at the playhead's time.
        .frame(width: Self.playheadGrab)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(x: x - Self.playheadGrab / 2)
        .opacity(x >= -4 ? 1 : 0)
    }

    /// "1.6", "12.4", "1:02.5": seconds to a tenth, minutes once there are some.
    static func playheadLabel(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        let minutes = tenths / 600
        let rest = Double(tenths % 600) / 10
        let text = rest.formatted(.number.precision(.fractionLength(1)))
        guard minutes > 0 else { return text }
        return "\(minutes):" + (rest < 10 ? "0" : "") + text
    }

    /// Dragging the head itself. Same gesture as the ruler's, in the same space, so
    /// grabbing the line and scrubbing the ruler cannot behave differently.
    private var scrubbing: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                model.beginScrub()
                model.scrub(to: viewport.time(at: value.location.x))
            }
            .onEnded { _ in model.endScrub() }
    }

    private var events: some View {
        TimelineEventCatcher(
            scroll: { points in
                viewport.scroll(by: points, duration: model.duration)
            },
            magnify: { factor, x in
                viewport.setPointsPerSecond(viewport.pointsPerSecond * factor,
                                            anchoring: viewport.time(at: x),
                                            duration: model.duration)
            }
        )
        .allowsHitTesting(false)
    }
}
