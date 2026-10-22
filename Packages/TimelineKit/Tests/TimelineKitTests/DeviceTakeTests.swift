import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// A recording of a connected iPhone or iPad in the editor: the frame it opens in, and
/// everything that reads the pointer coping with a take that never had one.
@MainActor
struct DeviceTakeTests {
    private func package(device: RecordedDevice?) throws -> (RecordingPackage, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CueStudioTests-\(UUID().uuidString)", isDirectory: true)
        let package = try RecordingPackage.create(named: "Phone", in: folder)
        var manifest = RecordingManifest(
            name: "Phone",
            duration: 20,
            displayScale: device?.family.displayScale ?? 2,
            tracks: [.init(kind: .screen, path: "media/screen.mov",
                           pixelSize: CGSize(width: 1_178, height: 2_556), frameRate: 60)],
            // What a device take writes: no pointer, no clicks, no focus.
            telemetry: .init())
        manifest.device = device
        try package.write(manifest)
        return (package, folder)
    }

    // MARK: - The frame

    @Test func anIPhoneTakeOpensInAnIPhone() throws {
        let (package, folder) = try package(device: RecordedDevice(name: "Phone", family: .iPhone))
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try EditorDocument(package: package)
        #expect(document.isDeviceTake)

        document.adoptDeviceLook()
        #expect(document.timeline.style.chrome.kind == .iPhone)
        #expect(document.timeline.style.chrome.orientation == .automatic)
        #expect(!document.isDirty, "a look a take opens with is where it starts, not an edit")
    }

    @Test func anIPadTakeOpensInAnIPad() {
        let timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        #expect(timeline.dressed(for: RecordedDevice(name: "Tablet", family: .iPad)).style.chrome.kind == .iPad)
    }

    /// The defaults were written for the Mac; a browser bar round a phone is never meant.
    @Test func theDeviceFrameReplacesAWindowTheDefaultsChose() {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.style.chrome.kind = .browser
        timeline.style.chrome.orientation = .portrait
        let dressed = timeline.dressed(for: RecordedDevice(name: "Phone", family: .iPhone))
        #expect(dressed.style.chrome.kind == .iPhone)
        #expect(dressed.style.chrome.orientation == .automatic)
    }

    /// A device that could not be told apart gets nothing rather than the wrong thing, and
    /// a take of the Mac's own screen is not touched at all.
    @Test func aScreenTakeOrAnUnknownDeviceIsLeftAlone() throws {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.style.chrome.kind = .window
        #expect(timeline.dressed(for: nil) == timeline)
        #expect(timeline.dressed(for: RecordedDevice(name: "Thing", family: .other)) == timeline)

        let (package, folder) = try package(device: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try EditorDocument(package: package)
        #expect(!document.isDeviceTake)
        let before = document.timeline
        document.adoptDeviceLook()
        #expect(document.timeline == before)
    }

    /// Taken off on purpose, it stays off: only an untouched project is dressed.
    @Test func anEditedProjectKeepsItsOwnFrame() throws {
        let (package, folder) = try package(device: RecordedDevice(name: "Phone", family: .iPhone))
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try EditorDocument(package: package)
        try document.save()

        let reopened = try EditorDocument(package: package)
        reopened.adoptDeviceLook()
        #expect(reopened.timeline.style.chrome.kind == .none)
    }

    // MARK: - No pointer

    /// No cursor sidecar at all — not an empty one, none — reads as a track with nothing in
    /// it, and every question the renderer asks of it has a quiet answer.
    @Test func aTakeWithNoPointerHasAnEmptyTrack() throws {
        let (package, folder) = try package(device: RecordedDevice(name: "Phone", family: .iPhone))
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try EditorDocument(package: package)

        let track = document.cursorTrack
        #expect(track.isEmpty)
        #expect(track.clicks.isEmpty, "no clicks, so no click sounds and no click rings")
        #expect(track.position(at: 5) == nil, "no position, so no pointer is drawn")
        #expect(track.marks(at: 5).isEmpty)
        #expect(track.clickScale(at: 5) == 1)
        #expect(track.averagePosition(at: 5, window: 1) == nil)
        #expect(track.speed(at: 5) == 0)
        #expect(document.inputSamples.isEmpty)
        #expect(document.focusSamples.isEmpty)
        #expect(document.pictureTrack.isEmpty)
        #expect(document.cursorArtwork.isEmpty)
    }

    /// Auto-zoom with nothing to go on proposes nothing, rather than guessing.
    @Test func autoZoomHasNothingToProposeWithoutAPointer() {
        let suggester = ZoomSuggester(frameSize: CGSize(width: 393, height: 852))
        let regions = suggester.suggestions(cursor: [], input: [], focus: [],
                                            duration: CMTime(seconds: 20, preferredTimescale: 600))
        #expect(regions.isEmpty)
    }
}
