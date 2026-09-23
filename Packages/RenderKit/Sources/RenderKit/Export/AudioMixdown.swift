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
/// moves, both move, because both read `timeline.clips`.
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
    ///   - videoURL: the recording, whose audio tracks carry the screen and microphone.
    ///   - packageURL: the project, for `AudioRegion` files stored inside it.
    public static func build(timeline: Timeline,
                             videoURL: URL,
                             packageURL: URL?) async -> Result {
        let composition = AVMutableComposition()
        await appendRecordedAudio(of: timeline, from: videoURL, into: composition)
        let parameters = await appendAudioRegions(of: timeline, packageURL: packageURL, into: composition)

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

    /// The recording's own sound, cut the way the picture is cut.
    private static func appendRecordedAudio(of timeline: Timeline,
                                            from videoURL: URL,
                                            into composition: AVMutableComposition) async {
        let asset = AVURLAsset(url: videoURL)
        guard let sources = try? await asset.loadTracks(withMediaType: .audio), !sources.isEmpty else { return }

        for source in sources {
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var playhead = CMTime.zero
            for clip in timeline.clips {
                let range = CMTimeRange(start: clip.sourceStart, duration: clip.sourceDuration)
                do {
                    try track.insertTimeRange(range, of: source, at: playhead)
                } catch {
                    // A clip reaching past the end of the sound — a recording whose
                    // audio stops a few milliseconds early — leaves silence rather than
                    // failing the export. The picture is still there to show.
                    playhead = playhead + clip.duration
                    continue
                }
                if clip.speed != 1 {
                    // The range as it now sits in the composition, scaled to the length
                    // the clip occupies on the timeline.
                    track.scaleTimeRange(CMTimeRange(start: playhead, duration: clip.sourceDuration),
                                         toDuration: clip.duration)
                }
                playhead = playhead + clip.duration
            }
        }
    }

    /// Music, voiceover, anything dropped on top. Each gets its own track so one can be
    /// quiet without the others being touched.
    private static func appendAudioRegions(of timeline: Timeline,
                                           packageURL: URL?,
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

            guard region.gain != 1 else { continue }
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(Float(max(0, region.gain)), at: .zero)
            parameters.append(input)
        }
        return parameters
    }
}
