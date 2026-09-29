import Foundation
import Testing
@testable import RecordKit

/// The Recordings library: listing takes, telling them apart, and the three operations
/// that change something on disk.
///
/// Every test builds its own packages in a temporary folder and removes them afterwards.
/// None of this may ever be pointed at a real library — the operations under test rename,
/// copy and trash, and a screen recording is often the only copy of something.
struct LibraryTests {
    private func temporaryFolder() -> URL {
        let url = URL.temporaryDirectory.appending(path: "RecordKitLibraryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A package with a manifest in it, which is the least a take needs to be listed.
    @discardableResult
    private func make(_ name: String,
                      in folder: URL,
                      at created: Date = .now,
                      duration: Double = 1,
                      tracks: [RecordingManifest.Track] = []) throws -> RecordingPackage {
        let package = try RecordingPackage.create(named: name, in: folder)
        try package.write(RecordingManifest(name: package.url.deletingPathExtension().lastPathComponent,
                                           createdAt: created,
                                           duration: duration,
                                           tracks: tracks))
        return package
    }

    // MARK: - Listing

    @Test func aTakeIsListedWithItsLengthItsDateAndWhatIsInIt() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let package = try make("Demo", in: folder, at: when, duration: 42.5,
                               tracks: [.init(kind: .screen, path: "media/screen.mov"),
                                        .init(kind: .microphone, path: "media/mic.m4a")])
        // Something with bytes in it, so the size is a size rather than zero.
        try Data(repeating: 0, count: 4_096).write(to: package.mediaFolder.appendingPathComponent("screen.mov"))

        let entries = RecordingLibrary(folder: folder).entries()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.name == "Demo")
        #expect(entry.duration == 42.5)
        #expect(entry.createdAt == when)
        #expect(entry.kinds == [.screen, .microphone])
        #expect(entry.byteCount >= 4_096, "the manifest and the media both count")
    }

    /// A package with no readable manifest is a recording that died mid-write. It is
    /// dropped rather than listed, because an error row for it would arrive once per
    /// refresh forever.
    @Test func anUnreadablePackageIsLeftOutRatherThanListedBroken() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try make("Good", in: folder)
        _ = try RecordingPackage.create(named: "Broken", in: folder)

