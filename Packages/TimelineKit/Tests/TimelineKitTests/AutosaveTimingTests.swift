import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// When an autosave is due, told against a clock that is a number.
struct AutosaveTimingTests {
    @Test func nothingIsDueUntilSomethingIsEdited() {
        let timing = AutosaveTiming(quiet: 2)
        #expect(timing.due == nil)
        #expect(!timing.isDue(at: 100))
        #expect(timing.wait(from: 100) == nil)
        #expect(!timing.isWaiting)
    }

    @Test func aWriteIsDueAQuietPeriodAfterTheLastEdit() {
        var timing = AutosaveTiming(quiet: 2)
        timing.edited(at: 10)
        #expect(timing.due == 12)
        #expect(!timing.isDue(at: 11.9))
        #expect(timing.isDue(at: 12))
        #expect(timing.isDue(at: 50), "overdue is still due")
    }

    /// Edits that keep coming push the write out: a drag is one write at its end.
    @Test func everyEditRestartsTheQuietPeriod() {
        var timing = AutosaveTiming(quiet: 2)
        timing.edited(at: 10)
        timing.edited(at: 11)
        timing.edited(at: 11.5)
        #expect(timing.due == 13.5)
        #expect(!timing.isDue(at: 12))
        #expect(timing.wait(from: 11.5) == 2)
        #expect(timing.wait(from: 13) == 0.5)
        #expect(timing.wait(from: 20) == 0, "never asked to wait a negative time")
    }

    @Test func aWriteThatHadToBePutOffIsTriedAgainAfterAnotherQuietPeriod() {
        var timing = AutosaveTiming(quiet: 2)
        timing.edited(at: 10)
        timing.postponed(at: 12)
        #expect(timing.due == 14)
    }

    @Test func settlingClearsWhatWasWaiting() {
        var timing = AutosaveTiming(quiet: 2)
        timing.edited(at: 10)
        timing.settled()
        #expect(timing.due == nil)
        #expect(!timing.isDue(at: 100))
        timing.edited(at: 20)
        #expect(timing.due == 22, "and a later edit starts afresh")
    }

    @Test func theDefaultQuietPeriodIsAboutTwoSeconds() {
        #expect(AutosaveTiming().quiet == 2)
        #expect(AutosaveTiming(quiet: -5).quiet == 0, "a negative period is nonsense and means now")
    }
}

/// The write itself, taken off the main thread for a save nobody asked for.
@MainActor
struct BackgroundSaveTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func makeDocument() throws -> (EditorDocument, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueStudioTests-\(UUID().uuidString)", isDirectory: true)
        let package = try RecordingPackage.create(named: "Take", in: folder)
        try package.write(RecordingManifest(name: "Take", duration: 30))
        return (try EditorDocument(package: package), folder)
    }

    @Test func aBackgroundSaveWritesTheProjectAndMarksItClean() async throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(3), duration: time(5), scale: 3)))
        #expect(document.isDirty)
        try await document.saveInBackground().value
        #expect(!document.isDirty)
        #expect(document.hasBeenEdited)

        let reopened = try EditorDocument(package: document.package)
        #expect(reopened.timeline == document.timeline)
    }

    /// An edit made while the file was being written is still unsaved afterwards —
    /// against the version on disk, which is the only honest comparison.
    @Test func editingDuringTheWriteLeavesTheDocumentDirty() async throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(3), duration: time(5))))
        let writing = document.saveInBackground()
        document.apply(Commands.AddZoom(ZoomRegion(start: time(12), duration: time(5))))
        try await writing.value

        #expect(document.isDirty, "the second zoom is not in the file")
        let reopened = try EditorDocument(package: document.package)
        #expect(reopened.timeline.zooms.count == 1)
        try await document.saveInBackground().value
        #expect(!document.isDirty)
    }

    /// The old file stays whole until the new one is complete — a rename, never a
    /// rewrite in place.
    @Test func theSaveIsAtomic() async throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(3), duration: time(5))))
        try await document.saveInBackground().value
        let projectURL = document.package.url.appendingPathComponent(EditorDocument.projectFileName)
        let first = try Data(contentsOf: projectURL)

        document.apply(Commands.AddZoom(ZoomRegion(start: time(12), duration: time(5))))
        try await document.saveInBackground().value
        let second = try Data(contentsOf: projectURL)
        #expect(second != first)
        // Nothing half-written left beside it.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: document.package.url.path(percentEncoded: false))
            .filter { $0.hasPrefix(".project.") }
        #expect(leftovers.isEmpty)
    }

    @Test func undoWorksAcrossASave() async throws {
        let (document, folder) = try makeDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        document.apply(Commands.AddZoom(ZoomRegion(start: time(3), duration: time(5))))
        try await document.saveInBackground().value
        document.apply(Commands.AddZoom(ZoomRegion(start: time(12), duration: time(5))))
        try await document.saveInBackground().value

        document.undo()
        #expect(document.timeline.zooms.count == 1)
        #expect(document.isDirty, "undone past what is on disk")
        document.undo()
        #expect(document.timeline.zooms.isEmpty)
        document.redo()
        document.redo()
        #expect(document.timeline.zooms.count == 2)
        #expect(!document.isDirty, "back to exactly what was written")
    }
}
