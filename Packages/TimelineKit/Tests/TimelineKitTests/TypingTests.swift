import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Typing, read off the presses the recorder is allowed to write.
struct TypingTests {
    private func presses(from start: Double, count: Int, every gap: Double = 0.2) -> [InputSample] {
        (0..<count).map { .key(t: start + Double($0) * gap, modifiers: 0) }
    }

    @Test func aRunOfPressesIsABurst() {
        let bursts = Typing.bursts(in: presses(from: 10, count: 8))
        #expect(bursts.count == 1)
        #expect(bursts[0].start == 10)
        #expect(abs(bursts[0].end - 11.4) < 0.0001)
        #expect(bursts[0].presses == 8)
    }

    @Test func aPauseSplitsTwoBursts() {
        let bursts = Typing.bursts(in: presses(from: 10, count: 5) + presses(from: 14, count: 5))
        #expect(bursts.count == 2)
        #expect(bursts[1].start == 14)
    }

    @Test func aFewPressesAreNotTyping() {
        #expect(Typing.bursts(in: presses(from: 10, count: 3)).isEmpty)
        #expect(Typing.bursts(in: presses(from: 10, count: 4)).count == 1)
        #expect(Typing.bursts(in: presses(from: 10, count: 3), minimumPresses: 2).count == 1)
    }

    /// The other half of the privacy rule, read back: a shortcut is somebody operating
    /// the app, and never counts as writing in it.
    @Test func shortcutsAreNotTyping() {
        let shortcuts: [InputSample] = (0..<8).map { .shortcut(t: 10 + Double($0) * 0.2, modifiers: [.command], key: "Z") }
        #expect(Typing.bursts(in: shortcuts).isEmpty)
        #expect(Typing.bursts(in: presses(from: 10, count: 8) + shortcuts).count == 1)
    }

    /// Deleting a word and typing it again is one stretch of typing, not two.
    @Test func deleteKeepsABurstGoingButNeverStartsOne() {
        let deletes: [InputSample] = (0..<8).map { .shortcut(t: 11 + Double($0) * 0.3, modifiers: [], key: "Delete") }
        let joined = Typing.bursts(in: presses(from: 10, count: 5) + deletes + presses(from: 14, count: 5))
        #expect(joined.count == 1, "two seconds of deleting between them is still typing")
        #expect(joined[0].presses == 10, "the deletes do not count")
        #expect(Typing.bursts(in: deletes).isEmpty, "deleting on its own is not typing")
        let arrows: [InputSample] = (0..<8).map { .shortcut(t: 20 + Double($0) * 0.3, modifiers: [], key: "Down") }
        #expect(Typing.bursts(in: arrows).isEmpty, "stepping through a list is not typing")
    }

    @Test func anEditingKeyWithAModifierIsAShortcut() {
        let all: [InputSample] = presses(from: 10, count: 5)
            + [.shortcut(t: 11.2, modifiers: [.option], key: "Delete")]
            + presses(from: 13, count: 5)
        #expect(Typing.bursts(in: all).count == 2, "⌥⌫ is a shortcut, so the gap stands")
    }

    /// What was typed after tabbing into the next field was typed into *that* field.
    @Test func aBurstNeverCrossesAChangeOfFocus() {
        let continuous = presses(from: 10, count: 20)   // 10.0 … 13.8
        let split = Typing.bursts(in: continuous, splitAt: [12.05])
        #expect(split.count == 2)
        #expect(split[0].end == 12)
        #expect(abs(split[1].start - 12.2) < 0.0001)
        #expect(Typing.bursts(in: continuous, splitAt: [9, 20]).count == 1, "a change outside the run is nothing")
    }

    @Test func burstsAreInOrderAndNoneTouch() {
        let bursts = Typing.bursts(in: presses(from: 30, count: 5) + presses(from: 10, count: 5))
        #expect(bursts.map(\.start) == [10, 30])
        #expect(bursts[0].end < bursts[1].start)
    }
}

