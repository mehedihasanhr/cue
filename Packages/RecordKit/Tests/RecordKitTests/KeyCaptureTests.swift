import AppKit
import CoreMedia
import Foundation
import os
import Testing
@testable import RecordKit

/// A keyboard that is not there.
///
/// Stands in for the grant, the global monitor and the layout, so a tracker can be fed
/// presses and read back without a person at the Mac — and so no test ever installs a
/// real key monitor, which on a trusted machine would be reading whoever is typing.
private final class FakeKeyboard: @unchecked Sendable {
    struct State {
        var trusted = true
        var handler: (@MainActor @Sendable (KeyEvent) -> Void)?
        var watching = 0
        var stopped = 0
        var labels: [UInt16: String] = [:]
        var asked: [UInt16] = []
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    init(trusted: Bool = true, labels: [UInt16: String] = [:]) {
        state.withLock {
            $0.trusted = trusted
            $0.labels = labels
        }
    }

    var environment: KeyTracker.Environment {
        KeyTracker.Environment(
            isTrusted: { [state] in state.withLock { $0.trusted } },
            watch: { [state] handler in
                state.withLock {
                    $0.handler = handler
                    $0.watching += 1
                }
                return NSObject()
            },
            unwatch: { [state] _ in
                state.withLock {
                    $0.handler = nil
                    $0.stopped += 1
                }
            },
            label: { [state] keyCode in
                state.withLock {
                    $0.asked.append(keyCode)
                    return $0.labels[keyCode]
                }
            })
    }

    @MainActor
    func press(_ event: KeyEvent) {
        state.withLock { $0.handler }?(event)
    }

