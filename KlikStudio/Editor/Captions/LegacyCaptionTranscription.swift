import Foundation
import os
import Speech
import TimelineKit

/// The recogniser every Mac that can run this app has.
///
/// `SFSpeechRecognizer` is the old API and it shows: it is a callback, it reports nothing
/// until it is done, and its on-device support is a yes-or-no per language rather than
/// something you can ask it to fetch. None of that is a reason to drop it — it is the
/// floor. A Mac on macOS 14 gets captions from this and they are the same cues a Mac on
/// macOS 26 gets, only with coarser timings and no progress along the way.
///
/// Left as close to what it was as possible on purpose: this path is the one that cannot
/// be exercised on a new machine, so the less of it that changed, the less of it can have
/// quietly broken.
nonisolated struct LegacyCaptionTranscription: CaptionTranscription {
    typealias Failure = CaptionGenerator.Failure

    func words(in videoURL: URL,
               locale: Locale,
               progress: @escaping CaptionGenerator.ProgressHandler) async throws(Failure) -> [TranscribedWord] {
        guard await Self.authorise() else { throw Failure.notAuthorised }

        let language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let recogniser = SFSpeechRecognizer(locale: locale) else {
            throw Failure.noRecogniser(language)
        }
        guard recogniser.isAvailable else { throw Failure.failed("The recogniser isn't available right now.") }
        guard recogniser.supportsOnDeviceRecognition else {
            throw Failure.unavailableOffline(language)
        }

        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        // Said out loud rather than left to be inferred: this recogniser hands back one
        // final result at the end and nothing before it, so there is no fraction to
        // report and the inspector should keep spinning rather than pretend.
        progress(nil)

        do {
            return try await Self.recognise(request, with: recogniser)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    /// Asks the system, once, whether we may listen to the recording at all.
    static func authorise() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    /// The callback API, awaited once.
    ///
    /// `shouldReportPartialResults` is off, so exactly one final result arrives — but
    /// the continuation is guarded anyway: a recogniser that calls back twice would
    /// otherwise crash the app rather than produce a bad caption.
    private static func recognise(_ request: SFSpeechURLRecognitionRequest,
                                  with recogniser: SFSpeechRecognizer) async throws -> [TranscribedWord] {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            recogniser.recognitionTask(with: request) { result, error in
                let alreadyResumed = resumed.withLock { done -> Bool in
                    if done { return true }
                    if error != nil || result?.isFinal == true { done = true; return false }
                    return true
                }
                guard !alreadyResumed else { return }

                if let error {
                    continuation.resume(throwing: error)
                } else {
                    // Copied to values here, inside the callback, so nothing the
                    // recogniser owns crosses back to the caller —
                    // `SFTranscriptionSegment` is a class and is not `Sendable`.
                    let words = (result?.bestTranscription.segments ?? []).map {
                        TranscribedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    continuation.resume(returning: words)
                }
            }
        }
    }
}
