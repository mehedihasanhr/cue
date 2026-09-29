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
