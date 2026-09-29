import AVFoundation
import CoreMedia
import Foundation
import TimelineKit

extension AudioMixdown {
    /// When somebody is speaking, on the timeline — only asked for when some added sound
    /// is set to go down under speech.
    ///
    /// The captions' word timings when there are captions: they are what a person already
    /// checked, and they know a word from a door closing. Otherwise the voice's own levels,
    /// measured once from its file and carried through the edit's cuts. Nothing heard is
    /// nobody speaking, so a muted voice ducks nothing.
    static func speech(in timeline: Timeline, videoURL: URL, packageURL: URL?) async -> [ClosedRange<Double>] {
        guard timeline.ducksAnything else { return [] }
        let captions = timeline.speechFromCaptions
        if !captions.isEmpty { return captions }

        if timeline.hasSeparateSound {
            guard let voice = timeline.duckingVoice, let packageURL else { return [] }
            let measured = await SoundAnalyzer.shared.measurement(of: packageURL.appendingPathComponent(voice.path))
            return timeline.timelineStretches(ofRecorded: measured?.speech ?? [])
        }

        // A recording from before the sources were separated: the voice is somewhere in
        // the video's own tracks, and there is no telling which, so any of them counts.
        guard timeline.sound.isAudible,
              let tracks = try? await AVURLAsset(url: videoURL).loadTracks(withMediaType: .audio) else { return [] }
        var heard: [ClosedRange<Double>] = []
        for index in tracks.indices {
            heard += await SoundAnalyzer.shared.measurement(of: videoURL, track: index)?.speech ?? []
        }
        return timeline.timelineStretches(ofRecorded: heard)
    }

    /// An added sound's level over time with its dips under speech: the corners from
    /// `Ducking.envelope`, joined by ramps.
    ///
    /// Ramps rather than a sampled level for the reason `levels(for:on:)` gives, and
    /// laid end to end so that none overlaps the next, which the mix does not allow.
    static func duckedLevels(for region: AudioRegion,
                             under speech: [ClosedRange<Double>],
                             on track: AVAssetTrack) -> AVMutableAudioMixInputParameters {
        let input = AVMutableAudioMixInputParameters(track: track)
        let points = Ducking.envelope(for: region, speech: speech).map {
            (time: CMTime(seconds: $0.seconds, preferredTimescale: 48_000), volume: Float($0.volume))
        }
        for (from, to) in zip(points, points.dropFirst()) where to.time > from.time {
            input.setVolumeRamp(fromStartVolume: from.volume, toEndVolume: to.volume,
                                timeRange: CMTimeRange(start: from.time, end: to.time))
        }
        return input
    }
}

extension AudioMixdown.Result {
    /// The sound as the preview plays it.
    ///
    /// Made here, beside the exporter's reader, so that the one thing the preview adds —
    /// hanging the mix on a player item — cannot quietly leave the mix off. The mix is
    /// where the voice clean-up and the dips under speech live; an item without it would
    /// play the untreated sound while the export shipped the treated one.
    @MainActor
    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        return item
    }
}
