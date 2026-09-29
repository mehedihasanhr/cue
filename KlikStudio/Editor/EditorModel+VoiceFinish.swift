import Foundation
import RenderKit
import TimelineKit

/// "Clean up voice", "Even out volume" and "Lower under speech": the edits, and the
/// questions the panels and the Audio menu ask about them.
///
/// Every switch is a document edit through `apply`, so each is one undo and each changes
/// the sound's signature — which is what sends the preview off to rebuild the mix. The
/// work itself happens in RenderKit's mixdown, the same for the preview and the export.
extension EditorModel {
    // MARK: - Which source

    /// The source the Audio menu's voice switches act on: the one selected on the
    /// timeline, else the voice, else — for a recording with its sound inside the video —
    /// `nil`, meaning the recording as a whole.
    var voiceSwitchTarget: SoundTrack? {
        if case .soundTrack(let id) = selection, let track = timeline.soundTrack(id) { return track }
        return timeline.soundTrackForSpeech
    }

    /// The switches of a source, or of the whole recording's sound when `id` is `nil`.
    func voiceStyle(_ id: UUID?) -> SoundStyle {
        guard let id else { return timeline.sound }
        return timeline.soundTrack(id)?.style ?? SoundStyle()
    }

    private func restyleVoice(_ id: UUID?, _ name: String,
                              _ change: @escaping @Sendable (inout SoundStyle) -> Void) {
        if let id {
            apply(Commands.RestyleSoundTrack(id: id, name: name) { change(&$0.style) })
        } else {
            apply(Commands.Restyle(name) { change(&$0.sound) })
        }
    }

    func setCleansVoice(_ on: Bool, for id: UUID?) {
        guard voiceStyle(id).cleansVoice != on else { return }
        restyleVoice(id, on ? "Clean Up Voice" : "Stop Cleaning Up Voice") { $0.cleansVoice = on }
    }

    func setEvensVolume(_ on: Bool, for id: UUID?) {
        guard voiceStyle(id).evensVolume != on else { return }
        restyleVoice(id, on ? "Even Out Volume" : "Stop Evening Out Volume") { $0.evensVolume = on }
    }

    // MARK: - The Audio menu

    /// Whether the voice switches have anything to act on: a source, or a recording
    /// with sound in its video.
    var canTreatVoice: Bool {
        timeline.hasSeparateSound || waveform.state != .unavailable
    }

    var menuCleansVoice: Bool { voiceStyle(voiceSwitchTarget?.id).cleansVoice }
    var menuEvensVolume: Bool { voiceStyle(voiceSwitchTarget?.id).evensVolume }

    func setMenuCleansVoice(_ on: Bool) { setCleansVoice(on, for: voiceSwitchTarget?.id) }
    func setMenuEvensVolume(_ on: Bool) { setEvensVolume(on, for: voiceSwitchTarget?.id) }

    /// The added sounds "Lower Music Under Speech" acts on: the selected one, or all.
    private var duckingTargets: [UUID] {
        if case .audio(let id) = selection, timeline.audio.contains(where: { $0.id == id }) { return [id] }
        return timeline.audio.map(\.id)
    }

    var menuDucksMusic: Bool {
        let targets = Set(duckingTargets)
        let chosen = timeline.audio.filter { targets.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy(\.ducksUnderSpeech)
    }

    func setMenuDucksMusic(_ on: Bool) {
        let targets = Set(duckingTargets)
        guard !targets.isEmpty else { return }
        apply(Commands.Restyle(on ? "Lower Under Speech" : "Stop Lowering Under Speech") { timeline in
            for index in timeline.audio.indices where targets.contains(timeline.audio[index].id) {
                timeline.audio[index].ducksUnderSpeech = on
            }
        })
    }

    // MARK: - An added sound

    func setDucksUnderSpeech(_ on: Bool, for id: UUID) {
        guard let region = timeline.audio.first(where: { $0.id == id }), region.ducksUnderSpeech != on else { return }
        apply(Commands.Restyle(on ? "Lower Under Speech" : "Stop Lowering Under Speech") { timeline in
            guard let index = timeline.audio.firstIndex(where: { $0.id == id }) else { return }
            timeline.audio[index].ducksUnderSpeech = on
        })
    }

    func setDuckAmount(_ decibels: Double, for id: UUID) {
        apply(Commands.Restyle("Lower By") { timeline in
            guard let index = timeline.audio.firstIndex(where: { $0.id == id }) else { return }
            timeline.audio[index].duckAmount = decibels
        })
    }

    /// Where the music learns that somebody is speaking, said plainly — or why it cannot.
    var duckingSource: (available: Bool, explanation: String) {
        if !timeline.speechFromCaptions.isEmpty {
            return (true, "Goes down wherever the captions have words.")
        }
        if timeline.hasSeparateSound {
            if let voice = timeline.duckingVoice {
                return (true, "Goes down wherever \(voice.name) is speaking. Captions, once made, are used instead.")
            }
            return (false, "Nobody to listen to: the voice is muted and there are no captions.")
        }
        if timeline.sound.isAudible, waveform.state != .unavailable {
            return (true, "Goes down wherever the recording has a voice in it. Captions, once made, are used instead.")
        }
        return (false, "Nobody to listen to: the recording has no sound and there are no captions.")
    }

    // MARK: - Measuring

    /// The file a source's levels are measured from, and which of its audio tracks.
    /// The recording as a whole is its first track: the same one "Even out volume"
    /// reports for a recording with its sound inside the video.
    func measuredFile(for id: UUID?) -> (url: URL, track: Int)? {
        if let id {
            guard let track = timeline.soundTrack(id) else { return nil }
            return (packageURL.appendingPathComponent(track.path), 0)
        }
        guard let url = document.videoURL else { return nil }
        return (url, 0)
    }
}
