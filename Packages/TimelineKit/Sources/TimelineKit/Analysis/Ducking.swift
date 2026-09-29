import CoreMedia
import Foundation

/// Music lowered wherever somebody speaks, as a level over time.
///
/// Worked out here, as numbers, rather than by listening to the voice while mixing: the
/// mixer only knows how to follow volume ramps, and ramps laid into the audio mix are what
/// both the preview's player and the exporter's reader obey. A side-chain compressor would
/// sound much the same and would be a second thing to keep in step between the two.
public enum Ducking {
    /// Seconds the music takes to go down. It starts going down this long *before* the
    /// first word, so the word lands on music that is already out of its way.
    public static let attack: Double = 0.2
    /// Seconds it takes to come back after the last word.
    public static let release: Double = 0.6
    /// Pauses shorter than this stay lowered. Music that rises for every breath between
    /// two words pumps, which is the one thing ducking is known for doing badly.
    public static let bridge: Double = attack + release + 0.2
    /// Words closer to the edges of what is kept than this are not worth a dip.
    public static let shortest: Double = 0.08

    /// One corner of the level over time: at `seconds` on the timeline, the sound plays
    /// at `volume` (1 is its own level), and it moves in a straight line to the next.
    public struct Point: Equatable, Sendable {
        public var seconds: Double
        public var volume: Double

        public init(seconds: Double, volume: Double) {
            self.seconds = seconds
            self.volume = volume
        }
    }

    /// Speech as stretches, sorted, with the short pauses inside a sentence filled in.
    public static func merged(_ stretches: [ClosedRange<Double>],
                              bridging gap: Double = bridge) -> [ClosedRange<Double>] {
        let sorted = stretches
            .filter { $0.lowerBound.isFinite && $0.upperBound.isFinite }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Double>] = []
        for stretch in sorted {
            if let last = result.last, stretch.lowerBound - last.upperBound <= gap {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, stretch.upperBound)
            } else {
                result.append(stretch)
            }
        }
        return result.filter { $0.upperBound - $0.lowerBound >= shortest }
    }

    /// The lowered level as a fraction: 12 dB down is about a quarter.
    public static func floor(forAmount decibels: Double) -> Double {
        let amount = decibels.isFinite ? min(max(decibels, 0), 60) : AudioRegion.defaultDuckAmount
        return pow(10, -amount / 20)
    }

    /// How far down the ducking alone has the sound at a moment: 1 when nobody speaks,
    /// `floor` under a word, and a straight line between the two on the way.
    ///
    /// `speech` must already be `merged`, which is what keeps the ramps of two stretches
    /// from overlapping.
    public static func duck(at seconds: Double, speech: [ClosedRange<Double>], floor: Double) -> Double {
        var level = 1.0
        for stretch in speech {
            let down = stretch.lowerBound - attack
            let up = stretch.upperBound + release
            guard seconds > down, seconds < up else { continue }
            let here: Double
            if seconds < stretch.lowerBound {
                here = 1 - (1 - floor) * (seconds - down) / attack
            } else if seconds <= stretch.upperBound {
                here = floor
            } else {
                here = floor + (1 - floor) * (seconds - stretch.upperBound) / release
            }
            level = min(level, here)
        }
        return level
    }

    /// The whole level of one added sound over its length: its gain, its fades and the
    /// dips under speech multiplied together, as corners joined by straight lines.
    ///
    /// Corners go wherever either the fades or the dips change direction, so between two
    /// corners at most one of them is moving and the straight line is exact — except where
    /// a fade and a dip overlap, where it is the chord of a gentle curve and nobody can
    /// hear the difference.
    public static func envelope(for region: AudioRegion, speech: [ClosedRange<Double>]) -> [Point] {
        let start = region.start.seconds
        let end = region.end.seconds
        guard end > start else { return [] }
        let gain = max(0, region.gain)
        let floor = floor(forAmount: region.duckAmount)
        let merged = merged(speech)

        var corners = Set(region.fadeCorners.map(\.seconds))
        for stretch in merged {
            for corner in [stretch.lowerBound - attack, stretch.lowerBound,
                           stretch.upperBound, stretch.upperBound + release] {
                corners.insert(corner)
            }
        }

        return corners
            .filter { $0 >= start && $0 <= end }
            .sorted()
            .map { seconds in
                // The shape rather than the envelope: the envelope is 0 at the region's
                // very end, which is only right for a fade out.
                let fade = region.shape(at: CMTime(seconds: seconds, preferredTimescale: 48_000))
                return Point(seconds: seconds,
                             volume: gain * fade * duck(at: seconds, speech: merged, floor: floor))
            }
    }
}

public extension Timeline {
    /// When somebody is speaking, read off the captions' word timings, on the timeline.
    ///
    /// Empty when there are no captions, which is the caller's cue to listen to the voice
    /// instead. Every word counts, including those in a line typed by hand, whose timings
    /// are spread across the line by length — near enough for music to get out of the way.
    var speechFromCaptions: [ClosedRange<Double>] {
        captions.flatMap { cue -> [ClosedRange<Double>] in
            let start = cue.start.seconds
            let length = cue.duration.seconds
            guard length > 0 else { return [] }
            return cue.timedWords.map { word in
                (start + word.from * length)...(start + max(word.from, word.to) * length)
            }
        }
    }

    /// Stretches of the recording, in the recording's own seconds, as they land on the
    /// timeline once the edit has cut, reordered and sped them up.
    ///
    /// Through the detached lane when there is one, because then that lane is what is
    /// heard; otherwise through the picture's clips. A stretch that was cut out is not
    /// heard and has no place here, and a stretch used twice is here twice.
    func timelineStretches(ofRecorded stretches: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        struct Piece { let at: Double; let from: Double; let to: Double; let speed: Double }
        var pieces: [Piece] = []
        if let runs = detachedSound {
            pieces = runs.map {
                Piece(at: $0.start.seconds, from: $0.sourceStart.seconds,
                      to: $0.sourceEnd.seconds, speed: $0.speed)
            }
        } else {
            var playhead = 0.0
            for clip in clips {
                // The recording's speech is not heard over an imported clip.
                if clip.source == nil {
                    pieces.append(Piece(at: playhead, from: clip.sourceStart.seconds,
                                        to: clip.sourceEnd.seconds, speed: clip.speed))
                }
                playhead += clip.duration.seconds
            }
        }
        var result: [ClosedRange<Double>] = []
        for piece in pieces where piece.speed > 0 {
            for stretch in stretches {
                let from = max(stretch.lowerBound, piece.from)
                let to = min(stretch.upperBound, piece.to)
                guard to > from else { continue }
                result.append((piece.at + (from - piece.from) / piece.speed)...(piece.at + (to - piece.from) / piece.speed))
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Whether any added sound is set to go down under speech.
    var ducksAnything: Bool { audio.contains { $0.ducksUnderSpeech } }

    /// The source whose voice the music listens to when there are no captions: the
    /// speech lane, if it is heard. A muted microphone is nobody speaking.
    var duckingVoice: SoundTrack? {
        guard let voice = soundTrackForSpeech, isAudible(voice), sound.isAudible else { return nil }
        return voice
    }
}
