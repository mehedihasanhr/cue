import AVFoundation
import CoreMedia
import Foundation
import os
import Speech
import TimelineKit

/// The recogniser macOS 26 brought, which is the one built for this job.
///
/// `SpeechAnalyzer` differs from `SFSpeechURLRecognitionRequest` in the ways that matter
/// to an editor rather than to a dictation field: it is meant for long-form audio, it
/// streams results as it goes instead of one lump at the end, and every run of its text
/// carries the range of audio it came from, which is what makes a caption land on the word
/// rather than near it. It also owns its language models explicitly, so "the model isn't
/// here yet" is a state you can see and fix rather than a silent refusal.
///
/// No speech-recognition permission is asked for here, and that is deliberate rather than
/// forgotten. This API transcribes a local file with a local model; there is no
/// recognition service acting on the user's behalf and therefore no authorisation to hold.
/// If a future macOS decides otherwise, its error comes back through `.failed` with the
/// system's own words in it, which is a bad outcome that at least says what happened.
@available(macOS 26, *)
nonisolated struct ModernCaptionTranscription: CaptionTranscription {
    typealias Failure = CaptionGenerator.Failure

    /// Whether the machine has the framework's models at all — Apple's own gate, and the
    /// reason the seam asks more than just the OS version.
    static var isUsable: Bool { SpeechTranscriber.isAvailable }

    func words(in videoURL: URL,
               locale: Locale,
               progress: @escaping CaptionGenerator.ProgressHandler) async throws(Failure) -> [TranscribedWord] {
        do {
            return try await transcribe(videoURL, locale: locale, progress: progress)
        } catch let failure as Failure {
            throw failure
        } catch {
            // Everything AVFoundation and Speech can go wrong with lands here, with the
            // system's description kept: a wrong guess dressed up as a friendly sentence
            // is worse than an unfriendly true one.
            CaptionGenerator.log.error("Modern transcription failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.failed(error.localizedDescription)
        }
    }

    private func transcribe(_ videoURL: URL,
                            locale: Locale,
                            progress: @escaping CaptionGenerator.ProgressHandler) async throws -> [TranscribedWord] {
        let language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        // The framework has its own idea of which locales are equivalent — asking it is how
        // `en_GB` ends up transcribed by the `en-GB` model rather than refused.
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.noRecogniser(language)
        }

        // `.audioTimeRange` is the reason for using this API at all: without it the result
        // is a wall of text with one range around the whole of it, and captions cannot be
        // cut from that. No volatile results are asked for — a transcript that rewrites
        // itself is useful for a live caption and useless for an undo stack.
        let transcriber = SpeechTranscriber(locale: supported,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        try await install(transcriber, for: supported, language: language, progress: progress)

        // Verified: `AVAudioFile` opens a QuickTime movie and decodes its first audio
        // track, so the recording is read where it lies rather than copied out first.
        let file = try AVAudioFile(forReading: videoURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate

        let analyser = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .utility,
                                                                      modelRetention: .whileInUse))
        // `finishAfterFile` is what ends the results sequence when the recording does.
        // Without it the loop below would sit waiting for audio that is never coming,
        // which is the one failure mode a progress spinner cannot tell you about.
        try await analyser.start(inputAudioFile: file, finishAfterFile: true)

        var words: [TranscribedWord] = []
        var reported: Double = 0
        do {
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                words.append(contentsOf: Self.words(in: result))

                // Honest, and monotonic: how much of the recording has been listened to,
                // never running backwards even if a late result finalises an earlier range.
                if duration > 0 {
                    reported = max(reported, min(1, result.range.end.seconds / duration))
                    progress(reported)
                }
            }
        } catch {
            // Whatever was recognised before the failure is still true. Throwing it away
            // to show an error would be the worse of the two answers for a long recording.
            guard words.isEmpty else {
                CaptionGenerator.log.error("Transcription stopped early, keeping \(words.count) words: \(error.localizedDescription, privacy: .public)")
                return words
            }
            throw error
        }
        return words
    }

    /// The words inside one result, with the moments they were said.
    ///
    /// The text is an `AttributedString` whose runs are the recogniser's own units — a word
    /// or a short phrase — each tagged with the audio it came from. Runs without a range
    /// are skipped rather than guessed at; a caption in the wrong place is worse than a
    /// caption that is missing.
    private static func words(in result: SpeechTranscriber.Result) -> [TranscribedWord] {
        result.text.runs.compactMap { run in
            guard let range = run.audioTimeRange, range.duration > .zero else { return nil }
            let text = String(result.text[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscribedWord(text: text, start: range.start, duration: range.duration)
        }
    }

    /// Makes sure the language model is actually on the machine, before a sample is read.
    ///
    /// This is the case the old API could only refuse: the framework knows the language,
    /// will happily be handed audio, and the model is a download away. Handled here and
    /// explicitly, because the alternative is a job that never visibly finishes.
    ///
    /// `installedLocales` is asked rather than `AssetInventory.status(forModules:)`, which
    /// on a cold start was observed answering `.supported` for a locale that was in fact
    /// installed — a wrong answer that would send us downloading something already here.
    /// And a nil installation request means the framework has nothing it wants fetched, not
    /// that it has refused: going on is right, because the analysis itself is the honest
    /// test of whether the model is there, and failing at this point would fail on machines
    /// that work.
    private func install(_ transcriber: SpeechTranscriber,
                         for locale: Locale,
                         language: String,
                         progress: @escaping CaptionGenerator.ProgressHandler) async throws {
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier == locale.identifier }) else { return }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            CaptionGenerator.log.notice("No install offered for \(language, privacy: .public); analysing anyway")
            return
        }
        // A download's length has nothing to do with the recording's, so the fraction goes
        // back to "unknown" for the duration rather than being blended into the analysis
        // progress that follows it.
        progress(nil)
        CaptionGenerator.log.notice("Fetching the \(language, privacy: .public) speech model")
        do {
            try await request.downloadAndInstall()
        } catch {
            CaptionGenerator.log.error("Couldn't install the speech model: \(error.localizedDescription, privacy: .public)")
            throw Failure.modelNotInstalled(language)
        }
    }
}
