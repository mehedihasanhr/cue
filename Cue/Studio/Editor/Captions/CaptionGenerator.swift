import AVFoundation
import CoreMedia
import Foundation
import os
import TimelineKit

/// Turns the recorded speech into lines of text on the timeline.
///
/// On-device recognition, insisted on rather than merely preferred: a screen recording
/// is very often of something not meant to leave the machine, and quietly uploading its
/// audio to a server to save a second of processing is not a trade this app gets to make
/// on someone's behalf. Where a language has no on-device model the answer is to say so,
/// not to fall back to the network.
///
/// Times come back in the *recording's* clock and are mapped onto the edit before they
/// become cues, so captions still line up after a trim, a reorder or a speed change.
///
/// There are two recognisers behind this, because macOS grew a much better one after the
/// app's deployment target was set. `SpeechAnalyzer` is built for exactly this job —
/// long-form, from a file, on device, with real word timings — and it arrived in macOS 26;
/// `SFSpeechRecognizer` is what every Mac running macOS 14 has. So this is not a
/// replacement but an upgrade with a floor under it, and the version check lives here, in
/// `engine`, and nowhere else. That is the point of the seam: `EditorModel` asks for cues
/// and gets cues, and neither it nor the inspector has any idea which recogniser produced
/// them. Both engines hand back `TranscribedWord`s and both are shaped into cues by the
/// same `CaptionShaper`, which is what makes "the cues are the contract" true rather than
/// aspirational.
nonisolated enum CaptionGenerator {
    enum Failure: Error, Equatable {
        case notAuthorised
        case noRecogniser(String)
        case unavailableOffline(String)
        case modelNotInstalled(String)
        case noAudio
        case noSpeechFound
        case failed(String)

        var message: String {
            switch self {
            case .notAuthorised:
                "Cue needs permission to use speech recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            case .noRecogniser(let language):
                "macOS has no speech recogniser for \(language)."
            case .unavailableOffline(let language):
                "The \(language) speech model isn't on this Mac yet. Add the language in System Settings › General › Language & Region, then try again."
            case .modelNotInstalled(let language):
                "The \(language) speech model isn't installed yet, and downloading it didn't work. Check your connection, or add the language in System Settings › General › Language & Region, then try again."
            case .noAudio:
                "This recording has no sound, so there is nothing to write down."
            case .noSpeechFound:
                "No speech was found in this recording."
            case .failed(let detail):
                "Captions couldn't be generated. \(detail)"
            }
        }
    }

    /// How far along, when the engine can honestly say — and `nil` when it cannot.
    ///
    /// Same shape as `WaveformStore`'s: a plain closure the caller hops to the main actor
    /// itself. `nil` rather than a made-up number is the whole point: the older recogniser
    /// reports nothing at all until it is finished, and a bar creeping along on a guess is
    /// a lie told sixty times a second.
    typealias ProgressHandler = @Sendable (Double?) -> Void

    /// Recognises the speech in a recording and returns it as cues on `timeline`.
    static func cues(for videoURL: URL,
                     timeline: Timeline,
                     locale: Locale = .current,
                     progress: @escaping ProgressHandler = { _ in }) async throws(Failure) -> [CaptionCue] {
        // Asked before any recogniser is started, because "there is no sound in this
        // recording" is a true and useful thing to say, and both engines would otherwise
        // spend a while finding no speech in silence and then blame the speech.
        guard try await hasAudio(videoURL) else { throw Failure.noAudio }

        let words = try await engine.words(in: videoURL, locale: locale, progress: progress)
        guard !words.isEmpty else { throw Failure.noSpeechFound }

        let cues = CaptionShaper.cues(from: words, on: timeline)
        guard !cues.isEmpty else { throw Failure.noSpeechFound }
        log.notice("Recognised \(words.count) words as \(cues.count) captions")
        return cues
    }

    /// The one version check in the feature.
    ///
    /// `isUsable` is asked as well as the OS version because a Mac can be new enough for
    /// the API and still not have the speech models it needs — in which case the older
    /// recogniser, which the system has always had, is a better answer than a failure.
    private static var engine: any CaptionTranscription {
        if #available(macOS 26, *), ModernCaptionTranscription.isUsable {
            ModernCaptionTranscription()
        } else {
            LegacyCaptionTranscription()
        }
    }

    /// Whether there is anything to listen to.
    private static func hasAudio(_ videoURL: URL) async throws(Failure) -> Bool {
        do {
            let asset = AVURLAsset(url: videoURL)
            return try await !asset.loadTracks(withMediaType: .audio).isEmpty
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    static let log = Logger(subsystem: "com.stackrover.cue", category: "captions")
}

/// One recogniser, reduced to the only question worth asking it.
///
/// Deliberately about words and not about cues: shaping words into readable lines is a
/// judgement that should not differ between a new Mac and an old one, so it sits on the
/// other side of this seam, in `CaptionShaper`, and an engine cannot get it wrong. What an
/// engine *does* own is everything that genuinely differs — which permission to ask for,
/// which model to install, and how to describe its own failures.
protocol CaptionTranscription: Sendable {
    func words(in videoURL: URL,
               locale: Locale,
               progress: @escaping CaptionGenerator.ProgressHandler) async throws(CaptionGenerator.Failure) -> [TranscribedWord]
}
