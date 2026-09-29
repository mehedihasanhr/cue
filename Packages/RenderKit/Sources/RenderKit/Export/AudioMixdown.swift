import AVFoundation
import CoreMedia
import Foundation
import TimelineKit

/// The edit's sound, as one asset to read from.
///
/// Built as an `AVComposition` rather than mixed by hand: trimming, reordering and
/// speed changes are exactly what a composition's time mapping is for, and asking
/// AVFoundation to resample a sped-up clip is both less code and better sounding than
/// anything written here would be.
///
/// The same clip list drives this and the video loop, so the two cannot drift: if a cut
/// moves, both move, because both read `timeline.clips` — unless the user has explicitly
/// detached the sound, in which case `timeline.detachedSound` is the whole truth about it
/// and the clips say nothing. Both states are laid down here, in one function, because
/// this one function is what the preview plays *and* what the exporter writes: the moment
/// there were two, the thing you heard while cutting would stop being the thing you shipped.
public enum AudioMixdown {
    /// What the exporter reads the finished audio out of.
    ///
    /// `@unchecked` because `AVComposition` and `AVAudioMix` are not `Sendable`, and the
    /// check cannot see why these two are safe: both are the *immutable* halves of their
    /// mutable pairs, copied out of the builders below and never touched again. Nothing
    /// holds a reference to the mutable originals once `build` returns, so what crosses
    /// to the exporter is a value in everything but its type.
    public struct Result: @unchecked Sendable {
        public let composition: AVComposition
        /// Per-track gain, or `nil` when everything plays at its recorded level.
        public let audioMix: AVAudioMix?
        public var isEmpty: Bool { composition.tracks(withMediaType: .audio).isEmpty }
    }

