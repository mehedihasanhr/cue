import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Markers from the recording, placed on the edit, jumped between and cut at.
struct RecordedMarkerTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func seconds(_ times: [CMTime]) -> [Double] {
        times.map { ($0.seconds * 1_000).rounded() / 1_000 }
    }

    private let markers = [MarkerSample(t: 8), MarkerSample(t: 2), MarkerSample(t: 5)]

    @Test func `on an untouched timeline a marker is where it was recorded, in order`() {
        let timeline = Timeline(sourceDuration: time(10))
        #expect(seconds(RecordedMarkers.times(of: markers, in: timeline)) == [2, 5, 8])
    }

    @Test func `trimming the start moves every marker with the footage`() {
        let timeline = Timeline(sourceDuration: time(10),
                                clips: [Clip(sourceStart: time(1), sourceDuration: time(9))])
        #expect(seconds(RecordedMarkers.times(of: markers, in: timeline)) == [1, 4, 7])
    }

    @Test func `a marker in footage that was cut out is gone`() {
        let timeline = Timeline(sourceDuration: time(10),
                                clips: [Clip(sourceStart: time(0), sourceDuration: time(4)),
                                        Clip(sourceStart: time(6), sourceDuration: time(4))])
        #expect(seconds(RecordedMarkers.times(of: markers, in: timeline)) == [2, 6])
    }

    @Test func `a faster stretch brings its markers closer`() {
        let timeline = Timeline(sourceDuration: time(10),
                                clips: [Clip(sourceStart: time(0), sourceDuration: time(10), speed: 2)])
        #expect(seconds(RecordedMarkers.times(of: markers, in: timeline)) == [1, 2.5, 4])
    }

    @Test func `previous and next skip the marker the playhead is on`() {
        let times = [time(2), time(5), time(8)]
        #expect(RecordedMarkers.next(after: time(5), in: times) == time(8))
        #expect(RecordedMarkers.previous(before: time(5), in: times) == time(2))
        #expect(RecordedMarkers.next(after: time(5.004), in: times) == time(8), "within a hundredth is on it")
        #expect(RecordedMarkers.next(after: time(8), in: times) == nil)
        #expect(RecordedMarkers.previous(before: time(2), in: times) == nil)
        #expect(RecordedMarkers.previous(before: time(100), in: times) == time(8))
    }

    @Test func `split at markers cuts at each one, as one undoable step`() {
        var timeline = Timeline(sourceDuration: time(10))
        let times = RecordedMarkers.times(of: markers, in: timeline)
        #expect(Commands.SplitAtMarkers(at: times).apply(to: &timeline))
        #expect(timeline.clips.count == 4)
        #expect(timeline.duration == time(10), "a cut has no length")
        #expect(seconds(timeline.clips.map(\.sourceStart)) == [0, 2, 5, 8])
    }

    @Test func `a marker on an existing cut or an end is passed over`() {
        var timeline = Timeline(sourceDuration: time(10),
                                clips: [Clip(sourceStart: time(0), sourceDuration: time(5)),
                                        Clip(sourceStart: time(5), sourceDuration: time(5))])
        #expect(Commands.SplitAtMarkers(at: [time(0), time(5), time(10)]).apply(to: &timeline) == false)
        #expect(timeline.clips.count == 2)
        #expect(Commands.SplitAtMarkers(at: [time(5), time(7)]).apply(to: &timeline))
        #expect(timeline.clips.count == 3)
    }

    // MARK: - Reading them from the package

    @MainActor
    private func makeDocument(markerLines: String?) throws -> (EditorDocument, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markers-\(UUID().uuidString)")
        let package = try RecordingPackage.create(named: "Take", in: folder)
        var manifest = RecordingManifest(name: "Take", duration: 10)
        if let markerLines {
            try Data(markerLines.utf8).write(to: package.url.appendingPathComponent(MarkerLog.path))
            manifest.telemetry.markers = MarkerLog.path
        }
        try package.write(manifest)
        return (try EditorDocument(package: package), folder)
    }

    @MainActor
    @Test func `a document reads the markers its recording has`() throws {
        let (document, folder) = try makeDocument(markerLines: "{\"t\":1.5}\n{\"t\":4}\n{\"t\":")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(document.recordedMarkers == [MarkerSample(t: 1.5), MarkerSample(t: 4)],
                "a half-written last line from a crash is skipped")
    }

    @MainActor
    @Test func `a recording made before markers has none`() throws {
        let (document, folder) = try makeDocument(markerLines: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(document.recordedMarkers.isEmpty)
    }
}
