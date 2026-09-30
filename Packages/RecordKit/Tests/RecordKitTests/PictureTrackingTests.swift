import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import RecordKit

/// Writing down where a window's picture sat inside a frame whose size was fixed before
/// the window was resized.
///
/// The numbers are a real take's: a 1512 × 861 pt frame on a 2× display, and a window that
/// grew taller after the countdown and was shrunk by 0.907 to fit — its picture 1371.8 pt
/// wide against the left edge, and black to the right of it.
struct PictureTrackingTests {
    private let frame = CGRect(x: 0, y: 0, width: 1_512, height: 861)

    private func geometry(_ content: CGRect, scale: CGFloat = 0.907, factor: CGFloat = 2) -> FrameGeometry {
        FrameGeometry(screenRect: CGRect(x: 200, y: 100, width: 1_512, height: 949),
                      contentRect: content, contentScale: scale, scaleFactor: factor)
    }

    // MARK: - The rule

    /// The frame was sized for the picture, so a picture that fills it is news to nobody —
    /// and a take whose window was never touched writes nothing at all.
    @Test func aPictureThatFillsTheFrameWritesNothing() {
        var rule = PictureRule(frame: frame, outputScale: 2)
        let filling = rule.change(for: geometry(frame, scale: 1))
        // A rounding error either way is still the whole frame.
        let rounded = rule.change(for: geometry(CGRect(x: 0, y: 0, width: 1_511.7, height: 861.2), scale: 1))
        #expect(filling == nil)
        #expect(rounded == nil)
    }

    @Test func aShrunkPictureIsWrittenOnceAndNotAgainUntilItMoves() {
        var rule = PictureRule(frame: frame, outputScale: 2)
        let shrunk = CGRect(x: 0, y: 0, width: 1_371.8, height: 861)

        let written = rule.change(for: geometry(shrunk))
        // The same picture on the next frame, and the next with a shimmer smaller than the
        // tolerance: neither is a change.
        let same = rule.change(for: geometry(shrunk))
        let shimmer = rule.change(for: geometry(CGRect(x: 0.2, y: 0, width: 1_372.1, height: 860.8)))
        // Half a point and more on any edge is.
        let moved = rule.change(for: geometry(CGRect(x: 0, y: 0, width: 1_360, height: 861)))
        #expect(written == shrunk)
        #expect(same == nil)
        #expect(shimmer == nil)
        #expect(moved == CGRect(x: 0, y: 0, width: 1_360, height: 861))
    }

    /// A window put back to the size it started at leaves nothing black, and the editor has
    /// to be told so or it would go on cropping a picture that no longer needs it.
    @Test func goingBackToFillingTheFrameIsWrittenToo() {
        var rule = PictureRule(frame: frame, outputScale: 2)
        _ = rule.change(for: geometry(CGRect(x: 0, y: 0, width: 1_371.8, height: 861)))
        let restored = rule.change(for: geometry(frame, scale: 1))
        #expect(restored == frame)
    }

    /// The attachments are in the points of the display the window is on. Dragged onto a 1×
    /// display mid-take, the same picture is described in half as many points, and it is
    /// the file's own points that the pointer is written in.
    @Test func thePictureIsWrittenInTheFilesPointsNotTheDisplays() {
        let picture = PictureRule.picture(of: geometry(CGRect(x: 0, y: 0, width: 685.9, height: 430.5), factor: 1),
                                          outputScale: 2, in: frame)
        #expect(picture == CGRect(x: 0, y: 0, width: 342.95, height: 215.25))
    }

    /// A frame that reports more than the frame holds is kept to the frame, and one that
    /// reports nothing usable is not written — the last answer stands.
    @Test func whatIsWrittenIsKeptInsideTheFrame() {
        #expect(PictureRule.picture(of: geometry(CGRect(x: -4, y: 0, width: 1_600, height: 900)),
                                    outputScale: 2, in: frame) == frame)
        #expect(PictureRule.picture(of: geometry(.zero), outputScale: 2, in: frame) == nil)
        #expect(PictureRule.picture(of: geometry(frame, factor: 0), outputScale: 2, in: frame) == nil)
    }

    // MARK: - The sidecar

    @Test func theSidecarHoldsOneLinePerChangeOnTheRecordingsClock() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("picture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let queue = DispatchQueue(label: "test.picture")
        let writer = JSONLWriter(url: folder.appendingPathComponent("picture.jsonl"), queue: queue)
        let clock = RecordingClock()
        let origin = CMTime(seconds: 1_000, preferredTimescale: 600)
        clock.start(at: origin)
        let tracker = PictureTracker(writer: writer, clock: clock, frameSize: frame.size, outputScale: 2)
        func at(_ seconds: Double) -> CMTime { origin + CMTime(seconds: seconds, preferredTimescale: 600) }

        let shrunk = CGRect(x: 0, y: 0, width: 1_371.8, height: 861)
        queue.sync {
            try? writer.open()
            tracker.place(geometry(frame, scale: 1), at: at(0))
            tracker.place(geometry(frame, scale: 1), at: at(1))
            tracker.place(geometry(shrunk), at: at(2))
            tracker.place(geometry(shrunk), at: at(2.5))
            tracker.place(geometry(frame, scale: 1), at: at(4))
            #expect(writer.close())
        }

        let samples = try String(contentsOf: writer.url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try JSONDecoder().decode(PictureSample.self, from: Data($0.utf8)) }
        #expect(samples.map(\.t) == [2, 4])
        #expect(samples.map(\.rect) == [shrunk, frame])
    }

    /// A window that is never resized leaves no file behind, so the manifest has nothing to
    /// name and the editor has nothing to read.
    @Test func aWindowNeverResizedLeavesNoSidecar() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("picture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let queue = DispatchQueue(label: "test.picture.untouched")
        let writer = JSONLWriter(url: folder.appendingPathComponent("picture.jsonl"), queue: queue)
        let clock = RecordingClock()
        clock.start(at: .zero)
        let tracker = PictureTracker(writer: writer, clock: clock, frameSize: frame.size, outputScale: 2)
        queue.sync {
            try? writer.open()
            for index in 0..<120 {
                tracker.place(geometry(frame, scale: 1), at: CMTime(value: CMTimeValue(index), timescale: 60))
            }
            #expect(!writer.close())
        }
        #expect(!FileManager.default.fileExists(atPath: writer.url.path(percentEncoded: false)))
    }

    // MARK: - The manifest

    @Test func theManifestNamesThePictureTrack() throws {
        let manifest = RecordingManifest(name: "Window",
                                         telemetry: .init(cursor: "telemetry/cursor.jsonl",
                                                          picture: "telemetry/picture.jsonl"))
        let decoded = try JSONDecoder().decode(RecordingManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded.telemetry.picture == "telemetry/picture.jsonl")
    }

    /// Every package recorded before the track existed has no such key, and must open.
    @Test func aManifestWrittenBeforeThePictureTrackStillOpens() throws {
        let manifest = RecordingManifest(name: "Old", telemetry: .init(cursor: "telemetry/cursor.jsonl"))
        var fields = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        var telemetry = try #require(fields["telemetry"] as? [String: Any])
        telemetry.removeValue(forKey: "picture")
        fields["telemetry"] = telemetry

        let decoded = try JSONDecoder().decode(RecordingManifest.self,
                                               from: JSONSerialization.data(withJSONObject: fields))
        #expect(decoded.telemetry.picture == nil)
        #expect(decoded.telemetry.cursor == "telemetry/cursor.jsonl")
    }
}
