import CoreMedia
import SwiftUI
import TimelineKit

/// The edit, seen sideways: clips on one row, the things laid over them on the next, the
/// playhead across both.
///
/// Scrub in the ruler or on empty background; click a row to select, drag it to move.
/// Everything that moves snaps to the cuts and to the other regions, in points rather
/// than seconds, so it feels the same however far the timeline is zoomed — up to the
/// point where the whole recording is on screen, where the tolerance is capped in time
/// so free positioning is still possible.
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

    /// Tall enough for the rows this edit actually has.
    static func height(for timeline: Timeline, hasSound: Bool = true) -> CGFloat {
        var rows = 1.0                                   // zooms, always shown
        if !timeline.blurs.isEmpty { rows += 1 }
        if !timeline.annotations.isEmpty { rows += 1 }
        if !timeline.audio.isEmpty { rows += 1 }
        if !timeline.cursorRegions.isEmpty { rows += 1 }
        return padding * 2 + rulerHeight + clipHeight
            + (hasSound ? soundHeight + spacing : 0)
            + (regionHeight + spacing) * rows + spacing
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: Self.spacing) {
                TimelineRuler(model: model, height: Self.rulerHeight)
                TimelineClipRow(model: model, height: Self.clipHeight)
                soundRow
                zoomRow
                cursorRow
                addedSoundRow
                blurRow
                annotationRow
            }
            .padding(.horizontal, 0)
            .padding(.vertical, Self.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                // Clicking past the end of everything clears the selection, which is the
                // only way out of one that does not involve the Escape key.
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clearSelection() }
            }
            .overlay(alignment: .topLeading) { playhead(height: proxy.size.height) }
            .overlay { events }
            .clipped()
            .onAppear { prepare(width: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in
                viewport.setWidth(width, duration: model.duration)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func prepare(width: Double) {
        viewport.setWidth(width, duration: model.duration)
        if viewport.pointsPerSecond == 40 { viewport.fit(model.duration) }
    }

    // MARK: - Rows

    /// The recording's own sound. Hidden for a take that has none, like the other lanes
    /// that only appear when there is something in them.
    @ViewBuilder
    private var soundRow: some View {
        if model.waveform.state != .unavailable {
            TimelineSoundRow(model: model, height: Self.soundHeight)
        }
    }

    /// Music and voiceover: sound that is free to sit where it likes, so it gets the
    /// ordinary region lane with its dragging and resizing.
    @ViewBuilder
    private var addedSoundRow: some View {
        if !model.timeline.audio.isEmpty {
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
    /// zoom is showing. Shown only when there is something in it, like the lanes below.
    @ViewBuilder
    private var cursorRow: some View {
        if !model.timeline.cursorRegions.isEmpty {
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
    }

    /// Shown only when there is something in it: four permanently empty lanes would be
    /// most of the strip's height spent on features nothing can add to yet.
    @ViewBuilder
    private var blurRow: some View {
        if !model.timeline.blurs.isEmpty {
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
    }

    @ViewBuilder
    private var annotationRow: some View {
        if !model.timeline.annotations.isEmpty {
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

    private func playhead(height: Double) -> some View {
        let x = viewport.x(for: model.playhead)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5, height: height)
            // A grab handle at the top, inside the ruler, so the line itself can stay
            // out of the way of everything under it.
            Path { path in
                path.move(to: CGPoint(x: -5, y: 0))
                path.addLine(to: CGPoint(x: 5, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 8))
                path.closeSubpath()
            }
            .fill(Color.red)
            .frame(width: 10, height: 8)
        }
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
