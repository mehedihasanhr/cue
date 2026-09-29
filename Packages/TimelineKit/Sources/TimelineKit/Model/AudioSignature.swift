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
            /// How long the clip is silent for, when it is a freeze frame or a title. The
            /// three above are the same for every hold, so without this a two-second
            /// still made five would not rebuild the sound, and everything after it would
            /// be heard three seconds early.
            public let hold: CMTime?
            /// How the clip arrives, as far as the sound is concerned: a dip fades the
            /// sound with the picture, and a crossfade blends it.
            public let transition: ClipTransition?
            /// Which file the clip plays. Two clips at the same times of different files
            /// are two different sounds.
            public let source: String?

            init(_ clip: Clip) {
                sourceStart = clip.sourceStart
                sourceDuration = clip.sourceDuration
                speed = clip.speed
                hold = clip.hold
                transition = clip.transition
                source = clip.source
            }
        }

        /// One run of a *detached* sound lane: the recording's own sound, laid where the
        /// lane says rather than where the picture says.
        public struct Run: Equatable, Sendable {
            public let start: CMTime
            public let duration: CMTime
            public let sourceStart: CMTime
            public let speed: Double
        }

        /// A sound from outside the recording.
        public struct Sound: Equatable, Sendable {
            public let path: String
            public let start: CMTime
            public let duration: CMTime
            public let sourceStart: CMTime
            public let gain: Double
            public let fadeIn: Double
            public let fadeOut: Double
        }

        /// Empty once the lane is detached, and that emptiness is doing work: the
        /// picture's cuts then say nothing about the sound, so moving one must *not* send
        /// the editor off to decode the recording again.
        public let cuts: [Cut]
        /// `nil` while the sound follows the picture. Present or absent is itself audible —
        /// detaching changes which branch of the mixdown runs — so the two states can never
        /// compare equal, which is what keeps the preview from going on playing the old
        /// edit after a detach.
        public let runs: [Run]?
        public let sounds: [Sound]
        /// One of the recording's own sources, as the mixdown will open it.
        ///
        /// The level is the *resolved* one — this source's own, under the master — so a
        /// change to either is a change here. The path is what tells two sources apart:
        /// a mix built from the microphone's file is not the mix built from the screen's,
        /// however identical the numbers beside it look.
        public struct Source: Equatable, Sendable {
            public let path: String
            public let level: Double
        }

        /// What the recording's own sound is doing. Muting it removes tracks from the
        /// mix rather than merely turning them down, so it has to be built again.
        public let recorded: SoundStyle
        /// The sources, in order. Empty for a recording whose sound lives in its video
        /// file, which is a different mix from one with no audible sources — hence the
        /// paths, which are never empty when there is something to hear.
        public let sources: [Source]

        /// What the click sounds depend on, or `nil` when there are none.
        ///
        /// Clicks follow the picture rather than the sound lane, so the picture's cuts
        /// are here even when `cuts` is empty because the sound has been detached. And a
        /// stretch that hides the pointer silences the clicks inside it, so those are here
        /// too.
        public struct Clicks: Equatable, Sendable {
            public let kind: CursorStyle.ClickSound
            public let volume: Double
            public let picture: [Cut]
            public let hiding: [CursorRegion]
            /// Clicks outside the crop are not heard — see `visibleClicks` — so cropping
            /// changes which ones are.
            public let crop: CGRect?
        }

        public let clicks: Clicks?

        /// The voice switches and the music's dips under speech. See `VoiceSignature`.
        public var voice: VoiceSignature = VoiceSignature()
        /// The imported clips, which lay their own sound down whether or not the
        /// recording's lane is detached — so they are here in both states, where `cuts`
        /// is empty once the lane is detached.
        public var imported: [Cut] = []
    }

    /// What the sound of this edit depends on.
    ///
    /// Clip identity is deliberately left out: a command that hands a clip a new `id`
    /// without moving it — and there is no reason for one to — would not be a reason to
    /// decode the recording again.
    public var audioSignature: AudioSignature {
        AudioSignature(
            cuts: detachedSound == nil ? clips.map(AudioSignature.Cut.init) : [],
            runs: detachedSound.map { runs in
                runs.map {
                    .init(start: $0.start, duration: $0.duration,
                          sourceStart: $0.sourceStart, speed: $0.speed)
                }
            },
            sounds: audio.map {
                .init(path: $0.path, start: $0.start, duration: $0.duration,
                      sourceStart: $0.sourceStart, gain: $0.gain,
                      fadeIn: $0.heardFades.fadeIn, fadeOut: $0.heardFades.fadeOut)
            },
            recorded: sound,
            sources: soundTracks.map { .init(path: $0.path, level: level(of: $0)) },
            clicks: cursor.isVisible && cursor.clickSound
                ? .init(kind: cursor.clickSoundKind,
                        volume: cursor.clickSoundVolume,
                        picture: clips.map(AudioSignature.Cut.init),
                        hiding: cursorRegions,
                        crop: style.crop?.rect)
                : nil,
            voice: voiceSignature,
            imported: clips.contains(where: \.isImported) ? clips.map(AudioSignature.Cut.init) : []
        )
    }
}
