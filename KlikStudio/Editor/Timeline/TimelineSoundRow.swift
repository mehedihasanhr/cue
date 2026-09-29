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


    private var viewport: TimelineViewport { model.viewport }
    private var isMuted: Bool {
        if let track { return !model.timeline.isAudible(track) }
        return !model.timeline.sound.isAudible
    }
    private var runs: [SoundRun]? { model.timeline.detachedSound }
    private let radius: CGFloat = 5
    @State private var hoveredGrip: String?
    @Environment(\.colorScheme) private var colorScheme

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
                // Nothing over a freeze frame or a title: they are silent, and the gap in
                // the lane is the silence. Nothing over a movie brought in either: this lane
                // is the recording's sound, and the movie's own plays with its clip.
                ForEach(Array(model.timeline.clips.enumerated()), id: \.element.id) { index, clip in
                    if clip.playsRecording { slice(clip, at: index) }
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

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint.chipFill(selected ? 0.4 : 0.26, in: colorScheme))
            .overlay { waveform(clippedTo: width, offsetBy: left,
                                spans: TimelineWaveform.Span.followingClips(of: model.timeline)) }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
            }
            // Only on the first slice, so a cut-up recording gets one label rather than
            // one per piece.
            .overlay(alignment: .leading) {
                if index == model.timeline.clips.firstIndex(where: \.playsRecording) { label.padding(.leading, 6) }
            }
            .opacity(isMuted ? 0.45 : 1)
            .frame(width: width, height: height)
            .position(x: left + width / 2, y: height / 2)
    }

    // MARK: - Detached: the sound with a life of its own

    private func body(for run: SoundRun) -> some View {
        // The gesture's answer while one is running, the document's otherwise — see
        // `TimelineRegionRow.body(for:)`.
        let live = model.liveRange(of: run.id, start: run.start, duration: run.duration)
        let left = viewport.x(for: live.start)
        let width = max(6, live.duration.seconds * viewport.pointsPerSecond)
        let selected = model.isSelected(.soundRun(run.id))

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint.chipFill(selected ? 0.46 : 0.3, in: colorScheme))
            .overlay { waveform(clippedTo: width, offsetBy: left, spans: [.init(run)]) }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
            }
            .opacity(isMuted ? 0.45 : 1)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                // Against the leading edge and never re-laid-out: a run trimmed narrower
                // than its own badge has the badge cut off by the run rather than shrunk
                // inside it. See `TimelineRegionRow.label(_:width:)`.
                label
                    .fixedSize()
                    .padding(.leading, TimelineHandle.target + 3)
                    .opacity(width > TimelineHandle.target * 2 + 20 ? 1 : 0)
                    .animation(StudioMotion.state, value: width > TimelineHandle.target * 2 + 20)
            }
            .overlay(alignment: .leading) { edge(run, leading: true, width: width) }
            .overlay(alignment: .trailing) { edge(run, leading: false, width: width) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                model.select(.soundRun(run.id),
                             extending: NSEvent.modifierFlags.contains(.command))
            }
            .gesture(move(run))
            .contextMenu {
                Button("Delete", role: .destructive) { model.deleteSelection(run.id) }
                Divider()
                laneMenu
            }
            .help("Sound · \(Timecode.length(live.duration))")
            // Placed rather than offset — see `TimelineRegionRow.body(for:)`.
            .position(x: left + width / 2, y: height / 2)
    }

    // MARK: - Gestures

    /// A grabbable end of a run — see `TimelineHandle`.
    private func edge(_ run: SoundRun, leading: Bool, width: CGFloat) -> some View {
        let key = "\(run.id)-\(leading)"
        let isHovered = hoveredGrip == key
        return TimelineHandle(leading: leading,
                              height: height,
                              chipWidth: width,
                              radius: radius,
                              isVisible: model.isSelected(.soundRun(run.id)) || isHovered,
                              isHovered: isHovered,
                              label: leading ? "Drag to trim the start of this sound"
                                             : "Drag to trim the end of this sound")
            .onHover { inside in
                guard !model.isGesturing else { return }
                hoveredGrip = inside ? key : (hoveredGrip == key ? nil : hoveredGrip)
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(trim(run, leading: leading))
    }

    /// Dragging the body slides everything selected and keeps it playing the same words,
    /// which is what "line the narration up with the click" means.
    ///
    /// Nothing is applied while the pointer moves — see `TimelineDrag`.
    private func move(_ run: SoundRun) -> some Gesture {
        drag(run, grip: .body)
    }

    /// Dragging an end trims: the sound that survives stays exactly where it was, and the
    /// run covers less of the timeline. The head is the interesting one — see
    /// `Commands.MoveSoundRun.trimsHead`.
    private func trim(_ run: SoundRun, leading: Bool) -> some Gesture {
        drag(run, grip: leading ? .head : .tail)
    }

    private func drag(_ run: SoundRun, grip: TimelineDrag.Grip) -> some Gesture {
        // Measured in the window's coordinates, never the chip's.
        //
        // `DragGesture`'s default space is `.local` — the dragged view's own — and this
        // view *moves while it is being dragged*, which makes that space move with it. Every
        // point the chip travels to the right takes the pointer's local x the same distance
        // to the left, so the translation shrinks, so the chip comes back, so the
        // translation grows again. That oscillation is the chip appearing at its old and new
        // positions on alternate frames. A space that does not move cannot feed back.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if !model.drag.isActive {
                    model.beginDrag(anchor: .soundRun(run.id), grip: grip)
                }
                model.dragOffset(CMTime(seconds: value.translation.width / viewport.pointsPerSecond,
                                        preferredTimescale: 600),
                                 pointsPerSecond: viewport.pointsPerSecond)
            }
            .onEnded { _ in model.endDrag() }
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
            // Given the lane from the screen's left edge to this piece's right-hand one,
            // then slid back onto the piece — see `TimelineRegionRow.shape(of:width:left:)`
            // for the piece-sized canvas this replaces, which drew nothing for any piece
            // further along than it was long.
            TimelineWaveform(viewport: viewport, spans: spans, peaks: peaks, height: height)
                .frame(width: max(0, min(viewport.width, left + width)), alignment: .leading)
                .offset(x: -left)
                .frame(width: width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: isMuted ? "speaker.slash.fill"
                  : (track?.symbol ?? (model.isSoundDetached ? "waveform.badge.minus" : "waveform")))
                .font(.system(size: 9, weight: .semibold))
            // No name here. The gutter beside the lane carries it, and a chip repeating
            // it would be the same word twice, one of them sitting on top of the waveform
            // it is there to let you read.
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
