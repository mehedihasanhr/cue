import AVFoundation
import Foundation
import os
import Speech

/// macOS's own speech recogniser, for a dictated clip: the clip in, its words out as one
/// line of text, on this Mac. Free, nothing to download beyond what macOS fetches for a
/// language itself, and nothing loaded once it has answered.
///
/// The captions use the same two recognisers (see `CaptionGenerator`), but want each word
/// with its moment; dictation wants the sentence, punctuated, so it asks for that instead.
nonisolated enum AppleDictation {
    enum Failure: LocalizedError {
        case notAuthorised
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorised:
                "Cue isn't allowed to recognise speech. Allow it in System Settings › Privacy & Security › Speech Recognition."
            case .unsupported(let language):
                "macOS can't recognise \(language) on this Mac. Choose another language, or use a Whisper model in Settings › Dictation."
            }
        }
    }

    static let log = Logger(subsystem: "com.stackrover.cue", category: "dictation")

    /// The words in the clip at `url`, spoken in `locale`.
    static func text(in url: URL, locale: Locale) async throws -> String {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            return try await modern(url, locale: locale)
        }
        return try await legacy(url, locale: locale)
    }

    private static func name(of locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: macOS 26

    @available(macOS 26, *)
    private static func modern(_ url: URL, locale: Locale) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupported(name(of: locale))
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        // The language's model, fetched by macOS the first time it is used and kept by
        // macOS (not Cue) after that.
        if !(await SpeechTranscriber.installedLocales).contains(where: { $0.identifier == supported.identifier }),
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log.notice("Fetching the speech model for \(supported.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyser = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyser.start(inputAudioFile: file, finishAfterFile: true)
        var parts: [String] = []
        for try await result in transcriber.results where result.isFinal {
            parts.append(String(result.text.characters))
        }
        return tidy(parts.joined(separator: " "))
    }

    // MARK: Before macOS 26

    private static func legacy(_ url: URL, locale: Locale) async throws -> String {
        guard await authorise() else { throw Failure.notAuthorised }
        guard let recogniser = SFSpeechRecognizer(locale: locale), recogniser.supportsOnDeviceRecognition else {
            throw Failure.unsupported(name(of: locale))
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        // On this Mac only, as Cue promises when it asks for the permission.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let text: String = try await withCheckedThrowingContinuation { continuation in
            recogniser.recognitionTask(with: request) { result, error in
                // Read here, inside the callback: the result is not `Sendable`.
                let ended = error != nil || result?.isFinal == true
                let words = result?.bestTranscription.formattedString ?? ""
                let first = resumed.withLock { done -> Bool in
                    guard !done, ended else { return false }
                    done = true
                    return true
                }
                guard first else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: words)
                }
            }
        }
        return tidy(text)
    }

    private static func authorise() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
