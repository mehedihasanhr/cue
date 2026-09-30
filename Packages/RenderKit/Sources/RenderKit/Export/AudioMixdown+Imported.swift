import AVFoundation
import CoreMedia
import Foundation
import TimelineKit

/// The sound of the movies brought into the project, under their clips.
///
/// An imported clip's sound is part of the clip, the way the recording's sound is part of
/// the recording's clips while the lane is attached: cut where the clip is cut, sped up
/// with it, moved with it. It stays that way when the recording's lane is detached. That
/// lane is the *recording's* sound set free of its picture — its runs name moments of the
/// recording and nothing else — so a detach neither takes an imported clip's sound onto
/// it nor leaves the clip silent. What an imported clip sounds like is always what it
/// plays.
///
/// Heard at the recording's master level, and silenced with it: "mute the recording" is
/// what someone reaches for to hear a voiceover alone, and a clip in the middle that went
/// on talking would be a surprise. The separate sources' own levels are the recording's
/// microphones and screen, which an imported movie has none of.
extension AudioMixdown {
    static func appendImportedAudio(of timeline: Timeline,
                                    packageURL: URL?,
                                    into composition: AVMutableComposition) async -> [AVAudioMixInputParameters] {
        guard timeline.sound.isAudible, let packageURL else { return [] }
        let paths = timeline.clips.compactMap { clip in clip.isFootage ? clip.source : nil }
        guard !paths.isEmpty else { return [] }

        var parameters: [AVAudioMixInputParameters] = []
        var opened: Set<String> = []
        for path in paths where !opened.contains(path) {
            opened.insert(path)
            // Measured when it arrived: a movie with no sound is not opened to find none.
            if timeline.media.first(where: { $0.path == path })?.hasSound == false { continue }
            let asset = AVURLAsset(url: packageURL.appendingPathComponent(path))
            guard let sources = try? await asset.loadTracks(withMediaType: .audio) else { continue }
            // Every track the file has: another take brought in with its microphone and
            // its screen's sound carries both, and both are what it sounded like.
            for source in sources {
                guard let track = layClips(from: path, of: timeline, source: source, into: composition) else { continue }
                parameters.append(levels(of: timeline, on: track))
                // Its side of a crossfade, lent past the clip's own ends — as the
                // recording's clips lend theirs. See `layCrossfadeOverlaps`.
                let end = (try? await source.load(.timeRange))?.end ?? .positiveInfinity
                if let overlap = layCrossfadeOverlaps(from: path, of: timeline, source: source,
                                                      endingAt: end, into: composition) {
                    parameters.append(overlapLevels(of: timeline, on: overlap))
                }
            }
        }
        return parameters
    }

