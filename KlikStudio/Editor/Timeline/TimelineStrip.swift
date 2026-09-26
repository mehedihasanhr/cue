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
    private static let regionHeight: CGFloat = 28
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 10
    /// Wide enough for "System Audio" and for a microphone's own name at a glance, and no
    /// wider: every point here is a point of edit that is not on screen.
    private static let gutterWidth: CGFloat = 148

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
            }
        }

        var height: CGFloat {
            switch self {
            case .clips: clipHeight
            case .recordedSound, .source: soundHeight
            case .zooms, .pointer, .addedSound, .blurs, .annotations: regionHeight
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
            case .blurs: "Blur"
            case .annotations: "Notes"
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
            }
        }

        /// The same colour the row's own contents are drawn in, so the heading reads as
        /// belonging to what is beside it rather than as a list of its own.
        func tint(in timeline: Timeline) -> Color {
            switch self {
            case .clips: .orange
            case .recordedSound: .green
            case .source(let id): timeline.soundTrack(id)?.source == .systemAudio ? .blue : .green
            case .zooms: .purple
            case .pointer: .orange
            case .addedSound: .green
            case .blurs: .teal
            case .annotations: .pink
            }
        }
    }

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
        if !timeline.audio.isEmpty { lanes.append(.addedSound) }
        if !timeline.blurs.isEmpty { lanes.append(.blurs) }
        if !timeline.annotations.isEmpty { lanes.append(.annotations) }
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
        .padding(.leading, 10)
        .padding(.trailing, 8)
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
                .font(.system(size: 11))
                .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(lane.tint(in: timeline)))
                .frame(width: 14)
            Text(lane.title(in: timeline))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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
                          }) { region in
            Text((region.path as NSString).lastPathComponent)
                .font(.system(size: 10, weight: .semibold))
        }
    }

    private var zoomRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.zooms,
                          tint: .purple,
                          title: "Zoom",
                          symbol: "plus.magnifyingglass",
                          height: Self.regionHeight,
                          selection: Selection.zoom) { zoom in
            HStack(spacing: 6) {
                Text("\(zoom.scale, format: .number.precision(.fractionLength(0...1)))×")
                // A padlock rather than a different tint: the chip already carries selection
                // in its tint, and a lock is the reason a drag is about to appear to fail —
                // which is exactly the moment somebody looks at the chip to find out why.
                if zoom.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                }
                if zoom.followsCursor {
                    Label("Auto", systemImage: "cursorarrow")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.85)
                }
            }
            .font(.system(size: 10, weight: .semibold))
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
                .font(.system(size: 10, weight: .semibold))
        }
    }

    private var blurRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.blurs,
                          tint: .teal,
                          title: "Blur",
                          symbol: "drop.halffull",
                          height: Self.regionHeight,
                          selection: Selection.blur) { blur in
            Text(blur.style == .pixelate ? "Pixelate" : "Blur")
                .font(.system(size: 10, weight: .semibold))
        }
    }

    private var annotationRow: some View {
        TimelineRegionRow(model: model,
                          regions: model.timeline.annotations,
                          tint: .pink,
                          title: "Note",
                          symbol: "textformat",
                          height: Self.regionHeight,
                          selection: Selection.annotation) { item in
            Text(Self.label(for: item.kind))
                .font(.system(size: 10, weight: .semibold))
        }
    }

    private static func label(for kind: AnnotationItem.Kind) -> String {
        switch kind {
        case .text(let text): text.isEmpty ? "Text" : text
        case .arrow: "Arrow"
        case .rectangle: "Box"
        case .image: "Image"
        }
    }

    // MARK: - Chrome

    private var playhead: some View {
        let x = viewport.x(for: model.playhead)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5)
            // A grab handle at the top, inside the ruler, so the line itself can stay
            // out of the way of everything under it.
            // Drawn in the frame's own coordinates — 0…10 across, not -5…5. Measured
            // from the middle, the whole handle sat five points to the left of the line
            // it is supposed to be the top of.
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 10, y: 0))
                path.addLine(to: CGPoint(x: 5, y: 8))
                path.closeSubpath()
            }
            .fill(Color.red)
            .frame(width: 10, height: 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(x: x - 0.75)
        .allowsHitTesting(false)
        .opacity(x >= -4 ? 1 : 0)
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
