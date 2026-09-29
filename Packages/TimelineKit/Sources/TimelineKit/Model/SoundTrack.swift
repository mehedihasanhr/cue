import CoreMedia
import Foundation
import RecordKit

/// One of the recording's own sounds: the screen, or a microphone.
///
/// A take used to have exactly one sound — whatever was in the recording's file — and one
/// `SoundStyle` governing it. That was never really true: a screen recording with a
/// voiceover has *two* sounds in it, and the first thing anybody wants to do with them is
/// the one thing a single style cannot express — turn the music on the screen down and
/// leave the voice where it is. Muting "the recording" muted the voice too, so the only
/// way out was to mute everything and import the voice again as a file.
///
/// So the recording's sound is a list of sources, each with its own name, its own file and
/// its own level. On disk that separation is literal: the recorder writes one audio file
/// per source, and this points at it. That is what makes the lanes honest — muting a lane
/// here removes exactly that file from the mix, and nothing else is touched.
///
/// What is deliberately *not* here: where the sound sits in time. Every source of one take
/// was captured at one moment on one clock, so they are cut together — the picture's cuts,
/// or `Timeline.detachedSound` once the sound has been cut loose from the picture. A lane
/// that could be slid on its own would be a lane that could be slid out of sync with the
/// face that is speaking, by accident, with no way to see that it had happened.
public struct SoundTrack: Identifiable, Codable, Equatable, Sendable {
    /// Where this sound came from. Used for an icon, for the default name, and for
    /// choosing which lane to transcribe — never for finding a file, which is `path`'s job.
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// Everything the Mac was playing: the browser, the app being demonstrated.
        case systemAudio
        /// One microphone — built in, USB, a headset, an interface.
        case microphone

        public var symbol: String {
            switch self {
            case .systemAudio: "speaker.wave.2"
            case .microphone: "mic"
            }
        }

        public var defaultName: String {
            switch self {
            case .systemAudio: "System Audio"
            case .microphone: "Microphone"
            }
        }
    }

    public let id: UUID
    public var source: Source
    /// What the lane is called: the device's own name for a microphone, so two voices on
    /// two microphones are told apart by the thing the user recognises.
    public var name: String
    /// The audio file, relative to the project package — exactly as the recording's
    /// manifest named it, so a project stays portable.
    public var path: String
    /// The capture device this came from, when it came from one. Two microphones of the
    /// same model carry the same name and different ids.
    public var deviceID: String?
    /// This source's own level and mute. Multiplied by `Timeline.sound`, which stays the
    /// master for the recording's sound as a whole.
    public var style: SoundStyle

    public init(id: UUID = UUID(),
                source: Source,
                name: String? = nil,
                path: String,
                deviceID: String? = nil,
                style: SoundStyle = SoundStyle()) {
        self.id = id
        self.source = source
        self.name = name ?? source.defaultName
        self.path = path
        self.deviceID = deviceID
        self.style = style
    }

    /// Decoded field by field for the reason `Timeline.init(from:)` gives: a lane missing
    /// its name is a lane called "Microphone", not a project that will not open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        source = value(.source, default: Source.microphone)
        path = value(.path, default: "")
        name = value(.name, default: source.defaultName)
        deviceID = ((try? container.decodeIfPresent(String.self, forKey: .deviceID)) ?? nil)
        style = value(.style, default: SoundStyle())
    }

    enum CodingKeys: String, CodingKey {
        case id, source, name, path, deviceID, style
    }

    public var symbol: String { source.symbol }
}

public extension Timeline {
    /// Whether this project knows its sound source by source.
    ///
    /// `false` for everything recorded before the recorder separated them, and those
    /// projects are not broken — their sound is whatever is inside the recording's own
    /// file, governed by `sound`, exactly as it always was. Every reader of the sound has
    /// to handle both, and this is the one question that decides which.
    var hasSeparateSound: Bool { !soundTracks.isEmpty }

    /// What one source is actually heard at: its own level under the master.
    ///
    /// One reading rather than two that can disagree — the preview, the exporter and the
    /// lane's own dimming all ask this, and a lane drawn as audible over a mix that
    /// silenced it is the kind of bug nobody reports because they assume they did it.
    func level(of track: SoundTrack) -> Double {
        sound.level * track.style.level
    }

    func isAudible(_ track: SoundTrack) -> Bool { level(of: track) > 0 }

    func soundTrack(_ id: UUID) -> SoundTrack? { soundTracks.first { $0.id == id } }

    /// The lane worth running speech recognition over: a voice if there is one, otherwise
    /// whatever sound there is.
    ///
    /// Captions used to be made from the recording's whole soundtrack, which meant
    /// transcribing a voice over the top of whatever the browser was playing. A microphone
    /// on its own file transcribes far better, and this is the only place that has to know
    /// to prefer it.
    var soundTrackForSpeech: SoundTrack? {
        soundTracks.first { $0.source == .microphone && isAudible($0) }
            ?? soundTracks.first { $0.source == .microphone }
            ?? soundTracks.first
    }
}

public extension Timeline {
    /// Fills in the recording's sound sources from its manifest.
    ///
    /// Run when a project is opened rather than stored by the recorder, because the
    /// manifest is the recording's account of itself and the timeline is the *edit's* — the
    /// edit needs a level and a mute per source, which the recorder has no opinion about.
    /// Once a project has been saved the lanes are its own and this leaves them alone, so a
    /// level set last week is not quietly reset by reopening.
    ///
    /// Only sources that are their own file are adopted. A recording made before the
    /// sources were separated names its audio tracks too — both pointing at `screen.mov`,
    /// because that is where they were — and adopting those would make two lanes that are
    /// the same single track read twice, played twice and exported twice.
    mutating func adoptSoundTracks(from manifest: RecordingManifest) {
        guard soundTracks.isEmpty else { return }
        let picture = manifest.track(.screen)?.path
        soundTracks = manifest.audioTracks.compactMap { track in
            guard track.path != picture else { return nil }
            return SoundTrack(source: track.kind == .systemAudio ? .systemAudio : .microphone,
                              name: track.name,
                              path: track.path,
                              deviceID: track.deviceID)
        }
    }

    /// Switches the voice treatments on for every microphone, as a new recording's
    /// starting point.
    ///
    /// Microphones only: "clean up voice" run over a browser tab's music takes the music's
    /// quiet passages out as if they were hiss, and "even out volume" on system audio
    /// levels whatever the demo happened to play. Only ever switches *on* — a default that
    /// is off leaves the lane as the recorder made it, rather than asserting "off" over a
    /// project that may already have been given a treatment some other way. A recording
    /// whose sound is inside the video has no microphone lanes and is left alone.
    mutating func treatVoices(cleansVoice: Bool, evensVolume: Bool) {
        for index in soundTracks.indices where soundTracks[index].source == .microphone {
            if cleansVoice { soundTracks[index].style.cleansVoice = true }
            if evensVolume { soundTracks[index].style.evensVolume = true }
        }
    }
}
