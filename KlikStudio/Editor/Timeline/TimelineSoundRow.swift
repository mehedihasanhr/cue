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
///
/// One of these per *source* once a recording has them — the screen on one lane, each
/// microphone on its own. `track` is which; `nil` is a recording made before the sources
/// were captured separately, whose sound is one undifferentiated thing inside the video
/// file, and that lane is drawn exactly as it always was.
///
/// What the lanes share is *time*: the runs below belong to the take, not to a source, so
/// trimming one trims all of them. That is the honest model — every source of one take was
/// captured on one clock at one moment, and a lane that could be slid on its own would be
/// a lane that could be slid out of sync with the face that is speaking. What the lanes do
/// not share is level: each has its own, which is the whole reason they are separate.
struct TimelineSoundRow: View {
    let model: EditorModel
    let height: CGFloat
    /// The source this lane is showing, or `nil` for a recording whose sound is one thing.
    var track: SoundTrack? = nil

    /// Where a run was when the current drag began, so every frame of the gesture is
    /// measured from one fixed origin rather than from the value the last frame wrote.
    @State private var dragOrigin: (start: CMTime, duration: CMTime)?

    private var viewport: TimelineViewport { model.viewport }
    private var isMuted: Bool {
        if let track { return !model.timeline.isAudible(track) }
        return !model.timeline.sound.isAudible
    }
    private var runs: [SoundRun]? { model.timeline.detachedSound }
    private let edgeWidth: CGFloat = 8
    /// Below this the two grips would touch, so the piece is left plain.
    private let minimumGripWidth: CGFloat = 26
    @State private var hoveredGrip: String?

    /// What this lane selects when it is clicked as a whole: this source, or — with no
    /// sources to tell apart — the recording's sound.
    private var laneSelection: Selection {
        track.map { Selection.soundTrack($0.id) } ?? .sound
    }

    /// Green for a voice, blue for the screen's own sound. A colour rather than only an
    /// icon because the lanes are read at a glance while scrubbing, and at that speed the
    /// thing that says "this is the one with me talking on it" is the colour.
    private var tint: Color {
        switch track?.source {
        case .systemAudio: .blue
        case .microphone, .none: .green
        }
    }

    /// This source's own gain, under the master.
    private var gain: Double {
        track.map { model.timeline.sound.gain * $0.style.gain } ?? model.timeline.sound.gain
    }

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
        .onTapGesture { if runs == nil { model.select(laneSelection) } }
        .contextMenu { laneMenu }
        .help(help)
    }

    private var help: String {
        if let track {
            if isMuted { return "\(track.name) — muted" }
            return runs == nil
                ? "\(track.name), cut where the picture is cut"
                : "\(track.name), detached — drag and trim it on its own"
        }
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
        if let track {
            Button(track.style.isMuted ? "Unmute \(track.name)" : "Mute \(track.name)") { toggleMute() }
            // Solo is spelled as "mute the others" so it is one undoable edit rather than a
            // piece of editor state the exporter would have to be told about separately.
            // See `Commands.SoloSoundTrack`.
            Button("Solo") { model.soloSound(track.id) }
                .disabled(model.timeline.soundTracks.count < 2)
            Button("Unmute All Sources") { model.unmuteAllSound() }
                .disabled(model.timeline.soundTracks.allSatisfy { !$0.style.isMuted })
            Button("Reset Level") { setGain(1) }
                .disabled(track.style.gain == 1)
            Divider()
            Button(model.timeline.sound.isMuted ? "Unmute Recording" : "Mute Recording") {
                let muted = model.timeline.sound.isMuted
                model.apply(Commands.Restyle(muted ? "Unmute" : "Mute") { $0.sound.isMuted = !muted })
            }
        } else {
            Button(isMuted ? "Unmute Recording" : "Mute Recording") { toggleMute() }
            Button("Reset Level") { setGain(1) }
                .disabled(model.timeline.sound.gain == 1)
        }
    }

    // MARK: - Attached: the sound the picture cuts

    /// One clip's worth of sound. Drawn per clip rather than as one strip so a cut is as
    /// visible here as it is on the row above.
    private func slice(_ clip: Clip, at index: Int) -> some View {
        let left = viewport.x(for: model.timeline.start(ofClipAt: index))
        let width = max(4, clip.duration.seconds * viewport.pointsPerSecond)
        let selected = model.selection == laneSelection

        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.opacity(selected ? 0.4 : 0.26))
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
            .fill(tint.opacity(selected ? 0.46 : 0.3))
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
                edge(run, leading: true, width: width).offset(x: left)
                edge(run, leading: false, width: width).offset(x: left + width - edgeWidth)
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

    /// A grabbable end of a run, and the line that says it is there.
    ///
    /// Drawn rather than left invisible, for the reason `TimelineRegionRow` gives: a handle
    /// you have to find by sweeping the pointer along the piece is barely a handle.
    private func edge(_ run: SoundRun, leading: Bool, width: CGFloat) -> some View {
        let key = "\(run.id)-\(leading)"
        let isHovered = hoveredGrip == key
        return Rectangle()
            .fill(.clear)
            .frame(width: edgeWidth, height: height)
            .overlay {
                if width >= minimumGripWidth {
                    Capsule()
                        .fill(.white.opacity(isHovered ? 1 : 0.6))
                        .frame(width: isHovered ? 3 : 2, height: max(8, height - 12))
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .animation(StudioMotion.state, value: isHovered)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hoveredGrip = inside ? key : (hoveredGrip == key ? nil : hoveredGrip)
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
        // A lane draws its *own* source's peaks. Drawing the recording's mixed waveform on
        // the microphone lane would be a picture of the wrong sound, and the whole reason
        // to look at a waveform is to find the moment somebody spoke.
        if let peaks = track.map({ model.regionWaveforms.peaks(forPath: $0.path) }) ?? model.waveform.peaks {
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
                  : (track?.symbol ?? (model.isSoundDetached ? "waveform.badge.minus" : "waveform")))
                .font(.system(size: 9, weight: .semibold))
            // The source's name, on the lane, because two green lanes with waveforms on
            // them are otherwise told apart only by remembering which is which.
            if let track {
                Text(track.name)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            if gain != 1, !isMuted {
                Text("\(Int((gain * 100).rounded()))%")
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
        guard let track else {
            let muted = model.timeline.sound.isMuted
            model.apply(Commands.Restyle(muted ? "Unmute" : "Mute") { $0.sound.isMuted = !muted })
            return
        }
        model.toggleSoundMute(track.id)
    }

    private func setGain(_ gain: Double) {
        guard let track else {
            model.apply(Commands.Restyle("Level") { $0.sound.gain = gain })
            return
        }
        model.setSoundGain(track.id, to: gain)
    }
}