        #expect(RecordingLibrary(folder: folder).entries().map(\.name) == ["Good"])
    }

    /// The folder is the source of truth for the name, because the Finder can rename it
    /// and this app cannot stop it.
    @Test func theFoldersNameWinsOverAStaleManifestName() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try make("Demo", in: folder)
        // What a rename in the Finder leaves behind: the folder says one thing, the
        // manifest still says another.
        let moved = folder.appendingPathComponent("Renamed in Finder.klikrec")
        try FileManager.default.moveItem(at: package.url, to: moved)

        let entry = try #require(RecordingLibrary(folder: folder).entries().first)
        #expect(entry.name == "Renamed in Finder")
        #expect(try RecordingPackage(url: moved).readManifest().name == "Demo",
                "reading a library must not write to it")
    }

    // MARK: - Searching and sorting

    private func sample() -> [RecordingEntry] {
        [RecordingEntry(url: URL(fileURLWithPath: "/l/Take 10.klikrec"), name: "Take 10",
                        createdAt: Date(timeIntervalSince1970: 300), duration: 5, byteCount: 1, kinds: []),
         RecordingEntry(url: URL(fileURLWithPath: "/l/Take 2.klikrec"), name: "Take 2",
                        createdAt: Date(timeIntervalSince1970: 100), duration: 90, byteCount: 1, kinds: []),
         RecordingEntry(url: URL(fileURLWithPath: "/l/apology.klikrec"), name: "apology",
                        createdAt: Date(timeIntervalSince1970: 200), duration: 30, byteCount: 1, kinds: [])]
    }

    @Test func datesSortNewestFirstAndLengthsLongestFirst() {
        #expect(RecordingLibrary.arrange(sample(), by: .date).map(\.name) == ["Take 10", "apology", "Take 2"])
        #expect(RecordingLibrary.arrange(sample(), by: .length).map(\.name) == ["Take 2", "apology", "Take 10"])
    }

    /// Names sort the way the Finder sorts them: A–Z whatever the case, and "Take 2"
    /// before "Take 10" rather than after it.
    @Test func namesSortTheWayTheFinderSortsThem() {
        #expect(RecordingLibrary.arrange(sample(), by: .name).map(\.name) == ["apology", "Take 2", "Take 10"])
    }

    @Test func reversingAnOrderReversesTheList() {
        let forwards = RecordingLibrary.arrange(sample(), by: .date, descending: true).map(\.name)
        let backwards = RecordingLibrary.arrange(sample(), by: .date, descending: false).map(\.name)
        #expect(backwards == forwards.reversed())
    }

    /// Two takes of the same length, or from the same second, must not swap places
    /// between refreshes — a list that reorders itself under the pointer is unusable.
    @Test func tiesAreBrokenByNameSoTheOrderIsStable() {
        let when = Date(timeIntervalSince1970: 1)
        let entries = [RecordingEntry(url: URL(fileURLWithPath: "/l/b.klikrec"), name: "b",
                                      createdAt: when, duration: 1, byteCount: 1, kinds: []),
                       RecordingEntry(url: URL(fileURLWithPath: "/l/a.klikrec"), name: "a",
                                      createdAt: when, duration: 1, byteCount: 1, kinds: [])]
        #expect(RecordingLibrary.arrange(entries, by: .date).map(\.name) == ["a", "b"])
        #expect(RecordingLibrary.arrange(entries, by: .length).map(\.name) == ["a", "b"])
    }

    @Test(arguments: ["take", "TAKE", " take "])
    func searchIgnoresCaseAndSurroundingSpace(query: String) {
        #expect(RecordingLibrary.arrange(sample(), matching: query, by: .name).map(\.name) == ["Take 2", "Take 10"])
    }

    @Test func anEmptySearchKeepsEverything() {
        #expect(RecordingLibrary.arrange(sample(), matching: "   ").count == 3)
        #expect(RecordingLibrary.arrange(sample(), matching: "nothing at all").isEmpty)
    }

    // MARK: - Renaming

    @Test func renamingMovesTheFolderAndTheManifestTogether() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let library = RecordingLibrary(folder: folder)
        let package = try make("Demo", in: folder, duration: 12)
        let renamed = try library.rename(package.url, to: "The one with the bug")

        #expect(renamed.lastPathComponent == "The one with the bug.klikrec")
        #expect(!FileManager.default.fileExists(atPath: package.url.path(percentEncoded: false)))
        #expect(try RecordingPackage(url: renamed).readManifest().name == "The one with the bug")
        #expect(try RecordingPackage(url: renamed).readManifest().duration == 12,
                "the rest of the manifest survives the rename")
        #expect(library.entries().map(\.name) == ["The one with the bug"])
    }

    /// A name is trimmed before it is used: a trailing space is invisible, and would
    /// produce a second recording that looks identical to the first.
    @Test func aNameIsTrimmedBeforeItIsUsed() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try make("Demo", in: folder)
        let renamed = try RecordingLibrary(folder: folder).rename(package.url, to: "  Tidy  ")
        #expect(renamed.lastPathComponent == "Tidy.klikrec")
    }

    @Test func aNameAlreadyTakenIsRefusedAndNothingMoves() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try make("Demo", in: folder)
        let second = try make("Other", in: folder)

        #expect(throws: RecordingLibraryError.nameTaken("Demo")) {
            try RecordingLibrary(folder: folder).rename(second.url, to: "Demo")
        }
        #expect(FileManager.default.fileExists(atPath: first.url.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: second.url.path(percentEncoded: false)))
        #expect(try RecordingPackage(url: first.url).readManifest().name == "Demo",
                "the recording that was not renamed is untouched")
    }

    /// Renaming to the name it already has is not a collision with itself. It is also
    /// the repair for a manifest the Finder left behind.
    @Test func renamingToItsOwnNamePutsTheManifestBackInStep() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try make("Demo", in: folder)
        let moved = folder.appendingPathComponent("Finder Name.klikrec")
        try FileManager.default.moveItem(at: package.url, to: moved)

        let renamed = try RecordingLibrary(folder: folder).rename(moved, to: "Finder Name")
        #expect(renamed == moved)
        #expect(try RecordingPackage(url: moved).readManifest().name == "Finder Name")
    }

    @Test(arguments: [("", RecordingLibraryError.emptyName),
                      ("   ", .emptyName),
                      ("../../etc/passwd", .nameContainsPathSeparator),
                      ("Demo/Take 2", .nameContainsPathSeparator),
                      ("Macintosh HD:Users", .nameContainsPathSeparator),
                      (".hidden", .nameIsHidden)])
    func aNameThatIsReallyAPathIsRefused(name: String, expected: RecordingLibraryError) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try make("Demo", in: folder)
        #expect(throws: expected) { try RecordingLibrary(folder: folder).rename(package.url, to: name) }
        #expect(FileManager.default.fileExists(atPath: package.url.path(percentEncoded: false)))
    }

    /// Why the window refuses to rename a take whose editor is open.
    ///
    /// An `EditorSession` holds its `packageURL` in a `let`, and the document saves
    /// through it. This is what a rename does to anybody holding one: the path they have
    /// stops existing, and every write through it — the timeline, an imported sound, an
    /// export — goes somewhere that is not the recording. No window is involved in
    /// asserting it, which is the point: the refusal in `LibraryCatalog` is not a
    /// preference, it follows from this.
    @Test func aUrlHeldFromBeforeARenameNoLongerPointsAtTheRecording() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try make("Demo", in: folder)
        let held = package.url
        try RecordingLibrary(folder: folder).rename(held, to: "Renamed")

        #expect(!FileManager.default.fileExists(atPath: held.path(percentEncoded: false)))
        #expect(throws: (any Error).self) { try RecordingPackage(url: held).readManifest() }
    }

    // MARK: - Duplicating

    @Test func duplicatingTakesTheNextFreeNumberAndLeavesTheOriginal() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let library = RecordingLibrary(folder: folder)
        let package = try make("Demo", in: folder, duration: 7)
        try Data("frames".utf8).write(to: package.mediaFolder.appendingPathComponent("screen.mov"))

        let copy = try library.duplicate(package.url)
        #expect(copy.lastPathComponent == "Demo 2.klikrec")
        #expect(FileManager.default.fileExists(atPath: package.url.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("media/screen.mov").path(percentEncoded: false)),
                "a duplicate with no media is not a duplicate")

        let manifest = try RecordingPackage(url: copy).readManifest()
        #expect(manifest.name == "Demo 2", "the copy knows what it is called")
        #expect(manifest.duration == 7)

        let again = try library.duplicate(package.url)
        #expect(again.lastPathComponent == "Demo 3.klikrec", "the number steps past what is there")
    }

    // MARK: - The guard on everything destructive

    @Test func nothingDestructiveTouchesAFileOutsideTheLibrary() throws {
        let folder = temporaryFolder()
        let elsewhere = temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let library = RecordingLibrary(folder: folder)
        let stranger = try make("Somebody Else", in: elsewhere)

        #expect(throws: RecordingLibraryError.outsideLibrary) { try library.check(stranger.url) }
        #expect(throws: RecordingLibraryError.outsideLibrary) { try library.moveToTrash(stranger.url) }
        #expect(throws: RecordingLibraryError.outsideLibrary) { try library.rename(stranger.url, to: "Mine Now") }
        #expect(throws: RecordingLibraryError.outsideLibrary) { try library.duplicate(stranger.url) }
        #expect(FileManager.default.fileExists(atPath: stranger.url.path(percentEncoded: false)))
    }

    /// The folder itself, not a folder beneath it: a `.klikrec` inside a subfolder of the
    /// library is not something this window is listing, so it is not something this
    /// window may delete.
    @Test func aRecordingInASubfolderIsNotThisLibrarys() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let nested = folder.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let package = try make("Demo", in: nested)

        #expect(throws: RecordingLibraryError.outsideLibrary) { try RecordingLibrary(folder: folder).check(package.url) }
    }

    @Test func anythingThatIsNotARecordingIsRefusedBeforeItIsLookedAt() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let library = RecordingLibrary(folder: folder)
        let precious = folder.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)

        #expect(throws: RecordingLibraryError.notARecording) { try library.moveToTrash(precious) }
        #expect(throws: RecordingLibraryError.notARecording) { try library.check(folder) }
        #expect(FileManager.default.fileExists(atPath: precious.path(percentEncoded: false)))
    }

    @Test func aRecordingThatHasAlreadyGoneIsReportedRatherThanGuessedAt() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let gone = folder.appendingPathComponent("Deleted in Finder.klikrec")
        #expect(throws: RecordingLibraryError.missing) { try RecordingLibrary(folder: folder).check(gone) }
    }

    /// Deleting is the Trash, never an unlink.
    ///
    /// Asserted on where it went, not only on the original being gone: `removeItem` would
    /// also pass "the original is gone", and the difference between the two is whether the
    /// user can get their recording back. The test then removes exactly the item the
    /// system reported, so it does not leave litter in anybody's Trash.
    @Test func deletingMovesTheRecordingToTheTrashWhereItCanBeRecovered() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try make("RecordKitLibraryTests-Trashable", in: folder)
        let trashed = try RecordingLibrary(folder: folder).moveToTrash(package.url)

        let landed = try #require(trashed, "the system must say where it put it")
        defer { try? FileManager.default.removeItem(at: landed) }
        #expect(FileManager.default.fileExists(atPath: landed.path(percentEncoded: false)))
        #expect(landed.pathExtension == "klikrec")
        #expect(!FileManager.default.fileExists(atPath: package.url.path(percentEncoded: false)))
    }
}
