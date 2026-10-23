import CoreMedia
import Foundation
import Testing
@testable import RecordKit

/// Markers dropped while recording land on the recording's clock, pauses taken out.
struct MarkerLogTests {
    private func host(_ seconds: Double) -> CMTime {
        CMTime(seconds: 1_000 + seconds, preferredTimescale: 600)
    }

    /// A log writing into a fresh folder, and a clock started at host second 0.
    private func makeLog() throws -> (MarkerLog, JSONLWriter, DispatchQueue, RecordingClock, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-tests-\(UUID().uuidString)", isDirectory: true)
        let queue = DispatchQueue(label: "marker-tests")
        let writer = JSONLWriter(url: folder.appendingPathComponent("markers.jsonl"), queue: queue)
        try queue.sync { try writer.open() }
        let clock = RecordingClock()
        clock.start(at: host(0))
        return (MarkerLog(writer: writer, queue: queue, clock: clock), writer, queue, clock, folder)
    }

    @Test func `a marker is stamped with seconds since the clock started`() throws {
        let (log, _, _, _, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = log.add(at: host(4.5))
        #expect(marker?.t == 4.5)
    }

    /// The whole reason markers read the clock: after a five-second hold, a marker dropped
    /// at wall-clock second 12 is at recording second 7, where the picture is.
    @Test func `a marker after a pause leaves the pause out`() throws {
        let (log, _, _, clock, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        clock.hold(at: host(2))
        clock.release(at: host(7))
        let marker = log.add(at: host(12))
        #expect(abs((marker?.t ?? 0) - 7) < 0.0001)
    }

    @Test func `a marker dropped while paused lands where the pause began`() throws {
        let (log, _, _, clock, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        clock.hold(at: host(3))
        let marker = log.add(at: host(9))
        #expect(abs((marker?.t ?? 0) - 3) < 0.0001)
    }

    @Test func `two pauses are both taken out`() throws {
        let (log, _, _, clock, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        clock.hold(at: host(1))
        clock.release(at: host(3))      // 2 s out
        clock.hold(at: host(5))
        clock.release(at: host(10))     // 5 s out
        let marker = log.add(at: host(20))
        #expect(abs((marker?.t ?? 0) - 13) < 0.0001)
    }

    @Test func `no marker before the first frame`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)")
        let queue = DispatchQueue(label: "marker-tests")
        let writer = JSONLWriter(url: folder.appendingPathComponent("markers.jsonl"), queue: queue)
        let log = MarkerLog(writer: writer, queue: queue, clock: RecordingClock())
        #expect(log.add(at: host(1)) == nil)
        #expect(log.markers.isEmpty)
    }

    @Test func `two presses a moment apart are one marker`() throws {
        let (log, _, _, _, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(log.add(at: host(2)) != nil)
        #expect(log.add(at: host(2.1)) == nil)
        #expect(log.add(at: host(2 + MarkerLog.minimumSpacing + 0.01)) != nil)
        #expect(log.markers.count == 2)
    }

    /// Two presses either side of a pause are far apart in wall time and on top of each
    /// other in the recording. The recording's time is the one that decides.
    @Test func `spacing is measured on the recording's clock`() throws {
        let (log, _, _, clock, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(log.add(at: host(5)) != nil)
        clock.hold(at: host(5.05))
        clock.release(at: host(30))
        #expect(log.add(at: host(30.1)) == nil, "0.15 s after the last one in the recording")
    }

    @Test func `markers reach the file, one per line, readable back`() throws {
        let (log, writer, queue, _, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        log.add(at: host(1))
        log.add(at: host(3.25))
        let wrote = queue.sync { writer.close() }
        #expect(wrote)
        let lines = try String(contentsOf: writer.url, encoding: .utf8).split(separator: "\n")
        let samples = try lines.map { try JSONDecoder().decode(MarkerSample.self, from: Data($0.utf8)) }
        #expect(samples == [MarkerSample(t: 1), MarkerSample(t: 3.25)])
        // Recovery cuts every sidecar by the `t` at the top of each line.
        #expect(TakeRecovery.time(ofLine: Data(lines[1].utf8)) == 3.25)
    }

    @Test func `a take with no markers leaves no file`() throws {
        let (_, writer, queue, _, folder) = try makeLog()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrote = queue.sync { writer.close() }
        #expect(!wrote)
        #expect(!FileManager.default.fileExists(atPath: writer.url.path(percentEncoded: false)))
    }

    // MARK: - The manifest

    /// Old projects open: a manifest from before markers decodes, with none.
    @Test func `a manifest without markers still decodes`() throws {
        let json = """
        {"formatVersion":1,"name":"Old","createdAt":"2025-01-01T00:00:00Z","duration":3,
         "displayScale":2,"tracks":[],"telemetry":{"cursor":"telemetry/cursor.jsonl"},
         "recordedBy":"Cue Studio"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecordingManifest.self, from: Data(json.utf8))
        #expect(manifest.telemetry.markers == nil)
        #expect(manifest.telemetry.cursor == "telemetry/cursor.jsonl")
    }

    @Test func `the manifest names the marker log and keeps it through a round trip`() throws {
        let manifest = RecordingManifest(name: "Take", telemetry: .init(markers: MarkerLog.path))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(RecordingManifest.self, from: encoder.encode(manifest))
        #expect(back.telemetry.markers == "telemetry/markers.jsonl")
    }

    /// Recovery keeps the marker log of an interrupted take when it has lines in it, and
    /// forgets it when the take was cut short before any marker was written.
    @Test func `recovery keeps a marker log only when it has markers`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marker-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Take", in: folder)
        let telemetry = RecordingManifest.Telemetry(markers: MarkerLog.path)
        #expect(TakeRecovery.present(telemetry, in: package).markers == nil)

        try Data("{\"t\":1.5}\n".utf8).write(to: package.url.appendingPathComponent(MarkerLog.path))
        #expect(TakeRecovery.present(telemetry, in: package).markers == MarkerLog.path)
    }
}
