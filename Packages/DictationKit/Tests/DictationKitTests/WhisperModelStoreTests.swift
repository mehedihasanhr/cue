import Foundation
import Testing
@testable import DictationKit

/// Installing, updating and removing models, with a stand-in for the repository.
struct WhisperModelStoreTests {
    private let model = WhisperModel.all[0]

    /// A store in a fresh folder, whose "repository" writes `content` and reports `fingerprint`.
    private func store(fingerprint: String = "one", content: String = "weights",
                       failVerify: Bool = false) -> (WhisperModelStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "WhisperStoreTests-\(UUID().uuidString)")
        let source = WhisperModelStore.Source(
            download: { model, base, progress in
                let folder = base.appending(path: "models/\(WhisperModel.repository)/\(model.id)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(content.utf8).write(to: folder.appending(path: "weights.bin"))
                // The tokenizer and cache land beside it, as WhisperKit's downloader puts them.
                let tokenizer = base.appending(path: "models/openai/whisper-tiny")
                try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))
                progress(1)
                return folder
            },
            remote: { _ in WhisperModelStore.RemoteInfo(fingerprint: fingerprint, bytes: 1_000) },
            verify: { _, _ in if failVerify { throw CocoaError(.fileReadCorruptFile) } }
        )
        return (WhisperModelStore(root: root, source: source), root)
    }

    private func entries(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []).sorted()
    }

    private func weights(_ store: WhisperModelStore) throws -> String {
        let folder = try #require(store.modelFolder(for: model))
        return try String(contentsOf: folder.appending(path: "weights.bin"), encoding: .utf8)
    }

    @Test func installPutsEverythingInTheModelsFolder() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.installation(of: model) == nil)

        let installation = try await store.install(model)
        #expect(installation.fingerprint == "one")
        #expect(installation.bytes > 0)
        #expect(store.installation(of: model) == installation)
        #expect(try weights(store) == "weights")
        #expect(entries(root) == [model.id])
    }

    @Test func anUpdateReplacesTheOldFilesAndLeavesNothingBehind() async throws {
        let (first, root) = store(fingerprint: "one", content: "old")
        defer { try? FileManager.default.removeItem(at: root) }
        try await first.install(model)

        let second = WhisperModelStore(root: root, source: store(fingerprint: "two", content: "new").0.sourceForTests)
        #expect(try await second.updateAvailable(for: model))
        try await second.install(model)

        #expect(second.installation(of: model)?.fingerprint == "two")
        #expect(try weights(second) == "new")
        #expect(entries(root) == [model.id])
        #expect(try await !second.updateAvailable(for: model))
    }

    @Test func aFailedUpdateKeepsTheInstalledModel() async throws {
        let (first, root) = store(fingerprint: "one", content: "old")
        defer { try? FileManager.default.removeItem(at: root) }
        try await first.install(model)

        let broken = WhisperModelStore(root: root, source: store(fingerprint: "two", content: "new", failVerify: true).0.sourceForTests)
        await #expect(throws: (any Error).self) { try await broken.install(model) }

        #expect(broken.installation(of: model)?.fingerprint == "one")
        #expect(try weights(broken) == "old")
        #expect(entries(root) == [model.id])
    }

    @Test func removeDeletesTheModelCompletely() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.install(model)
        // A download Cue quit in the middle of.
        try FileManager.default.createDirectory(at: root.appending(path: ".staging-\(model.id)-X"), withIntermediateDirectories: true)

        try store.remove(model)
        #expect(store.installation(of: model) == nil)
        #expect(entries(root).isEmpty)
        #expect(store.totalBytes == 0)
    }

    @Test func leftoversAreClearedAtLaunch() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.install(model)
        for name in [".staging-a-1", ".old-b-2"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        store.cleanUpLeftovers()
        #expect(entries(root) == [model.id])
    }

    @Test func theFingerprintFollowsEveryFile() {
        let a = HubFingerprint.fingerprint(of: [("b", "2"), ("a", "1")])
        #expect(a == HubFingerprint.fingerprint(of: [("a", "1"), ("b", "2")]))
        #expect(a != HubFingerprint.fingerprint(of: [("a", "1"), ("b", "3")]))
        #expect(a != HubFingerprint.fingerprint(of: [("a", "1")]))
    }

    @Test func whisperMarkersAreTakenOut() {
        #expect(WhisperTranscriber.clean(" [BLANK_AUDIO]  Hello  (music) world ") == "Hello world")
    }
}
