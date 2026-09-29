import Foundation
import Testing
@testable import TimelineKit

/// The folder of look files: naming, listing, renaming, deleting, importing — all in a
/// temporary folder, never the real one.
struct LookStoreTests {
    private func makeFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KlikStudioLooks-\(UUID().uuidString)", isDirectory: true)
    }

    private func look(_ name: String, padding: Double = 0.1) -> Look {
        var look = Look(name: name)
        look.frame.padding = padding
        return look
    }

    @Test func aSavedLookIsListedByNameAndReadBackWhole() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LookStore(folder: folder, reservedNames: [])

        #expect(store.list().isEmpty, "a folder that does not exist yet is simply empty")
        let saved = try store.save(look("Zebra", padding: 0.2))
        try store.save(look("apple", padding: 0.3))
        #expect(saved.url.pathExtension == Look.fileExtension)
        #expect(saved.url.lastPathComponent == "Zebra.klikstyle")

        let listed = store.list()
        #expect(listed.map(\.name) == ["apple", "Zebra"], "sorted the way the Finder sorts")
        #expect(listed[1].look.frame.padding == 0.2)
        #expect(listed[0].look == look("apple", padding: 0.3))
    }

    @Test func aNameHasToBeSomethingAndHasToBeFree() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LookStore(folder: folder, reservedNames: ["Studio"])

        #expect(throws: LookStore.Failure.emptyName) { try store.save(look("   ")) }
        #expect(throws: LookStore.Failure.reservedName("studio")) { try store.save(look("studio")) }
        try store.save(look("Mine"))
        #expect(throws: LookStore.Failure.nameTaken("MINE")) { try store.save(look("MINE")) }
        #expect(store.isTaken("mine"))
        #expect(store.isTaken("Studio"))
        #expect(!store.isTaken("Yours"))
        #expect(LookStore.Failure.nameTaken("X").errorDescription?.contains("X") == true)
    }

    @Test func theNameIsTrimmedAndTheFileNameIsSafe() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LookStore(folder: folder, reservedNames: [])

        let saved = try store.save(look("  16:9 / Dark  "))
        #expect(saved.name == "16:9 / Dark")
        #expect(saved.url.lastPathComponent == "16-9 - Dark.klikstyle")
        #expect(store.list().first?.name == "16:9 / Dark", "the pretty name inside the file wins while it agrees with the file")
        #expect(LookStore.fileName(for: "///") == "---")
        #expect(LookStore.fileName(for: "   ") == "Look")
        #expect(LookStore.fileName(for: "..") == "Look")
    }

    @Test func aFileRenamedInTheFinderTakesItsNewName() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LookStore(folder: folder, reservedNames: [])

        let saved = try store.save(look("Before"))
        let moved = folder.appendingPathComponent("After.klikstyle")
        try FileManager.default.moveItem(at: saved.url, to: moved)
        #expect(store.list().map(\.name) == ["After"])
    }

    @Test func renamingMovesTheFileAndKeepsWhatItDoesNotUnderstand() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LookStore(folder: folder, reservedNames: ["Studio"])

        try store.save(look("Other"))
        let saved = try store.save(look("First"))
        // A field from a newer build, planted in the file by hand.
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: saved.url)) as? [String: Any])
        object["hologram"] = ["depth": 3]
        try JSONSerialization.data(withJSONObject: object).write(to: saved.url)

        let renamed = try store.rename(saved, to: "Second")
        #expect(renamed.name == "Second")
        #expect(renamed.url.lastPathComponent == "Second.klikstyle")
        #expect(!FileManager.default.fileExists(atPath: saved.url.path(percentEncoded: false)))
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: renamed.url)) as? [String: Any])
        #expect(after["name"] as? String == "Second")
        #expect((after["hologram"] as? [String: Any])?["depth"] as? Int == 3)
        #expect(store.list().map(\.name) == ["Other", "Second"])

        #expect(throws: LookStore.Failure.nameTaken("other")) { try store.rename(renamed, to: "other") }
        #expect(throws: LookStore.Failure.reservedName("Studio")) { try store.rename(renamed, to: "Studio") }
        #expect(throws: LookStore.Failure.emptyName) { try store.rename(renamed, to: "") }
        // Renaming to its own name, differently spaced, is allowed: it is not taken by anybody else.
        let same = try store.rename(renamed, to: " Second ")
        #expect(same.url == renamed.url)
        // And so is fixing its capitals, which on this disk is a move onto itself.
        let recased = try store.rename(same, to: "second")
        #expect(recased.name == "second")
        #expect(recased.url.lastPathComponent == "second.klikstyle")
        #expect(store.list().map(\.name) == ["Other", "second"])
    }

    @Test func deletingTakesTheFileAway() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LookStore(folder: folder, reservedNames: [])

        let saved = try store.save(look("Gone"))
        try store.delete(saved)
        #expect(store.list().isEmpty)
        #expect(throws: LookStore.Failure.missing) { try store.delete(saved) }
    }

    @Test func importingCopiesTheFileUnderAFreeName() throws {
        let folder = makeFolder()
        let elsewhere = makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let store = LookStore(folder: folder, reservedNames: ["Studio"])
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        // A look sent by somebody else, with a field this build does not know.
        let shared = elsewhere.appendingPathComponent("Sunset.klikstyle")
        try Data(#"{"version": 3, "name": "Sunset", "frame": {"padding": 0.12}, "extra": true}"#.utf8).write(to: shared)

        try store.save(look("Sunset"))
        let imported = try store.importLook(from: shared)
        #expect(imported.name == "Sunset 2", "the person did not type the name, so it is made unique rather than refused")
        #expect(imported.look.frame.padding == 0.12)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: imported.url)) as? [String: Any])
        #expect(object["extra"] as? Bool == true, "copied, not re-encoded")
        #expect(object["name"] as? String == "Sunset 2")
        #expect(store.list().map(\.name) == ["Sunset", "Sunset 2"])

        let again = try store.importLook(from: shared)
        #expect(again.name == "Sunset 3")

        // A reserved name is stepped past the same way.
        let studio = elsewhere.appendingPathComponent("Studio.klikstyle")
        try Data(#"{"name": "Studio", "frame": {"padding": 0.5}}"#.utf8).write(to: studio)
        #expect(try store.importLook(from: studio).name == "Studio 2")
        #expect(FileManager.default.fileExists(atPath: shared.path(percentEncoded: false)), "the original stays where it was")
    }

    @Test func importingSomethingThatIsNotALookIsRefused() throws {
        let folder = makeFolder()
        let elsewhere = makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let store = LookStore(folder: folder, reservedNames: [])
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let text = elsewhere.appendingPathComponent("notes.klikstyle")
        try Data("hello".utf8).write(to: text)
        #expect(throws: LookStore.Failure.notALook) { try store.importLook(from: text) }

        let empty = elsewhere.appendingPathComponent("empty.klikstyle")
        try Data("{}".utf8).write(to: empty)
        #expect(throws: LookStore.Failure.notALook) { try store.importLook(from: empty) }
        #expect(store.list().isEmpty)
    }

    @Test func aFileThatIsNotALookDoesNotSpoilTheList() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LookStore(folder: folder, reservedNames: [])
        try store.save(look("Fine"))
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("broken.klikstyle"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        #expect(store.list().map(\.name) == ["Fine"])
    }

    @Test func theStandardFolderIsUnderApplicationSupport() {
        let folder = LookStore.standardFolder
        #expect(folder.lastPathComponent == "Looks")
        #expect(folder.deletingLastPathComponent().lastPathComponent == "Klik Studio")
        #expect(folder.path(percentEncoded: false).contains("Application Support"))
    }
}