    /// The clips that play one file, laid at their places on the edit.
    ///
    /// The same shape as the recording's attached track: silence said out loud up to each
    /// clip, the clip's stretch of the file, scaled to the clip's length when it plays at
    /// another speed.
    private static func layClips(from path: String,
                                 of timeline: Timeline,
                                 source: AVAssetTrack,
                                 into composition: AVMutableComposition) -> AVMutableCompositionTrack? {
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var playhead = CMTime.zero
        var filled = CMTime.zero
        for clip in timeline.clips {
            defer { playhead = playhead + clip.duration }
            guard clip.isFootage, clip.source == path, clip.sourceDuration > .zero else { continue }
            if playhead > filled {
                track.insertEmptyTimeRange(CMTimeRange(start: filled, end: playhead))
                filled = playhead
            }
            do {
                try track.insertTimeRange(CMTimeRange(start: clip.sourceStart, duration: clip.sourceDuration),
                                          of: source, at: playhead)
            } catch {
                // A clip reaching past the end of the file's sound is silent there, as the
                // recording's is.
                continue
            }
            if clip.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: playhead, duration: clip.sourceDuration),
                                     toDuration: clip.duration)
            }
            filled = playhead + clip.duration
        }
        return track
    }

    /// The sound an imported clip lends a crossfade it is one side of: the file from just
    /// before the incoming clip's in-point, laid before the cut, and from just after the
    /// outgoing clip's out-point, laid after it — exactly what the recording's clips lend
    /// in `AudioMixdown+Transitions`, from this file instead of the recording.
    ///
    /// Without it an imported clip's sound went to half at the cut and stopped, or began
    /// at half out of nothing, while the recording beside it crossfaded properly: the one
    /// clip in the edit whose change of scene sounded chopped. On a track of its own,
    /// because the clip's main track is already playing the other side of the cut there.
    /// `nil` when this file is on neither side of any crossfade.
    private static func layCrossfadeOverlaps(from path: String,
                                             of timeline: Timeline,
                                             source: AVAssetTrack,
                                             endingAt fileEnd: CMTime,
                                             into composition: AVMutableComposition) -> AVMutableCompositionTrack? {
        let pieces = crossfadeLoans(from: path, of: timeline, fileEnd: fileEnd)
        guard !pieces.isEmpty,
              let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var filled = CMTime.zero
        for piece in pieces where piece.at >= filled {
            if piece.at > filled { track.insertEmptyTimeRange(CMTimeRange(start: filled, end: piece.at)) }
            do {
                try track.insertTimeRange(piece.source, of: source, at: piece.at)
            } catch {
                filled = piece.at
                continue
            }
            let length = CMTimeMultiplyByFloat64(piece.source.duration, multiplier: 1 / piece.speed)
            if piece.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: piece.at, duration: piece.source.duration), toDuration: length)
            }
            filled = piece.at + length
        }
        return track
    }

    /// One stretch of a file lent to a crossfade: which part of the file, where on the
    /// edit it starts, and at what speed it plays.
    struct CrossfadeLoan: Equatable {
        let source: CMTimeRange
        let at: CMTime
        let speed: Double
    }

    /// What `layCrossfadeOverlaps` lays, worked out without a composition so it can be
    /// checked on its own. Held to the file at both ends: there is nothing before its start
    /// or after its end to lend, and that side of the crossfade fades against silence.
    static func crossfadeLoans(from path: String, of timeline: Timeline, fileEnd: CMTime) -> [CrossfadeLoan] {
        var loans: [CrossfadeLoan] = []
        for moment in timeline.transitions where moment.style == .crossfade {
            let half = CMTimeMultiplyByFloat64(moment.duration, multiplier: 0.5)
            let incoming = timeline.clips[moment.incoming]
            let outgoing = timeline.clips[moment.outgoing]
            if incoming.isFootage, incoming.source == path {
                let wanted = CMTimeMultiplyByFloat64(half, multiplier: incoming.speed)
                let lent = CMTimeRange(start: max(.zero, incoming.sourceStart - wanted), end: incoming.sourceStart)
                if lent.duration > .zero {
                    let at = moment.cut - CMTimeMultiplyByFloat64(lent.duration, multiplier: 1 / incoming.speed)
                    loans.append(CrossfadeLoan(source: lent, at: at, speed: incoming.speed))
                }
            }
            if outgoing.isFootage, outgoing.source == path {
                let wanted = CMTimeMultiplyByFloat64(half, multiplier: outgoing.speed)
                let to = min(fileEnd, outgoing.sourceEnd + wanted)
                if to > outgoing.sourceEnd {
                    loans.append(CrossfadeLoan(source: CMTimeRange(start: outgoing.sourceEnd, end: to),
                                               at: moment.cut, speed: outgoing.speed))
                }
            }
        }
        return loans
    }

    /// Silent but for the crossfades, where the lent sound rises to half at the cut and
    /// falls away after it, mirroring the main track's dip to half so the two always add
    /// up to the master level.
    private static func overlapLevels(of timeline: Timeline, on track: AVAssetTrack) -> AVMutableAudioMixInputParameters {
        let input = AVMutableAudioMixInputParameters(track: track)
        let gain = Float(timeline.sound.level)
        input.setVolume(0, at: .zero)
        for moment in timeline.transitions where moment.style == .crossfade {
            let half = CMTimeMultiplyByFloat64(moment.duration, multiplier: 0.5)
            input.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain / 2,
                                timeRange: CMTimeRange(start: moment.cut - half, duration: half))
            input.setVolumeRamp(fromStartVolume: gain / 2, toEndVolume: 0,
                                timeRange: CMTimeRange(start: moment.cut, duration: half))
        }
        return input
    }

    /// The master level, and the picture's transitions heard in it: down to nothing at a
    /// dip's cut and to half at a crossfade's, as the recording's own sound goes. Laid for
    /// every transition, because a ramp over a stretch where the track is silent is heard
    /// as nothing.
    private static func levels(of timeline: Timeline, on track: AVAssetTrack) -> AVMutableAudioMixInputParameters {
        let input = AVMutableAudioMixInputParameters(track: track)
        let gain = Float(timeline.sound.level)
        input.setVolume(gain, at: .zero)
        for moment in timeline.transitions {
            let half = CMTimeMultiplyByFloat64(moment.duration, multiplier: 0.5)
            let middle: Float = moment.style == .crossfade ? gain / 2 : 0
            input.setVolumeRamp(fromStartVolume: gain, toEndVolume: middle,
                                timeRange: CMTimeRange(start: moment.cut - half, duration: half))
            input.setVolumeRamp(fromStartVolume: middle, toEndVolume: gain,
                                timeRange: CMTimeRange(start: moment.cut, duration: half))
        }
        return input
    }
}
