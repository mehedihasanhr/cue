import CoreGraphics
import AppKit
import Foundation
import Testing
@testable import RecordKit

/// The `.cuerec` package, its manifest, and the telemetry files beside the video.
struct PackageTests {
    private func temporaryFolder() -> URL {
        let url = URL.temporaryDirectory.appending(path: "RecordKitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aNewPackageHasItsFoldersReady() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try RecordingPackage.create(named: "Demo", in: folder)
        #expect(package.url.pathExtension == "cuerec")
        for directory in [package.url, package.mediaFolder, package.telemetryFolder] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    /// Four takes of the same thing are the normal case, and none of them may overwrite
    /// another.
    @Test func recordingTwiceNeverOverwrites() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try RecordingPackage.create(named: "Demo", in: folder)
        let second = try RecordingPackage.create(named: "Demo", in: folder)
        let third = try RecordingPackage.create(named: "Demo", in: folder)

        #expect(first.url.lastPathComponent == "Demo.cuerec")
        #expect(second.url.lastPathComponent == "Demo 2.cuerec")
        #expect(third.url.lastPathComponent == "Demo 3.cuerec")
    }

    @Test func theManifestRoundTrips() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try RecordingPackage.create(named: "Demo", in: folder)
        let manifest = RecordingManifest(name: "Demo",
                                         duration: 12.5,
                                         displayScale: 2,
                                         sourceRect: CGRect(x: 10, y: 20, width: 800, height: 600),
                                         tracks: [.init(kind: .screen, path: "media/screen.mov",
                                                        pixelSize: CGSize(width: 1_600, height: 1_200),
                                                        frameRate: 60, codec: "hvc1")],
                                         telemetry: .init(cursor: "telemetry/cursor.jsonl"))
        try package.write(manifest)

        let read = try package.readManifest()
        #expect(read.name == "Demo")
        #expect(read.duration == 12.5)
        #expect(read.track(.screen)?.pixelSize == CGSize(width: 1_600, height: 1_200))
        #expect(read.telemetry.cursor == "telemetry/cursor.jsonl")
        #expect(read.formatVersion == RecordingManifest.currentFormat)
        #expect(abs(read.createdAt.timeIntervalSince(manifest.createdAt)) < 1)
    }

    /// Rewriting the manifest happens whenever a recording ends; a half-written one
    /// would read as a corrupt recording even with every frame safe beside it.
    @Test func rewritingTheManifestReplacesItWhole() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try RecordingPackage.create(named: "Demo", in: folder)
        try package.write(RecordingManifest(name: "First", duration: 1))
        try package.write(RecordingManifest(name: "Second", duration: 2))

