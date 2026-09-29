import AVFoundation
import CoreMedia
import Foundation
import TimelineKit

/// The recording's sound through a transition, so it is heard the way the picture is seen.
///
/// A dip is a fade: the sound goes down to nothing at the cut and comes back up, over the
/// same half-lengths the picture takes to go to black and return. A crossfade is a real
/// one, which the picture's frozen edges cannot be: the outgoing clip's sound carries on
/// past the cut and the incoming clip's starts before it, each fading as the other rises.
/// That is sound the edit does not otherwise use — the recording on either side of the cut
/// — and it is what makes the change of scene sound continuous rather than chopped. It is
/// laid on a second track, because one track cannot play two things at one moment.
///
/// Linear ramps that meet at half level at the cut, so the two sides always add up to the
/// level the source is set to and a crossfade is never louder or quieter than its clips.
extension AudioMixdown {
    static func levelsThroughTransitions(of timeline: Timeline,
                                         on following: AVMutableCompositionTrack,
                                         from source: AVAssetTrack,
                                         at level: Double,
                                         treatedWith recipe: VoiceRecipe? = nil,
                                         into composition: AVMutableComposition) -> [AVAudioMixInputParameters] {
        let moments = timeline.transitions
        let gain = Float(max(0, level))

        let main = AVMutableAudioMixInputParameters(track: following)
        main.setVolume(gain, at: .zero)
        // The voice treatment goes through a transition too: without it, every project with
        // one would lose its clean-up and levelling on the whole of its sound.
        if let recipe { main.audioTapProcessor = VoiceTap.make(recipe) }
        for moment in moments {
            let (before, after) = halves(of: moment)
            // At the cut: nothing through a dip, half through a crossfade.
            let middle: Float = moment.style == .crossfade ? gain / 2 : 0
            main.setVolumeRamp(fromStartVolume: gain, toEndVolume: middle, timeRange: before)
            main.setVolumeRamp(fromStartVolume: middle, toEndVolume: gain, timeRange: after)
        }

        let crossfades = moments.filter { $0.style == .crossfade }
        guard !crossfades.isEmpty,
              let overlap = appendOverlaps(crossfades, of: timeline, from: source, into: composition)
        else { return [main] }

        let other = AVMutableAudioMixInputParameters(track: overlap)
        other.setVolume(0, at: .zero)
        if let recipe { other.audioTapProcessor = VoiceTap.make(recipe) }
        for moment in crossfades {
            let (before, after) = halves(of: moment)
            other.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain / 2, timeRange: before)
            other.setVolumeRamp(fromStartVolume: gain / 2, toEndVolume: 0, timeRange: after)
        }
        return [main, other]
    }

    /// The two halves of a transition, either side of its cut.
    private static func halves(of moment: TransitionMoment) -> (before: CMTimeRange, after: CMTimeRange) {
        let half = CMTimeMultiplyByFloat64(moment.duration, multiplier: 0.5)
        return (CMTimeRange(start: moment.cut - half, duration: half),
                CMTimeRange(start: moment.cut, duration: half))
    }

    /// The sound each side of a crossfade lends the other: the incoming clip's recording
    /// from just before its in-point, laid before the cut, and the outgoing clip's from
    /// just after its out-point, laid after it.
    ///
    /// Held to the recording at both ends — there is no sound before its start or after
    /// its end to lend — and to footage: a freeze frame or a title has no sound, so its
    /// side of the crossfade fades against silence.
    private static func appendOverlaps(_ crossfades: [TransitionMoment],
                                       of timeline: Timeline,
                                       from source: AVAssetTrack,
                                       into composition: AVMutableComposition) -> AVMutableCompositionTrack? {
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var filled = CMTime.zero

        /// Lays `sourceRange` of the recording at `time`, played at `speed`.
        func lay(_ sourceRange: CMTimeRange, at time: CMTime, speed: Double) {
            guard sourceRange.duration > .zero, time >= filled else { return }
            if time > filled { track.insertEmptyTimeRange(CMTimeRange(start: filled, end: time)) }
            do {
                try track.insertTimeRange(sourceRange, of: source, at: time)
            } catch {
                // Past the end of the recording's sound: silence, as everywhere else.
                filled = time
                return
            }
            let length = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1 / speed)
            if speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: time, duration: sourceRange.duration), toDuration: length)
            }
            filled = time + length
        }

        for moment in crossfades {
            let half = CMTimeMultiplyByFloat64(moment.duration, multiplier: 0.5)
            let incoming = timeline.clips[moment.incoming]
            let outgoing = timeline.clips[moment.outgoing]

            // The recording's sound only: an imported clip lends none of the recording.
            if incoming.playsRecording {
                let wanted = CMTimeMultiplyByFloat64(half, multiplier: incoming.speed)
                let from = max(.zero, incoming.sourceStart - wanted)
                let lent = CMTimeRange(start: from, end: incoming.sourceStart)
                lay(lent, at: moment.cut - CMTimeMultiplyByFloat64(lent.duration, multiplier: 1 / incoming.speed),
                    speed: incoming.speed)
            }
            if outgoing.playsRecording {
                let wanted = CMTimeMultiplyByFloat64(half, multiplier: outgoing.speed)
                let to = min(timeline.sourceDuration, outgoing.sourceEnd + wanted)
                lay(CMTimeRange(start: outgoing.sourceEnd, end: to), at: moment.cut, speed: outgoing.speed)
            }
        }
        return track
    }
}
