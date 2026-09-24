import AppKit
import CoreMedia
import SwiftUI
import TimelineKit

/// The recording's own sound, on a lane of its own.
///
/// It used to be drawn inside the clips, which said something untrue: that the sound is a
/// property of the picture and goes wherever the picture goes. It *is* cut with the
/// picture — it is the same take — but it is a thing you work on, with its own level, its
/// own mute and its own place to click. Sharing a row with the video left nowhere to put
/// any of that.
///
/// The lane has two states, and which one it is in is the user's explicit choice.
///
/// **Attached**, the default, is what it always was: the runs follow `timeline.clips`
/// exactly, because this is one recording and a sound that could drift out from under its
/// own footage by accident is a bug. Nothing about this state has changed — a project made
/// before detaching existed opens here and sounds identical.
///
/// **Detached** is what the ordinary edits need. Letting someone finish a sentence over a
/// cut, lifting a cough out without losing the frame, sliding narration a few frames onto
/// an action: none of them can be said about a clip, because a clip has no timeline
/// position of its own. So detaching replaces "follow the clips" with a row of `SoundRun`s
/// that carry their own positions and are dragged, trimmed and snapped like every other
/// lane's contents.
///
/// Sound that was never part of the take — music, an imported voiceover — is an
/// `AudioRegion` and has always had the ordinary region lane below.
struct TimelineSoundRow: View {
    let model: EditorModel
    let height: CGFloat

    /// Where a run was when the current drag began, so every frame of the gesture is
    /// measured from one fixed origin rather than from the value the last frame wrote.
    @State private var dragOrigin: (start: CMTime, duration: CMTime)?