        #expect(try package.readManifest().name == "Second")
        let strays = try FileManager.default.contentsOfDirectory(atPath: package.url.path(percentEncoded: false))
            .filter { $0.hasPrefix(".manifest") }
        #expect(strays.isEmpty, "the temporary file must not be left behind")
    }

    @Test func relativePathsAreRecordedNotAbsoluteOnes() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let package = try RecordingPackage.create(named: "Demo", in: folder)
        let file = package.mediaFolder.appendingPathComponent("screen.mov")
        #expect(package.relativePath(of: file) == "media/screen.mov")
    }

    @Test func discardRefusesAnythingThatIsNotAPackage() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let precious = folder.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        RecordingPackage(url: precious).discard()
        #expect(FileManager.default.fileExists(atPath: precious.path(percentEncoded: false)))

        let package = try RecordingPackage.create(named: "Demo", in: folder)
        package.discard()
        #expect(!FileManager.default.fileExists(atPath: package.url.path(percentEncoded: false)))
    }

    // MARK: - Telemetry

    @Test func telemetryIsWrittenOnePerLine() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let queue = DispatchQueue(label: "test.telemetry")
        let writer = JSONLWriter(url: folder.appendingPathComponent("cursor.jsonl"), queue: queue)
        queue.sync {
            try? writer.open()
            for index in 0..<2_000 {
                writer.append(CursorSample(t: Double(index) / 120, x: Double(index), y: 0, shape: .arrow))
            }
            #expect(writer.close())
        }

        let lines = try String(contentsOf: writer.url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2_000)

        let decoder = JSONDecoder()
        let first = try decoder.decode(CursorSample.self, from: Data(lines[0].utf8))
        let last = try decoder.decode(CursorSample.self, from: Data(lines[1_999].utf8))
        #expect(first.x == 0)
        #expect(last.x == 1_999)
    }

    /// An empty track is left out rather than recorded as an empty file the editor has
    /// to special-case.
    @Test func atrackWithNoSamplesLeavesNoFile() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let queue = DispatchQueue(label: "test.telemetry.empty")
        let writer = JSONLWriter(url: folder.appendingPathComponent("input.jsonl"), queue: queue)
        queue.sync {
            try? writer.open()
            #expect(!writer.close())
        }
        #expect(!FileManager.default.fileExists(atPath: writer.url.path(percentEncoded: false)))
    }

    @Test func inputSamplesKeepTheirKindAndTime() throws {
        let samples: [InputSample] = [
            .mouseDown(t: 1.5, button: 0, x: 10, y: 20),
            .scroll(t: 2, dx: 0, dy: -12),
            .key(t: 2.5, modifiers: 0),
        ]
        let data = try JSONEncoder().encode(samples)
        let decoded = try JSONDecoder().decode([InputSample].self, from: data)
        #expect(decoded == samples)
        #expect(decoded.map(\.t) == [1.5, 2, 2.5])
    }

    /// A recording may say *when* someone typed. It may never say what they typed.
    ///
    /// Asserted on the bytes rather than on the type, because the type is exactly the
    /// thing that could quietly regain a text field one day. If this fails, a `.cuerec`
    /// has started carrying its author's keystrokes next to the video.
    @Test func aKeystrokeNeverCarriesItsText() throws {
        let data = try JSONEncoder().encode([InputSample.key(t: 2.5, modifiers: 1 << 17)])
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.lowercased().contains("character"))
        #expect(!json.lowercased().contains("keycode"))
        #expect(json.contains("2.5"), "the timing is the part worth keeping")
    }

    /// Recordings made before the text was dropped must still open.
    ///
    /// The old line carries a `characters` field this build has no case for. Decoding
    /// ignores it — which is the whole reason the field could be removed rather than
    /// deprecated — and the take opens with its typing rhythm intact.
    @Test func aRecordingFromBeforeTheTextWasDroppedStillOpens() throws {
        let old = Data(#"[{"key":{"t":2.5,"characters":"hunter2","modifiers":0}}]"#.utf8)
        let decoded = try JSONDecoder().decode([InputSample].self, from: old)

        #expect(decoded == [.key(t: 2.5, modifiers: 0)])
    }

    /// Typing and operating the app are different things, and only one of them should
    /// pull the camera to a text field.
    @Test func modifiersSeparateTypingFromShortcuts() {
        let command = Int(NSEvent.ModifierFlags.command.rawValue)
        let shift = Int(NSEvent.ModifierFlags.shift.rawValue)

        #expect(InputSample.key(t: 1, modifiers: 0).isTyping)
        #expect(InputSample.key(t: 1, modifiers: shift).isTyping, "shift is still typing")
        #expect(!InputSample.key(t: 1, modifiers: command).isTyping, "⌘S is operating the app")
        #expect(!InputSample.scroll(t: 1, dx: 0, dy: 1).isTyping)
    }

    // MARK: - Targets and mapping

    @Test func aRequestTargetBecomesACaptureTarget() {
        #expect(CaptureTarget(RecordingRequest.Target.display(3)) == .display(3))
        #expect(CaptureTarget(RecordingRequest.Target.window(9)) == .window(9))
        #expect(CaptureTarget(RecordingRequest.Target.ask) == nil, "\"ask me\" is the add-on's job, not a target")
    }

    /// The pointer is recorded in the frame's space, so the editor can draw it without
    /// knowing which display the recording came from.
    @Test func pointerPositionsAreRelativeToWhatWasRecorded() {
        let mapper = CursorMapper(origin: CGPoint(x: 100, y: 50))
        #expect(mapper.map(CGPoint(x: 140, y: 90)) == CGPoint(x: 40, y: 40))
        #expect(mapper.map(CGPoint(x: 90, y: 40)) == CGPoint(x: -10, y: -10),
                "a pointer outside the recorded area is kept, not clamped: the editor decides")
    }
}