    /// Builds the edited audio for a timeline.
    ///
    /// - Parameters:
    ///   - videoURL: the recording. Its audio tracks carry the screen and microphone on a
    ///     recording made before the sources were captured separately; on a newer one it
    ///     has no audio at all and every source is a file in the package.
    ///   - packageURL: the project — for `AudioRegion` files stored inside it, and for the
    ///     recording's own sources.
    ///   - clicks: the recording's clicks, for the click sounds. Passed by the preview and
    ///     the exporter alike, so the clicks you hear while editing are the ones exported.
    ///   - clickFrame: the recording's size in points, so clicks outside the crop — which
    ///     are not drawn — are not heard either. `nil` hears them all.
    public static func build(timeline: Timeline,
                             videoURL: URL,
                             packageURL: URL?,
                             clicks: [CursorTrack.Click] = [],
                             clickFrame: CGSize? = nil) async -> Result {
        let clicks = clickFrame.map { timeline.visibleClicks(clicks, frame: $0) } ?? clicks
        let composition = AVMutableComposition()
        var parameters = await appendRecordedAudio(of: timeline, from: videoURL,
                                                   packageURL: packageURL, into: composition)
        // The movies brought into the project, under their own clips. See
        // `AudioMixdown+Imported`.
        parameters += await appendImportedAudio(of: timeline, packageURL: packageURL, into: composition)
        let speech = await speech(in: timeline, videoURL: videoURL, packageURL: packageURL)
        parameters += await appendAudioRegions(of: timeline, packageURL: packageURL, speech: speech,
                                               into: composition)
        parameters += await appendClickSounds(of: timeline, clicks: clicks, into: composition)

        var mix: AVAudioMix?
        if !parameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = parameters
            // Copied to the immutable class for the reason in `Result`'s note: what
            // leaves here must be something nobody can change afterwards.
            mix = audioMix.copy() as? AVAudioMix
        }
        return Result(composition: composition.copy() as! AVComposition, audioMix: mix)
    }

    /// The recording's own sound, cut the way the picture is cut, at the level the edit
    /// asks for.
    ///
    /// Two shapes of recording arrive here and both have to sound right. A recording made
    /// since the sources were separated carries a file per source — the screen, each
    /// microphone — and each is laid down at its own level under the master, which is the
    /// whole point: turning the screen down must not touch the voice. A recording made
    /// before that has its sound inside the video file, where the tracks cannot be told
    /// apart, so all of them are laid down together at the master level, exactly as they
    /// always were.
    ///
    /// Silenced means *absent*, not turned down to nothing: a muted source should cost
    /// neither the decoding nor the space, and an export of a silent edit should have no
    /// audio track rather than an empty one. That applies per source now, so a muted
    /// microphone costs nothing while the screen goes on playing.
    private static func appendRecordedAudio(of timeline: Timeline,
                                            from videoURL: URL,
                                            packageURL: URL?,
                                            into composition: AVMutableComposition) async -> [AVAudioMixInputParameters] {
        guard timeline.sound.isAudible else { return [] }

        guard timeline.hasSeparateSound else {
            let asset = AVURLAsset(url: videoURL)
            guard let sources = try? await asset.loadTracks(withMediaType: .audio) else { return [] }
            var parameters: [AVAudioMixInputParameters] = []
            for (index, source) in sources.enumerated() {
                let recipe = await SoundAnalyzer.shared.recipe(for: videoURL, track: index,
                                                               cleansVoice: timeline.sound.cleansVoice,
                                                               evensVolume: timeline.sound.evensVolume)
                parameters += lay(source, of: timeline, at: timeline.sound.level, treatedWith: recipe,
                                  into: composition)
            }
            return parameters
        }

        var parameters: [AVAudioMixInputParameters] = []
        for track in timeline.soundTracks {
            let level = timeline.level(of: track)
            guard level > 0, let packageURL else { continue }
            let asset = AVURLAsset(url: packageURL.appendingPathComponent(track.path))
            // One audio track per file, by construction — the recorder wrote it that way so
            // that this line could be a `.first` rather than a guess about ordering.
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
            let recipe = await SoundAnalyzer.shared.recipe(for: asset.url, cleansVoice: track.style.cleansVoice,
                                                           evensVolume: track.style.evensVolume)
            parameters += lay(source, of: timeline, at: level, treatedWith: recipe, into: composition)
        }
        return parameters
    }

    /// One source of sound, laid across the edit at one level.
    ///
    /// The two states of the lane, and the only place in the app that has to know there
    /// are two. Everything downstream — the player, the exporter, the playhead that
    /// follows the player's clock — sees one composition either way.
    private static func lay(_ source: AVAssetTrack,
                            of timeline: Timeline,
                            at level: Double,
                            treatedWith recipe: VoiceRecipe? = nil,
                            into composition: AVMutableComposition) -> [AVAudioMixInputParameters] {
        let laid = timeline.detachedSound.map { runs in
            appendDetached(runs, of: source, into: composition)
        } ?? [appendFollowingClips(timeline.clips, of: source, into: composition)].compactMap { $0 }

        // A cut with a transition fades the sound with the picture — but only while the
        // sound follows the picture. A detached lane is the whole truth about the sound,
        // and the cuts it was detached from say nothing about it any more.
        if timeline.detachedSound == nil, let following = laid.first, !timeline.transitions.isEmpty {
            return levelsThroughTransitions(of: timeline, on: following, from: source,
                                            at: level, treatedWith: recipe, into: composition)
        }

        guard level != 1 || recipe != nil else { return [] }
        return laid.map { track in
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(Float(level), at: .zero)
            // A tap per track: a detached lane is several tracks, and a tap carries the
            // state of the one sound running through it.
            if let recipe { input.audioTapProcessor = VoiceTap.make(recipe) }
            return input
        }
    }

    /// The sound cut exactly where the picture is cut: one contiguous track, clip by clip.
    ///
    /// Unchanged from the day the preview learned to play, and deliberately so — this is
    /// what every project written before the sound could be detached must go on sounding
    /// like, down to the track count.
    private static func appendFollowingClips(_ clips: [Clip],
                                             of source: AVAssetTrack,
                                             into composition: AVMutableComposition) -> AVMutableCompositionTrack? {
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var playhead = CMTime.zero
        /// How far the track has really been filled, which falls behind `playhead` over a
        /// freeze frame or a title — both silent — and is caught up with an empty range,
        /// said out loud, as the detached lane does. Over an imported clip too: its sound
        /// is its own file's, laid on a track of its own.
        var filled = CMTime.zero
        for clip in clips {
            guard clip.playsRecording else {
                playhead = playhead + clip.duration
                continue
            }
            if playhead > filled {
                track.insertEmptyTimeRange(CMTimeRange(start: filled, end: playhead))
                filled = playhead
            }
            let range = CMTimeRange(start: clip.sourceStart, duration: clip.sourceDuration)
            do {
                try track.insertTimeRange(range, of: source, at: playhead)
            } catch {
                // A clip reaching past the end of the sound — a recording whose audio
                // stops a few milliseconds early — leaves silence rather than failing the
                // export. The picture is still there to show.
                playhead = playhead + clip.duration
                continue
            }
            if clip.speed != 1 {
                // The range as it now sits in the composition, scaled to the length the
                // clip occupies on the timeline.
                track.scaleTimeRange(CMTimeRange(start: playhead, duration: clip.sourceDuration),
                                     toDuration: clip.duration)
            }
            playhead = playhead + clip.duration
            filled = playhead
        }
        // An edit that ends on a still or a title has sound that ends before its picture,
        // like one whose recording's sound stops a little early: a composition keeps no
        // empty stretch at its end to pad it with. The exporter finishes the sound when it
        // runs out, and the preview goes back to the wall clock for the rest.
        return track
    }

    /// A detached lane: runs laid at the times they claim, with silence between them.
    ///
    /// Three things make this more than the loop above with different numbers. A run says
    /// where it starts, so the gaps are real and have to be inserted as empty ranges rather
    /// than arrived at by adding up lengths. Runs need not be in order, so they are sorted
    /// first — a composition track is built front to back whatever order the user dragged
    /// them into. And runs may *overlap*, because two of them over one moment is an
    /// ordinary edit (a word held over a cut), which one track cannot express: so a run
    /// that would start before the current track has finished opens a new one. That is what
    /// an editor's audio lanes are underneath, and it is why this returns several tracks.
    private static func appendDetached(_ runs: [SoundRun],
                                       of source: AVAssetTrack,
                                       into composition: AVMutableComposition) -> [AVMutableCompositionTrack] {
        var tracks: [AVMutableCompositionTrack] = []
        /// How far each track has been filled, so the next run can find one that is free.
        var filled: [CMTime] = []

        for run in runs.sorted(by: { $0.start < $1.start }) {
            guard run.duration > .zero else { continue }
            let lane = filled.firstIndex { $0 <= run.start } ?? tracks.count
            if lane == tracks.count {
                guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                tracks.append(track)
                filled.append(.zero)
            }
            let track = tracks[lane]

            // The silence before this run, said out loud. Relying on `insertTimeRange(at:)`
            // past the end of a track to pad would work today and is not written down
            // anywhere; an empty range is.
            if run.start > filled[lane] {
                track.insertEmptyTimeRange(CMTimeRange(start: filled[lane], end: run.start))
            }

            let range = CMTimeRange(start: run.sourceStart, duration: run.sourceDuration)
            do {
                try track.insertTimeRange(range, of: source, at: run.start)
            } catch {
                // Same bargain as the attached branch: a run reaching past the end of the
                // recording's sound leaves silence rather than failing the export.
                filled[lane] = run.start
                continue
            }
            if run.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: run.start, duration: run.sourceDuration),
                                     toDuration: run.duration)
            }
            filled[lane] = run.end
        }
        return tracks
    }

    /// Music, voiceover, anything dropped on top. Each gets its own track so one can be
    /// quiet without the others being touched.
    private static func appendAudioRegions(of timeline: Timeline,
                                           packageURL: URL?,
                                           speech: [ClosedRange<Double>] = [],
                                           into composition: AVMutableComposition) async -> [AVAudioMixInputParameters] {
        guard let packageURL else { return [] }
        var parameters: [AVAudioMixInputParameters] = []

        for region in timeline.audio {
            let url = packageURL.appendingPathComponent(region.path)
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            let range = CMTimeRange(start: region.sourceStart, duration: region.duration)
            guard (try? track.insertTimeRange(range, of: source, at: region.start)) != nil else { continue }

            let fades = region.heardFades
            if region.ducksUnderSpeech {
                parameters.append(duckedLevels(for: region, under: speech, on: track))
                continue
            }
            guard region.gain != 1 || fades.fadeIn > 0 || fades.fadeOut > 0 else { continue }
            parameters.append(levels(for: region, on: track))
        }
        return parameters
    }

    /// An added sound's level over time: its gain, reached from silence over the fade in
    /// and taken back to silence over the fade out.
    ///
    /// Ramps rather than a level per moment, because a ramp is what the mixer applies
    /// sample by sample. A fade stepped even every frame is audible as a staircase.
    /// A ramp may not overlap a set level, so the level is only set where there is no
    /// fade in to reach it.
    static func levels(for region: AudioRegion, on track: AVAssetTrack) -> AVMutableAudioMixInputParameters {
        let input = AVMutableAudioMixInputParameters(track: track)
        let gain = Float(max(0, region.gain))
        // Corner to corner, each ramp from the level there to the level at the next, so a
        // piece that starts part-way up a fade (an excerpt) starts at that level rather
        // than at silence. Laid end to end: the mix does not allow ramps to overlap.
        let corners = region.fadeCorners
        input.setVolume(gain * Float(region.shape(at: region.start)), at: .zero)
        for (from, to) in zip(corners, corners.dropFirst()) where to > from {
            input.setVolumeRamp(fromStartVolume: gain * Float(region.shape(at: from)),
                                toEndVolume: gain * Float(region.shape(at: to)),
                                timeRange: CMTimeRange(start: from, end: to))
        }
        return input
    }

    /// A click sound wherever a click is seen. See `Timeline.clickSoundMoments(for:)`.
    ///
    /// Each sound is laid on the first track that is free by then. A double-click puts
    /// two sounds closer together than one of them lasts, and a track cannot hold two
    /// things at one moment, so the second goes on another track rather than cutting the
    /// first off. Four is plenty: nobody clicks five times inside seventy milliseconds.
    private static func appendClickSounds(of timeline: Timeline,
                                          clicks: [CursorTrack.Click],
                                          into composition: AVMutableComposition) async -> [AVAudioMixInputParameters] {
        let moments = timeline.clickSoundMoments(for: clicks)
        guard !moments.isEmpty,
              let url = try? ClickSound.file(for: timeline.cursor.clickSoundKind) else { return [] }
        let asset = AVURLAsset(url: url)
        guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
              let length = try? await asset.load(.duration), length > .zero else { return [] }

        let end = timeline.duration
        var lanes: [(track: AVMutableCompositionTrack, freeAt: CMTime)] = []
        for moment in moments where moment.time < end {
            let lane: Int
            if let free = lanes.firstIndex(where: { $0.freeAt <= moment.time }) {
                lane = free
            } else {
                guard lanes.count < 4,
                      let track = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                lanes.append((track, .zero))
                lane = lanes.count - 1
            }
            // Cut short at the end of the edit rather than running past it: a sound
            // longer than the picture would make the export's audio outlast its video.
            let heard = CMTimeMinimum(length, end - moment.time)
            guard (try? lanes[lane].track.insertTimeRange(CMTimeRange(start: .zero, duration: heard),
                                                          of: source, at: moment.time)) != nil else { continue }
            lanes[lane].freeAt = moment.time + heard
        }

        let volume = Float(timeline.cursor.clickSoundVolume)
        return lanes.map { lane in
            let input = AVMutableAudioMixInputParameters(track: lane.track)
            input.setVolume(volume, at: .zero)
            return input
        }
    }
}