/// The suggester fed the telemetry a real take produces: anonymous presses, named keys,
/// shortcuts and focus, all through the files the recorder writes.
@MainActor
struct TypingZoomTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let frame = CGSize(width: 1_000, height: 1_000)

    private func field(_ t: Double, _ rect: CGRect = CGRect(x: 300, y: 200, width: 400, height: 24)) -> FocusSample {
        FocusSample(t: t, kind: .field, rect: rect)
    }

    private func typing(from start: Double, count: Int, every gap: Double = 0.25) -> [InputSample] {
        (0..<count).map { .key(t: start + Double($0) * gap, modifiers: 0) }
    }

    /// A take as the recorder writes it: `input.jsonl` and `focus.jsonl` in a package
    /// with a manifest that names them, read back through `EditorDocument`.
    private func package(input: [InputSample], focus: [FocusSample], keys: KeyCapture? = .recorded,
                         seconds: Double = 60) throws -> (EditorDocument, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypingZoomTests-\(UUID().uuidString)", isDirectory: true)
        let package = try RecordingPackage.create(named: "Take", in: folder)
        let queue = DispatchQueue(label: "test.telemetry.typing")
        let inputWriter = JSONLWriter(url: package.telemetryFolder.appendingPathComponent("input.jsonl"), queue: queue)
        let focusWriter = JSONLWriter(url: package.telemetryFolder.appendingPathComponent("focus.jsonl"), queue: queue)
        queue.sync {
            try? inputWriter.open()
            for sample in input { inputWriter.append(sample) }
            _ = inputWriter.close()
            try? focusWriter.open()
            for sample in focus { focusWriter.append(sample) }
            _ = focusWriter.close()
        }
        let manifest = RecordingManifest(name: "Take", duration: seconds, displayScale: 1,
                                         telemetry: .init(cursor: nil,
                                                          input: input.isEmpty ? nil : "telemetry/input.jsonl",
                                                          focus: focus.isEmpty ? nil : "telemetry/focus.jsonl",
                                                          keys: keys))
        try package.write(manifest)
        return (try EditorDocument(package: package), folder)
    }

    private func suggestions(_ document: EditorDocument) -> [ZoomRegion] {
        ZoomSuggester(frameSize: frame)
            .suggestions(cursor: [], input: document.inputSamples,
                         focus: document.focusSamples, duration: document.timeline.duration)
    }

    /// Click into a field, type for eight seconds, press Return: one zoom onto the
    /// field, held until the typing stops, and no key on screen for the letters.
    @Test func typingIntoAFieldHoldsTheCameraOnIt() throws {
        var input: [InputSample] = [.mouseDown(t: 9.95, button: 0, x: 500, y: 212)]
        input += typing(from: 10.5, count: 30)                                // 10.5 … 17.75
        input.append(.shortcut(t: 18, modifiers: [], key: "Return"))
        let (document, folder) = try package(input: input, focus: [field(10)])
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(document.inputSamples.count == 32, "every line of the sidecar read back")
        let zooms = suggestions(document)
        #expect(zooms.count == 1)
        let zoom = try #require(zooms.first)
        #expect(zoom.source == .typing)
        #expect(zoom.start.seconds < 10)
        #expect(zoom.end.seconds > 18, "held until the typing stopped, and a little after")
        #expect(zoom.end.seconds < 22)
        #expect(!zoom.followsCursor)
        // Nothing typed became a key cue; the Return did, and it stays off screen by
        // default.
        let cues = document.recordedKeyCues()
        #expect(cues.map(\.key) == ["Return"])
        #expect(document.timeline.keyCue(at: time(18.5)) == nil)
    }

    /// Tab between two fields while typing: the camera moves to the second field with
    /// the typing, rather than staying on the first for as long as the typing lasts.
    @Test func typingFollowsFocusFromOneFieldToTheNext() throws {
        let first = CGRect(x: 100, y: 100, width: 300, height: 24)
        let second = CGRect(x: 100, y: 700, width: 300, height: 24)
        var input = typing(from: 10.5, count: 12)                              // 10.5 … 13.25
        input.append(.shortcut(t: 13.5, modifiers: [], key: "Tab"))
        input += typing(from: 13.8, count: 16)                                 // 13.8 … 17.55
        let (document, folder) = try package(input: input, focus: [field(10, first), field(13.55, second)])
        defer { try? FileManager.default.removeItem(at: folder) }

        let zooms = suggestions(document)
        #expect(zooms.count == 2)
        #expect(zooms[0].source == .typing)
        #expect(zooms[0].end.seconds <= 13.55, "the first field lets go when the second takes the caret")
        #expect(zooms[1].source == .typing, "the typing after the tab belongs to the second field")
        #expect(zooms[1].center.y > zooms[0].center.y)
        #expect(zooms[1].end.seconds > 17.5)
    }

    /// Switching to another app ends the field's hold, even though the other app is not
    /// somewhere to zoom to.
    @Test func anotherAppComingForwardEndsTheFieldsHold() throws {
        let input = typing(from: 10.5, count: 10) + typing(from: 14.5, count: 20)   // the second run is in the other app
        let focus = [field(10),
                     FocusSample(t: 14, kind: .application, rect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000), app: "com.example.other")]
        let (document, folder) = try package(input: input, focus: focus)
        defer { try? FileManager.default.removeItem(at: folder) }

        let zooms = suggestions(document)
        #expect(zooms.count == 1)
        #expect(zooms[0].end.seconds <= 14, "not held on an empty field while typing goes on elsewhere")
    }

    /// The recorder's own output, end to end: presses that were shortcuts become cues,
    /// presses that were typing become a zoom, and neither knows about the other.
    @Test func shortcutsAndTypingAreReadFromTheSameFile() throws {
        var input: [InputSample] = [.shortcut(t: 5, modifiers: [.command], key: "K")]
        input += typing(from: 10.5, count: 20)
        input += [.shortcut(t: 20, modifiers: [.command], key: "S")]
        let (document, folder) = try package(input: input, focus: [field(10)])
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(document.recordedKeyCues().map(\.title) == ["⌘K", "⌘S"])
        let zooms = suggestions(document)
        #expect(zooms.count == 1)
        #expect(zooms[0].source == .typing)
    }

    // MARK: - Opening a recording

    @Test func theRecordedPressesAreABaselineNotAnEdit() throws {
        let input: [InputSample] = [.shortcut(t: 5, modifiers: [.command], key: "K"),
                                    .shortcut(t: 8, modifiers: [.command], key: "Z"),
                                    .shortcut(t: 8.3, modifiers: [.command], key: "Z")]
        let (document, folder) = try package(input: input, focus: [])
        defer { try? FileManager.default.removeItem(at: folder) }

        document.adoptRecordedKeys()
        #expect(document.timeline.keyCues.map(\.title) == ["⌘K", "⌘Z ×2"])
        #expect(!document.isDirty, "a recording that has only been opened has no unsaved changes")
        #expect(!document.canUndo)
        #expect(document.manifest.telemetry.keys == .recorded)
    }

    @Test func aRecordingWithNoPressesOpensWithAnEmptyLane() throws {
        let (document, folder) = try package(input: [.mouseDown(t: 1, button: 0, x: 1, y: 1)], focus: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        document.adoptRecordedKeys()
        #expect(document.timeline.keyCues.isEmpty)
        #expect(!document.isDirty)
    }

    /// A project that was saved is a project whose lane is what its owner left it.
    @Test func anEditedProjectIsNotGivenItsPressesBack() throws {
        let input: [InputSample] = [.shortcut(t: 5, modifiers: [.command], key: "K")]
        let (document, folder) = try package(input: input, focus: [])
        defer { try? FileManager.default.removeItem(at: folder) }

        document.adoptRecordedKeys()
        #expect(document.timeline.keyCues.count == 1)
        document.apply(Commands.SetKeyCues([], name: "Remove All Shortcuts"))
        try document.save()

        let reopened = try EditorDocument(package: document.package)
        reopened.adoptRecordedKeys()
        #expect(reopened.timeline.keyCues.isEmpty, "taken out on purpose, and not put back")
        #expect(reopened.recordedKeyCues().count == 1, "though they can be asked for")
    }
}
