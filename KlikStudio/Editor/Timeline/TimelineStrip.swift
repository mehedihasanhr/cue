import CoreMedia
import SwiftUI
import TimelineKit

/// The edit, seen sideways: a column of lane headings, and beside it the lanes themselves
/// with the playhead across all of them.
///
/// Scrub in the ruler or on empty background; click a row to select, drag it to move.
/// Everything that moves snaps to the cuts and to the other regions, in points rather
/// than seconds, so it feels the same however far the timeline is zoomed — up to the
/// point where the whole recording is on screen, where the tolerance is capped in time
/// so free positioning is still possible.
///
/// The lanes are described once, by `Lane`, and drawn twice — once as headings in the
/// gutter, once as contents beside it. That is not an abstraction for its own sake: two
/// stacks of rows built from two lists is a layout that lines up until somebody adds a
/// lane to one of them, and a heading a row out of step with the thing it names is worse
/// than no heading at all.
struct TimelineStrip: View {
    let model: EditorModel

    private var viewport: TimelineViewport { model.viewport }

    private static let rulerHeight: CGFloat = 20
    private static let clipHeight: CGFloat = 54
    /// Shorter than the clips and taller than a region lane: the sound is a thing you
    /// read rather than a chip you read the label off, and a waveform squeezed into 28
    /// points is a smear.
    private static let soundHeight: CGFloat = 38
    /// Tall enough for a chip's two lines — what it is, and what it says.
    private static let regionHeight: CGFloat = 36
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 10
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

    /// A stripe and a glyph, and nothing else.
    ///
    /// The headings carried their names at first, which cost 148 points of every screen —
    /// and the names were the part you stop reading: after the first look you know the blue
    /// row is the screen and the green one is you. The name is still there on hover, for
    /// the take with two microphones on it where the glyphs are the same.
    private static let gutterWidth: CGFloat = 46

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

        var height: CGFloat {
            switch self {
            case .clips: clipHeight
            case .recordedSound, .source: soundHeight
            case .zooms, .pointer, .addedSound, .blurs, .annotations, .captions, .keys, .camera: regionHeight
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
            case .pointer: .orange
            case .addedSound: .green
            case .blurs: .teal
            case .annotations: .pink
            case .captions: .indigo
            case .keys: TimelineStrip.keysTint
            case .camera: TimelineStrip.cameraTint
            }
        }
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
                .reduce(0) { $0 + $1.height + spacing }
            - spacing
    }

    private var lanes: [Lane] {
        Self.lanes(for: model.timeline, hasSound: model.waveform.state != .unavailable)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let laneWidth = max(0, proxy.size.width - Self.gutterWidth - 1)
            HStack(spacing: 0) {
                gutter
                    .frame(width: Self.gutterWidth)
                StudioDivider(axis: .vertical)
                lanesColumn
                    .frame(width: laneWidth, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { Color.clear.studioSurface() }
            .onAppear { viewport.setWidth(laneWidth, duration: model.duration) }
            // The viewport measures the lanes, not the window: it maps seconds to points
            // inside the part of the strip that shows the edit, and handing it the whole
            // width would put every cut a gutter's worth to the right of where it is drawn.
            .onChange(of: laneWidth) { _, width in
                viewport.setWidth(width, duration: model.duration)
            }
        }
        .background { Color.clear.studioSurface() }
    }

    // MARK: - The gutter

    private var gutter: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            // Nothing beside the ruler. A heading for a row of numbers would be a word
            // explaining a clock.
            Color.clear.frame(height: Self.rulerHeight)
            ForEach(lanes) { lane in
                heading(lane)
            }
        }
        .padding(.vertical, Self.padding)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private func heading(_ lane: Lane) -> some View {
        let timeline = model.timeline
        let muted = isMuted(lane)
        return HStack(spacing: 7) {
            // A stripe in the lane's own colour, full height: at a glance down the gutter
            // this is what says which rows are sound and which are the picture, before any
            // of the words are read.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(lane.tint(in: timeline).opacity(muted ? 0.3 : 0.9))
                .frame(width: 3)
            Image(systemName: muted ? "speaker.slash.fill" : lane.symbol(in: timeline))
                .font(.system(size: 12))
                .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(lane.tint(in: timeline)))
                .frame(width: 18)
            Spacer(minLength: 0)
        }
        .frame(height: lane.height)
        .contentShape(Rectangle())
        .onTapGesture { if let selection = selection(of: lane) { model.select(selection) } }
        .help(lane.title(in: timeline))
    }

    /// Whether this row's sound is off, which is the one piece of state a heading shows.
    /// Every other lane answers `false` — a blur cannot be muted.
    private func isMuted(_ lane: Lane) -> Bool {
        switch lane {
        case .recordedSound: !model.timeline.sound.isAudible
        case .source(let id): model.timeline.soundTrack(id).map { !model.timeline.isAudible($0) } ?? false
        default: false
        }
    }

    /// What clicking a heading selects, for the rows that are one thing. The lanes that
    /// hold many regions select nothing: there is no single zoom a heading could mean.
    private func selection(of lane: Lane) -> Selection? {
        switch lane {
        case .recordedSound: .sound
        case .source(let id): .soundTrack(id)
        default: nil
        }
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
                          selection: Selection.zoom) { zoom in
            HStack(spacing: 6) {
                // Which zooms are off, at a glance down the lane. A switched-off zoom keeps
                // its place and its framing, so without a mark on it the lane shows a zoom
                // where the picture does not move and there is nothing to explain why.
                if !zoom.isEnabled {
                    Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold))
                }
                Text("\(zoom.scale, format: .number.precision(.fractionLength(0...1)))×")
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
                          tint: .orange,
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
                          selection: Selection.blur) { blur in
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
        case .ellipse, .line, .highlight, .step, .callout: kind.name.symbol
        }
    }

    private static func label(for kind: AnnotationItem.Kind) -> String {
        switch kind {
        case .text(let text): text.isEmpty ? "Text" : text
        case .arrow: "Arrow"
        case .rectangle: "Box"
        case .image: "Image"
        case .ellipse, .line, .highlight, .step, .callout: kind.label
        }
    }

    // MARK: - Chrome

    private var playhead: some View {
        let x = viewport.x(for: model.playhead)
        return ZStack(alignment: .top) {
            // A column of nothing either side of the line, so the playhead can be taken
            // hold of anywhere down the timeline rather than only at the small triangle on
            // top. A 1.5-point line is not a target; this is.
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    guard !model.isGesturing else { return }
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(scrubbing)

            Rectangle()
                .fill(StudioPalette.brand)
                .frame(width: 1.5)
                .allowsHitTesting(false)

            // A round knob at the top, inside the ruler, so the line itself can stay out
            // of the way of everything under it. A ring of the surface colour round it
            // lifts it off the ruler's numbers when it passes over them.
            Circle()
                .fill(StudioPalette.brand)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .padding(.top, 2)
                .allowsHitTesting(false)
        }
        // The width is stated rather than left to whichever child happens to be widest,
        // and everything in the stack centres in it — so the offset below places the *line*
        // at the playhead's time. Left implicit, the stack took the triangle's ten points
        // and the line sat four points to the right of the moment it was marking.
        .frame(width: Self.playheadGrab)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(x: x - Self.playheadGrab / 2)
        .opacity(x >= -4 ? 1 : 0)
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
