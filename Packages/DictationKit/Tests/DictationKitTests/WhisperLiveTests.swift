import Foundation
import Testing
@testable import DictationKit

/// The real thing, end to end: download the Tiny model from Hugging Face, hear a spoken
/// sentence, check for an update, remove it. Off unless asked for, because it needs the
/// network and takes a minute: `DICTATIONKIT_LIVE=1 swift test --filter WhisperLiveTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DICTATIONKIT_LIVE"] != nil))
struct WhisperLiveTests {
    @Test func downloadHearUpdateAndRemove() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WhisperLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root)
        let model = try #require(WhisperModel.named("openai_whisper-tiny"))

        let remote = try await store.remoteInfo(of: model)
        #expect(remote.bytes > 50_000_000)
        let installation = try await store.install(model)
        #expect(installation.bytes > 50_000_000)
        #expect(try await !store.updateAvailable(for: model))

        // A sentence spoken by the system voice.
        let speech = root.appending(path: "speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", speech.path(percentEncoded: false), "The quick brown fox jumps over the lazy dog."]
        try say.run()
        say.waitUntilExit()

        let transcriber = WhisperTranscriber(store: store)
        let text = try await transcriber.transcribe(fileAt: speech, with: model, language: "en")
        #expect(text.lowercased().contains("fox"))
        await transcriber.unload()

        // An update over the top leaves one copy.
        try await store.install(model)
        try store.remove(model)
        #expect(store.installation(of: model) == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []).filter { $0 != "speech.aiff" }.isEmpty)
    }
}