    var isWatching: Bool { state.withLock { $0.handler != nil } }
    var timesAsked: Int { state.withLock { $0.asked.count } }
}

/// What a recording may say about the keyboard, and what it must never say.
@MainActor
struct KeyCaptureTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 1_000_000_000)
    }

    private func temporaryFolder() -> URL {
        let url = URL.temporaryDirectory.appending(path: "KeyCaptureTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A tracker writing to a file, with a clock that started at host second 1000.
    private func tracker(_ keyboard: FakeKeyboard,
                         in folder: URL,
                         latency: Double = 0) -> (KeyTracker, JSONLWriter, DispatchQueue, RecordingClock) {
        let queue = DispatchQueue(label: "test.keys.\(UUID().uuidString)")
        let writer = JSONLWriter(url: folder.appendingPathComponent("input.jsonl"), queue: queue)
        queue.sync { try? writer.open() }
        let clock = RecordingClock()
        clock.start(at: seconds(1_000))
        let tracker = KeyTracker(writer: writer, queue: queue, clock: clock,
                                 latency: latency, environment: keyboard.environment)
        return (tracker, writer, queue, clock)
    }

    private func lines(of writer: JSONLWriter, on queue: DispatchQueue) throws -> [String] {
        queue.sync { _ = writer.close() }
        guard FileManager.default.fileExists(atPath: writer.url.path(percentEncoded: false)) else { return [] }
        return try String(contentsOf: writer.url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// A sentence as the key presses that type it on a US keyboard: shift held for a
    /// capital, one press every tenth of a second from `from`.
    private func typed(_ sentence: String, from start: Double) -> [KeyEvent] {
        var t = start
        return sentence.compactMap { character in
            defer { t += 0.1 }
            if character == " " { return KeyEvent(timestamp: t, keyCode: 49, modifiers: []) }
            guard let code = KeyLabels.unitedStatesKeyCode(for: character) else { return nil }
            return KeyEvent(timestamp: t, keyCode: code, modifiers: character.isUppercase ? [.shift] : [])
        }
    }

    // MARK: - The privacy rule

    /// The rule, key by key: a name only with ⌘ or ⌃ held or for a key on the list.
    @Test func onlyShortcutsAndNamedKeysMayBeNamed() {
        let k: UInt16 = 40
        #expect(KeyRecorder.mayBeNamed(keyCode: k, modifiers: [.command]))
        #expect(KeyRecorder.mayBeNamed(keyCode: k, modifiers: [.control]))
        #expect(KeyRecorder.mayBeNamed(keyCode: k, modifiers: [.command, .option]))
        #expect(!KeyRecorder.mayBeNamed(keyCode: k, modifiers: [.option]),
                "⌥ with a letter is how @ and brackets are typed on most keyboards")
        #expect(!KeyRecorder.mayBeNamed(keyCode: k, modifiers: [.option, .shift]))
        #expect(KeyRecorder.mayBeNamed(keyCode: 123, modifiers: [.option]), "⌥← is a named key, so it is named")
        #expect(KeyRecorder.mayBeNamed(keyCode: k, modifiers: [.command, .shift]))
        #expect(!KeyRecorder.mayBeNamed(keyCode: k, modifiers: []), "a letter")
        #expect(!KeyRecorder.mayBeNamed(keyCode: k, modifiers: [.shift]), "a capital letter is still typing")
        #expect(!KeyRecorder.mayBeNamed(keyCode: 49, modifiers: []), "the space bar")
        #expect(!KeyRecorder.mayBeNamed(keyCode: 18, modifiers: [.shift]), "a shifted digit")
        for named in NamedKey.allCases {
            #expect(KeyRecorder.mayBeNamed(keyCode: named.keyCode, modifiers: []), "\(named.rawValue) on its own")
            #expect(KeyRecorder.mayBeNamed(keyCode: named.keyCode, modifiers: [.shift]), "⇧\(named.rawValue)")
        }
    }

    /// A sentence typed during a take — capitals and all — leaves nothing of itself in
    /// the file: no key, no character, no modifier, and the layout was never even asked
    /// what the keys said.
    @Test func aTypedSentenceLeavesNoCharactersInTheTelemetry() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let keyboard = FakeKeyboard(labels: Dictionary(uniqueKeysWithValues: KeyLabels.unitedStates.map { ($0.key, $0.value) }))
        let (tracker, writer, queue, _) = tracker(keyboard, in: folder)
        tracker.start()

        let sentence = "The Quick brown fox says Hunter2 is My PASSWORD"
        let presses = typed(sentence, from: 1_002)
        #expect(presses.count == sentence.count, "every character became a press")
        for press in presses {
            tracker.record(press, now: seconds(press.timestamp + 0.01))
        }
        tracker.stop()

        let written = try lines(of: writer, on: queue)
        #expect(written.count == presses.count)
        // The exact shape of every line: a time and a zero, and not one thing more.
        let shape = try NSRegularExpression(pattern: #"^\{"key":\{"modifiers":0,"t":[0-9]+(\.[0-9]+)?\}\}$"#)
        for line in written {
            #expect(shape.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil, Comment(rawValue: line))
        }
        #expect(keyboard.timesAsked == 0, "the layout is never asked about a typed key")
        let decoded = written.map { try? JSONDecoder().decode(InputSample.self, from: Data($0.utf8)) }
        #expect(decoded.allSatisfy { if case .key(_, 0) = $0 { true } else { false } })
    }

    /// The strongest form of the rule: two different sentences typed to the same rhythm
    /// produce byte-for-byte the same file. The file is a function of *when*, and of
    /// nothing else.
    @Test func whatWasTypedMakesNoDifferenceToTheBytes() throws {
        func bytes(_ sentence: String) throws -> Data {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let keyboard = FakeKeyboard(labels: KeyLabels.unitedStates)
            let (tracker, writer, queue, _) = tracker(keyboard, in: folder)
            tracker.start()
            for press in typed(sentence, from: 1_001) {
                tracker.record(press, now: seconds(press.timestamp + 0.02))
            }
            tracker.stop()
            queue.sync { _ = writer.close() }
            return try Data(contentsOf: writer.url)
        }
        let one = try bytes("correct horse battery staple")
        let other = try bytes("Tr0ub4dor and three and NOPE")
        #expect(typed("correct horse battery staple", from: 0).count
                == typed("Tr0ub4dor and three and NOPE", from: 0).count, "the same rhythm")
        #expect(!one.isEmpty)
        #expect(one == other)
    }

    // MARK: - What is named

    private let ask: (UInt16) -> String? = { KeyLabels.label(forKeyCode: $0, layout: { _ in nil }) }

    @Test func aShortcutIsNamedWithWhatWasHeld() {
        let press = KeyEvent(timestamp: 5, keyCode: 40, modifiers: [.command, .shift])
        #expect(KeyRecorder.sample(for: press, at: 5, label: ask)
                == .shortcut(t: 5, modifiers: [.command, .shift], key: "K"))
        let control = KeyEvent(timestamp: 5, keyCode: 0, modifiers: [.control])
        #expect(KeyRecorder.sample(for: control, at: 5, label: ask)
                == .shortcut(t: 5, modifiers: [.control], key: "A"))
        let option = KeyEvent(timestamp: 5, keyCode: 49, modifiers: [.option, .command])
        #expect(KeyRecorder.sample(for: option, at: 5, label: ask)
                == .shortcut(t: 5, modifiers: [.option, .command], key: "Space"), "the space bar has a name once it is a shortcut")
        let typedAt = KeyEvent(timestamp: 5, keyCode: 37, modifiers: [.option])
        #expect(KeyRecorder.sample(for: typedAt, at: 5, label: ask) == .key(t: 5, modifiers: 0),
                "⌥L types @ on a German keyboard, and nothing of it is kept")
    }

    @Test func aNamedKeyOnItsOwnIsNamed() {
        let enter = KeyEvent(timestamp: 5, keyCode: NamedKey.return.keyCode, modifiers: [])
        #expect(KeyRecorder.sample(for: enter, at: 5, label: ask)
                == .shortcut(t: 5, modifiers: [], key: "Return"))
        let shiftedTab = KeyEvent(timestamp: 5, keyCode: NamedKey.tab.keyCode, modifiers: [.shift])
        #expect(KeyRecorder.sample(for: shiftedTab, at: 5, label: ask)
                == .shortcut(t: 5, modifiers: [.shift], key: "Tab"))
        let function = KeyEvent(timestamp: 5, keyCode: NamedKey.f5.keyCode, modifiers: [])
        #expect(KeyRecorder.sample(for: function, at: 5, label: ask)
                == .shortcut(t: 5, modifiers: [], key: "F5"))
    }

    @Test func aHeldKeyIsOnePress() {
        let held = KeyEvent(timestamp: 5, keyCode: 40, modifiers: [.command], isRepeat: true)
        #expect(KeyRecorder.sample(for: held, at: 5, label: ask) == nil)
        let heldLetter = KeyEvent(timestamp: 5, keyCode: 40, modifiers: [], isRepeat: true)
        #expect(KeyRecorder.sample(for: heldLetter, at: 5, label: ask) == nil)
    }

    /// A shortcut on a key nobody can name is still a press — just not a named one.
    @Test func aKeyWithNoNameIsWrittenAsAPress() {
        let odd = KeyEvent(timestamp: 5, keyCode: 200, modifiers: [.command])
        #expect(KeyRecorder.sample(for: odd, at: 5, label: ask) == .key(t: 5, modifiers: 0))
    }

    // MARK: - The label

    @Test func theLayoutsOwnLegendComesFirst() {
        // A French keyboard prints A where an American one prints Q.
        let french: (UInt16) -> String? = { $0 == 12 ? "a" : nil }
        #expect(KeyLabels.label(forKeyCode: 12, layout: french) == "A", "capitalised the way the cap is")
        #expect(KeyLabels.label(forKeyCode: 12, layout: { _ in nil }) == "Q", "the US name when the layout has none")
        #expect(KeyLabels.label(forKeyCode: 43, layout: { _ in "," }) == ",")
    }

    @Test func namedKeysAndTheSpaceBarIgnoreTheLayout() {
        let noisy: (UInt16) -> String? = { _ in "\r" }
        #expect(KeyLabels.label(forKeyCode: NamedKey.return.keyCode, layout: noisy) == "Return")
        #expect(KeyLabels.label(forKeyCode: 49, layout: { _ in " " }) == "Space")
    }

    /// A control character or a blank is not a legend, whatever the layout says.
    @Test func aLayoutAnswerThatCannotBePrintedIsNotALabel() {
        #expect(KeyLabels.legible("\u{08}") == nil)
        #expect(KeyLabels.legible(" ") == nil)
        #expect(KeyLabels.legible("") == nil)
        #expect(KeyLabels.legible("ab") == nil, "two characters is not one key")
        #expect(KeyLabels.legible("é") == "É")
        #expect(KeyLabels.legible("§") == "§")
    }

    @Test func theUnitedStatesTableCoversEveryLetterAndDigit() {
        for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            #expect(KeyLabels.unitedStatesKeyCode(for: character) != nil, "\(character)")
        }
    }

    @Test func namedKeysAreFoundByAnySpelling() {
        #expect(NamedKey(name: "return") == .return)
        #expect(NamedKey(name: "Page Up") == .pageUp)
        #expect(NamedKey(name: "pageup") == .pageUp)
        #expect(NamedKey(name: "esc") == .escape)
        #expect(NamedKey(name: "backspace") == .delete)
        #expect(NamedKey(name: "⌫") == .delete)
        #expect(NamedKey(name: "f12") == .f12)
        #expect(NamedKey(name: "k") == nil)
        #expect(NamedKey(keyCode: 36) == .return)
        #expect(NamedKey(keyCode: 40) == nil)
    }

    // MARK: - On disk

    @Test func modifiersAreWrittenAsNamesInMenuOrder() throws {
        let data = try JSONEncoder().encode(KeyModifiers([.command, .shift, .control]))
        #expect(String(decoding: data, as: UTF8.self) == #"["control","shift","command"]"#)
        #expect(try JSONDecoder().decode(KeyModifiers.self, from: data) == [.command, .shift, .control])
        #expect(KeyModifiers([.command, .shift, .control]).symbols == ["⌃", "⇧", "⌘"])
    }

    @Test func aModifierThisBuildDoesNotKnowIsSkipped() throws {
        let decoded = try JSONDecoder().decode(KeyModifiers.self, from: Data(#"["command","hyper"]"#.utf8))
        #expect(decoded == [.command])
    }

    @Test func aShortcutRoundTripsAndOldLinesStillRead() throws {
        let sample = InputSample.shortcut(t: 2.5, modifiers: [.command], key: "K")
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(InputSample.self, from: data) == sample)
        // A line a newer build wrote, with a field this one has never heard of.
        let newer = Data(#"{"shortcut":{"t":1,"modifiers":["option"],"key":"F","held":true}}"#.utf8)
        #expect(try JSONDecoder().decode(InputSample.self, from: newer)
                == .shortcut(t: 1, modifiers: [.option], key: "F"))
        let old = Data(#"{"key":{"t":2.5,"modifiers":0}}"#.utf8)
        #expect(try JSONDecoder().decode(InputSample.self, from: old) == .key(t: 2.5, modifiers: 0))
    }

    @Test func theManifestSaysWhetherKeysWereWatched() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let watched = try encoder.encode(RecordingManifest.Telemetry(keys: .recorded))
        #expect(try decoder.decode(RecordingManifest.Telemetry.self, from: watched).keys == .recorded)
        let refused = try encoder.encode(RecordingManifest.Telemetry(keys: .notPermitted))
        #expect(try decoder.decode(RecordingManifest.Telemetry.self, from: refused).keys == .notPermitted)
        // Absent — every recording made before the field existed — is "not asked for".
        let older = Data(#"{"cursor":"telemetry/cursor.jsonl"}"#.utf8)
        #expect(try decoder.decode(RecordingManifest.Telemetry.self, from: older).keys == nil)
        // A value from a newer build is a name this one does not know, not a manifest
        // that will not open.
        let newer = Data(#"{"keys":"partly"}"#.utf8)
        #expect(try decoder.decode(RecordingManifest.Telemetry.self, from: newer).keys == KeyCapture(rawValue: "partly"))
    }

    // MARK: - The tracker

    @Test func withoutTheGrantNothingIsWatchedAndTheManifestSaysSo() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let keyboard = FakeKeyboard(trusted: false)
        let (tracker, writer, queue, _) = tracker(keyboard, in: folder)
        #expect(tracker.start() == .notPermitted)
        #expect(!keyboard.isWatching, "no monitor is installed without the grant")
        keyboard.press(KeyEvent(timestamp: 1_002, keyCode: 40, modifiers: [.command]))
        tracker.stop()
        #expect(tracker.capture == .notPermitted)
        #expect(try lines(of: writer, on: queue).isEmpty)
    }

    @Test func withTheGrantAShortcutIsWrittenOnTheRecordingsClock() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let keyboard = FakeKeyboard(labels: [40: "k"])
        let (tracker, writer, queue, _) = tracker(keyboard, in: folder)
        #expect(tracker.start() == .recorded)
        #expect(keyboard.isWatching)
        tracker.record(KeyEvent(timestamp: 1_002.5, keyCode: 40, modifiers: [.command]),
                       now: seconds(1_002.52))
        tracker.stop()
        #expect(!keyboard.isWatching, "stopping takes the monitor down")
        #expect(tracker.capture == .recorded)

        let written = try lines(of: writer, on: queue)
        #expect(written.count == 1)
        let sample = try JSONDecoder().decode(InputSample.self, from: Data(try #require(written.first).utf8))
        #expect(sample == .shortcut(t: 2.5, modifiers: [.command], key: "K"))
    }

    /// The same nudge a click gets, so a ⌘-click and its click are stamped alike.
    @Test func thePointersLatencyIsAddedToAKeyPressToo() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (tracker, writer, queue, _) = tracker(FakeKeyboard(labels: [40: "k"]), in: folder, latency: 0.01)
        tracker.start()
        tracker.record(KeyEvent(timestamp: 1_002, keyCode: 40, modifiers: [.command]), now: seconds(1_002.01))
        tracker.stop()
        let written = try lines(of: writer, on: queue)
        let sample = try JSONDecoder().decode(InputSample.self, from: Data(try #require(written.first).utf8))
        #expect(abs(sample.t - 2.01) < 0.000_01)
    }

    /// A press made during a pause has no place in the recording, and is not given one.
    @Test func aPressInsideAHoldIsDropped() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (tracker, writer, queue, clock) = tracker(FakeKeyboard(labels: [40: "k"]), in: folder)
        tracker.start()
        clock.hold(at: seconds(1_004))
        tracker.record(KeyEvent(timestamp: 1_005, keyCode: 40, modifiers: [.command]), now: seconds(1_005.01))
        clock.release(at: seconds(1_006))
        // Told about late, after the hold — the callback runs when the main thread gets
        // to it — and still dropped, because it *happened* inside the hold.
        tracker.record(KeyEvent(timestamp: 1_005.5, keyCode: 40, modifiers: [.command]), now: seconds(1_006.2))
        // After the hold: two seconds of hold come off, so host 1007 is recording 5.
        tracker.record(KeyEvent(timestamp: 1_007, keyCode: 40, modifiers: [.command]), now: seconds(1_007.01))
        tracker.stop()

        let written = try lines(of: writer, on: queue)
        #expect(written.count == 1)
        let sample = try JSONDecoder().decode(InputSample.self, from: Data(try #require(written.first).utf8))
        #expect(abs(sample.t - 5) < 0.000_01)
    }

    @Test func aPressBeforeTheFirstFrameIsDropped() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (tracker, writer, queue, _) = tracker(FakeKeyboard(labels: [40: "k"]), in: folder)
        tracker.start()
        tracker.record(KeyEvent(timestamp: 999.5, keyCode: 40, modifiers: [.command]), now: seconds(999.51))
        tracker.stop()
        #expect(try lines(of: writer, on: queue).isEmpty)
    }

    @Test func aMomentHasAPlaceInTheRecordingOrItDoesNot() {
        let clock = RecordingClock()
        #expect(clock.moment(forHost: seconds(5)) == nil, "before the clock starts")
        clock.start(at: seconds(1_000))
        #expect(clock.moment(forHost: seconds(999)) == nil, "before the first frame")
        #expect(clock.moment(forHost: seconds(1_003)) == 3)
        clock.hold(at: seconds(1_004))
        #expect(clock.moment(forHost: seconds(1_005)) == nil, "inside a hold")
        clock.release(at: seconds(1_006))
        #expect(clock.moment(forHost: seconds(1_005)) == nil, "held then, even though not now")
        #expect(clock.moment(forHost: seconds(1_007)).map { abs($0 - 5) < 0.000_01 } == true)
    }

    /// Starting again after a pause does not install a second monitor.
    @Test func startingTwiceWatchesOnce() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let keyboard = FakeKeyboard()
        let (tracker, _, _, _) = tracker(keyboard, in: folder)
        tracker.start()
        tracker.start()
        #expect(keyboard.state.withLock { $0.watching } == 1)
        tracker.stop()
        tracker.start()
        #expect(keyboard.state.withLock { $0.watching } == 2)
        tracker.stop()
    }

    /// The real layout, asked on the main actor the way the monitor asks it. Whatever
    /// this Mac's layout is, the letter keys print *something* — the value is not
    /// asserted, because the test must not depend on the machine.
    @Test func theRealLayoutAnswersForLetterKeys() {
        let printed = KeyboardLayout.character(forKeyCode: 0)
        #expect(printed == nil || !printed!.isEmpty)
    }
}
