import CoreMedia
import Foundation

extension Timeline {
    /// Everything the edited sound is made of — and nothing else.
    ///
    /// Playing a timeline's audio means building an `AVComposition` of it, which has to
    /// open the recording's tracks; doing that on every edit would rebuild the sound
    /// because somebody dragged the corner radius. So the question "has the sound
    /// changed?" is asked of a value rather than guessed at from which command ran.
    ///
    /// What is *absent* here is the point: a background, padding, a zoom, a blur, an
    /// annotation, a caption or the pointer cannot change what comes out of the speakers,
    /// so none of them can invalidate the sound. A cut, a trim, a reorder, a speed change
    /// or an added sound can, and each is here.
    public struct AudioSignature: Equatable, Sendable {
        /// One run of the recording's own sound, as the mixdown will lay it down.
        public struct Cut: Equatable, Sendable {
            public let sourceStart: CMTime
            public let sourceDuration: CMTime
            public let speed: Double
        }

        /// A sound from outside the recording.
        public struct Sound: Equatable, Sendable {
            public let path: String
            public let start: CMTime
            public let duration: CMTime
            public let sourceStart: CMTime
            public let gain: Double
        }

        public let cuts: [Cut]
        public let sounds: [Sound]
        /// What the recording's own sound is doing. Muting it removes tracks from the
        /// mix rather than merely turning them down, so it has to be built again.
        public let recorded: SoundStyle
    }

    /// What the sound of this edit depends on.
    ///
    /// Clip identity is deliberately left out: a command that hands a clip a new `id`
    /// without moving it — and there is no reason for one to — would not be a reason to
    /// decode the recording again.
    public var audioSignature: AudioSignature {
        AudioSignature(
            cuts: clips.map {
                .init(sourceStart: $0.sourceStart, sourceDuration: $0.sourceDuration, speed: $0.speed)
            },
            sounds: audio.map {
                .init(path: $0.path, start: $0.start, duration: $0.duration,
                      sourceStart: $0.sourceStart, gain: $0.gain)
            },
            recorded: sound
        )
    }
}