    private var viewport: TimelineViewport { model.viewport }
    private var isMuted: Bool { !model.timeline.sound.isAudible }
    private var runs: [SoundRun]? { model.timeline.detachedSound }
    private let edgeWidth: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: height)

            if let runs {
                ForEach(runs) { run in
                    body(for: run)
                }
            } else {
                ForEach(Array(model.timeline.clips.enumerated()), id: \.element.id) { index, clip in
                    slice(clip, at: index)
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        // Only meaningful on the attached lane, where the whole row is one thing. Detached,
        // each run is its own target and this would fight them for the click.
        .onTapGesture { if runs == nil { model.select(.sound) } }
        .contextMenu { laneMenu }
        .help(help)
    }

    private var help: String {
        if isMuted { return "The recording's sound is muted" }
        return runs == nil
            ? "The recording's sound, cut where the picture is cut"
            : "The recording's sound, detached — drag and trim it on its own"
    }

    // MARK: - Menus

    /// What the lane offers wherever you right-click it. The run menu below adds to this
    /// rather than replacing it, because "mute the recording" is a fair thing to want with
    /// the pointer over a run.
    @ViewBuilder
    private var laneMenu: some View {
        if model.isSoundDetached {
            Button("Re-attach Audio") { model.requestSoundReattach() }
        } else {
            Button("Detach Audio") { model.detachSound() }
        }
        Divider()
        Button(isMuted ? "Unmute Recording" : "Mute Recording") { toggleMute() }
        Button("Reset Level") { setGain(1) }
            .disabled(model.timeline.sound.gain == 1)
    }

    // MARK: - Attached: the sound the picture cuts

    /// One clip's worth of sound. Drawn per clip rather than as one strip so a cut is as
    /// visible here as it is on the row above.
    private func slice(_ clip: Clip, at index: Int) -> some View {
        let left = viewport.x(for: model.timeline.start(ofClipAt: index))
        let width = max(4, clip.duration.seconds * viewport.pointsPerSecond)
        let selected = model.selection == .sound

        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.green.opacity(selected ? 0.4 : 0.26))
            .overlay { waveform(clippedTo: width, offsetBy: left,
                                spans: TimelineWaveform.Span.followingClips(of: model.timeline)) }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
            }
            // Only on the first slice, so a cut-up recording gets one label rather than
            // one per piece.
            .overlay(alignment: .leading) {
                if index == 0 { label.padding(.leading, 6) }
            }
            .opacity(isMuted ? 0.45 : 1)
            .frame(width: width, height: height)
            .offset(x: left)
    }

    // MARK: - Detached: the sound with a life of its own

    private func body(for run: SoundRun) -> some View {
        let left = viewport.x(for: run.start)
        let width = max(6, run.duration.seconds * viewport.pointsPerSecond)
        let selected = model.selection == .soundRun(run.id)

        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.green.opacity(selected ? 0.46 : 0.3))
            .overlay { waveform(clippedTo: width, offsetBy: left, spans: [.init(run)]) }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
            }
            .overlay(alignment: .leading) {
                // Only where there is room: a run trimmed to half a second is narrower
                // than its own badge, and a badge overhanging its run points at the
                // wrong one.
                if width > 34 { label.padding(.leading, 6) }
            }
            .opacity(isMuted ? 0.45 : 1)
            .frame(width: width, height: height)
            .offset(x: left)
            .contentShape(Rectangle())
            .onTapGesture { model.select(.soundRun(run.id)) }
            .gesture(move(run))
            .overlay {
                edge(run, leading: true).offset(x: left)
                edge(run, leading: false).offset(x: left + width - edgeWidth)
            }
            .contextMenu {
                Button("Delete", role: .destructive) { model.deleteSelection(run.id) }
                Divider()
                laneMenu
            }
            .help("Sound · \(Timecode.length(run.duration))")
    }

    // MARK: - Gestures

    /// Dragging the body slides the run in time and keeps playing the same words, which is
    /// what "line the narration up with the click" means.
    private func move(_ run: SoundRun) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = begin(run, name: "Move Sound")
                let proposed = origin.start + CMTime(seconds: value.translation.width / viewport.pointsPerSecond,
                                                     preferredTimescale: 600)
                let start = snapping().snapRegion(start: max(.zero, proposed),
                                                  duration: origin.duration,
                                                  to: others(of: run))
                model.apply(Commands.MoveSoundRun(id: run.id, start: max(.zero, start)))
            }
            .onEnded { _ in end() }
    }

    private func edge(_ run: SoundRun, leading: Bool) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: edgeWidth, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(trim(run, leading: leading))
    }

    /// Dragging an edge trims: the sound that survives stays exactly where it was, and the
    /// run simply covers less of the timeline. `MoveSoundRun.trimsHead` is what keeps the
    /// leading edge from re-cutting the take — see its note.
    private func trim(_ run: SoundRun, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = begin(run, name: "Trim Sound")
                let delta = CMTime(seconds: value.translation.width / viewport.pointsPerSecond,
                                   preferredTimescale: 600)
                let edges = others(of: run)
                if leading {
                    let proposed = snapping().snap(max(.zero, origin.start + delta), to: edges)
                    let limit = origin.start + origin.duration - Clip.minimumDuration
                    let start = min(proposed, limit)
                    model.apply(Commands.MoveSoundRun(id: run.id,
                                                      start: start,
                                                      duration: origin.start + origin.duration - start,
                                                      trimsHead: true))
                } else {
                    let proposed = snapping().snap(origin.start + origin.duration + delta, to: edges)
                    model.apply(Commands.MoveSoundRun(id: run.id,
                                                      start: origin.start,
                                                      duration: max(Clip.minimumDuration, proposed - origin.start)))
                }
            }
            .onEnded { _ in end() }
    }

    private func begin(_ run: SoundRun, name: String) -> (start: CMTime, duration: CMTime) {
        if let dragOrigin { return dragOrigin }
        let origin = (run.start, run.duration)
        dragOrigin = origin
        model.select(.soundRun(run.id))
        model.document.beginInteraction(name)
        return origin
    }

    private func end() {
        dragOrigin = nil
        model.document.endInteraction()
    }

    /// Hold ⌘ to place something exactly where you put it.
    private func snapping() -> Snapping {
        NSEvent.modifierFlags.contains(.command)
            ? .disabled
            : Snapping(pointsPerSecond: viewport.pointsPerSecond)
    }

    /// Everything worth snapping to except this run's own edges, which would only make it
    /// stick to where it already is. The clip cuts are in there, which is what makes
    /// "back in line with the picture" a thing a drag can find again.
    private func others(of run: SoundRun) -> [CMTime] {
        model.timeline.boundaries.filter { $0 != run.start && $0 != run.end }
    }

    // MARK: - Chrome

    /// The waveform, masked to one piece of the lane.
    ///
    /// Drawn across the whole row and then cut down rather than drawn per piece, because
    /// the peaks are indexed by *source* time: the view needs the spans that say which
    /// second of the recording each point stands for, and those are the lane's, not this
    /// rectangle's.
    @ViewBuilder
    private func waveform(clippedTo width: CGFloat,
                          offsetBy left: CGFloat,
                          spans: [TimelineWaveform.Span]) -> some View {
        if let peaks = model.waveform.peaks {
            TimelineWaveform(viewport: viewport, spans: spans, peaks: peaks, height: height)
                .mask {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .frame(width: width)
                        .offset(x: left)
                }
                .offset(x: -left)
                .frame(width: width, alignment: .leading)
                .clipped()
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: isMuted ? "speaker.slash.fill"
                  : (model.isSoundDetached ? "waveform.badge.minus" : "waveform"))
                .font(.system(size: 9, weight: .semibold))
            if model.timeline.sound.gain != 1, !isMuted {
                Text("\(Int((model.timeline.sound.gain * 100).rounded()))%")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.28), in: Capsule())
        .allowsHitTesting(false)
    }

    // MARK: - Edits

    private func toggleMute() {
        let muted = model.timeline.sound.isMuted
        model.apply(Commands.Restyle(muted ? "Unmute" : "Mute") { $0.sound.isMuted = !muted })
    }

    private func setGain(_ gain: Double) {
        model.apply(Commands.Restyle("Level") { $0.sound.gain = gain })
    }
}
