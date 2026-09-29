import Foundation

/// The part of `Timeline.AudioSignature` that the voice switches and ducking add.
///
/// Kept apart so the signature's older fields read as they always did. Everything here
/// changes what comes out of the speakers without moving anything on the timeline, which
/// is exactly the kind of change a signature built only from cuts and levels would miss:
/// flip "Clean up voice" and the preview would go on playing the untreated sound.
public struct VoiceSignature: Equatable, Sendable {
    /// One source's switches, by the file it plays, so the legacy recording (sound in
    /// the video) and a separate microphone never compare equal by accident.
    public struct Treatment: Equatable, Sendable {
        public let path: String
        public let cleansVoice: Bool
        public let evensVolume: Bool
    }

    /// One added sound's dip, in the order of `Timeline.audio`.
    public struct Dip: Equatable, Sendable {
        public let ducks: Bool
        public let amount: Double
    }

    public var treatments: [Treatment] = []
    public var dips: [Dip] = []
    /// When somebody speaks according to the captions, while anything ducks. Moving a
    /// caption moves the dips, so it has to rebuild the sound — but only then: with no
    /// ducking, captions have nothing to do with what is heard.
    public var captionSpeech: [ClosedRange<Double>] = []

    public init() {}
}

public extension Timeline {
    var voiceSignature: VoiceSignature {
        var signature = VoiceSignature()
        if hasSeparateSound {
            signature.treatments = soundTracks.map {
                .init(path: $0.path, cleansVoice: $0.style.cleansVoice, evensVolume: $0.style.evensVolume)
            }
        } else {
            signature.treatments = [.init(path: "", cleansVoice: sound.cleansVoice, evensVolume: sound.evensVolume)]
        }
        signature.dips = audio.map { .init(ducks: $0.ducksUnderSpeech, amount: $0.duckAmount) }
        if ducksAnything {
            signature.captionSpeech = speechFromCaptions
        }
        return signature
    }
}
