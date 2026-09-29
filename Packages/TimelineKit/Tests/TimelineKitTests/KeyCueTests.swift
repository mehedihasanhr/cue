import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// A key press as a region: what it says, how it is read back, and how it behaves on the
/// lane beside every other kind of region.
struct KeyCueTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline(seconds: Double = 60) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    // MARK: - What it says

    @Test func aShortcutIsWrittenTheWayAMenuWritesIt() {
        let cue = KeyCue(start: time(1), modifiers: [.shift, .command], key: "K")
        #expect(cue.caps == ["⇧", "⌘", "K"])
        #expect(cue.title == "⇧⌘K")
        #expect(KeyCue(start: time(1), modifiers: [.command], key: "Z", count: 3).title == "⌘Z ×3")
        #expect(KeyCue(start: time(1), modifiers: [.control, .option, .command], key: "Space").title == "⌃⌥⌘Space")
    }

    @Test func aNamedKeyIsDrawnAsItsSymbol() {
        #expect(KeyCue(start: .zero, key: "Return").caps == ["⏎"])
        #expect(KeyCue(start: .zero, modifiers: [.command], key: "Left").title == "⌘←")
        #expect(KeyCue(start: .zero, key: "F5").title == "F5")
        #expect(KeyCue(start: .zero, key: "esc").namedKey == .escape, "read by any spelling")
    }

    @Test func aNamedKeyOnItsOwnIsKnownAsSuch() {
        #expect(KeyCue(start: .zero, key: "Return").isNamedKeyAlone)
        #expect(KeyCue(start: .zero, modifiers: [.shift], key: "Tab").isNamedKeyAlone, "shift does not make it a shortcut")
        #expect(!KeyCue(start: .zero, modifiers: [.command], key: "Return").isNamedKeyAlone)
        #expect(!KeyCue(start: .zero, key: "K").isNamedKeyAlone, "a letter is not a named key")
        #expect(KeyCue(start: .zero, key: "").isEmpty)
        #expect(!KeyCue(start: .zero, modifiers: [.command], key: "").isEmpty, "a modifier alone is still something to draw")
    }

    @Test func theCountIsAtLeastOneAndTheKeyIsTrimmed() {
        let cue = KeyCue(start: .zero, key: "  K ", count: 0)
        #expect(cue.key == "K")
        #expect(cue.count == 1)
    }

    // MARK: - Typed in

    @Test func keysTypedAsSymbolsAreRead() throws {
        let read = try #require(KeyCue.parse("⌘⇧K"))
        #expect(read.modifiers == [.command, .shift])
        #expect(read.key == "K")
        #expect(read.count == 1)
    }

    @Test func keysTypedAsWordsAreRead() throws {
        let read = try #require(KeyCue.parse("cmd shift k"))
        #expect(read.modifiers == [.command, .shift])
        #expect(read.key == "K")
        let dashed = try #require(KeyCue.parse("ctrl-alt-delete"))
        #expect(dashed.modifiers == [.control, .option])
        #expect(dashed.key == "Delete")
        let plussed = try #require(KeyCue.parse("Option+Command+Esc"))
        #expect(plussed.modifiers == [.option, .command])
        #expect(plussed.key == "Escape")
    }

    @Test func aCountIsReadFromTheEnd() throws {
        #expect(try #require(KeyCue.parse("⌘Z ×3")).count == 3)
        #expect(try #require(KeyCue.parse("cmd z x3")).count == 3)
        #expect(try #require(KeyCue.parse("⌘Z x 12")).count == 12)
        // ⌘X is a shortcut, not a count.
        let cut = try #require(KeyCue.parse("⌘X"))
        #expect(cut.key == "X")
        #expect(cut.count == 1)
    }

    @Test func aKeyThatIsASeparatorIsStillAKey() throws {
        #expect(try #require(KeyCue.parse("⌘-")).key == "-")
        #expect(try #require(KeyCue.parse("cmd +")).key == "+")
        #expect(try #require(KeyCue.parse("⌘+")).key == "+")
    }

    @Test func namedKeysAndLettersAreStoredCanonically() throws {
        #expect(try #require(KeyCue.parse("page up")).key == "Page Up")
        #expect(try #require(KeyCue.parse("k")).key == "K")
        #expect(try #require(KeyCue.parse("⌘ space")).key == "Space")
        #expect(try #require(KeyCue.parse("←")).key == "Left")
        #expect(try #require(KeyCue.parse("⌘ 1")).key == "1")
    }

    @Test func nothingTypedIsNothing() {
        #expect(KeyCue.parse("") == nil)
        #expect(KeyCue.parse("   ") == nil)
        #expect(KeyCue.parse("+") != nil, "a plus on its own is the plus key")
    }

    /// Whatever the title says can be typed straight back in and mean the same thing.
    @Test(arguments: [
        KeyCue(start: .zero, modifiers: [.command, .shift], key: "K"),
        KeyCue(start: .zero, modifiers: [.command], key: "Z", count: 3),
        KeyCue(start: .zero, key: "Return"),
        KeyCue(start: .zero, modifiers: [.control, .option], key: "Delete"),
        KeyCue(start: .zero, modifiers: [.command], key: "Space"),
        KeyCue(start: .zero, modifiers: [.command], key: "-"),
        KeyCue(start: .zero, modifiers: [.option, .command], key: "Left", count: 2),
    ])
    func theTitleRoundTripsThroughParsing(_ cue: KeyCue) throws {
        let read = try #require(KeyCue.parse(cue.title))
        #expect(read.modifiers == cue.modifiers)
        #expect(read.key == cue.key)
        #expect(read.count == cue.count)
    }

    // MARK: - On the timeline

    @Test func theLaterPressWinsWhereTwoOverlap() {
        var timeline = timeline()
        let first = KeyCue(start: time(1), duration: time(1.2), modifiers: [.command], key: "C")
        let second = KeyCue(start: time(1.5), duration: time(1.2), modifiers: [.command], key: "V")
        timeline.keyCues = [first, second]
        #expect(timeline.keyCue(at: time(1.2))?.id == first.id)
        #expect(timeline.keyCue(at: time(1.6))?.id == second.id)
        #expect(timeline.keyCue(at: time(2.5))?.id == second.id)
        #expect(timeline.keyCue(at: time(2.8)) == nil)
        #expect(timeline.keyCue(at: time(0.5)) == nil)
    }

    @Test func aHiddenPressAndAnInvisibleLaneDrawNothing() {
        var timeline = timeline()
        let cue = KeyCue(start: time(1), modifiers: [.command], key: "K", isHidden: true)
        timeline.keyCues = [cue]
        #expect(timeline.keyCue(at: time(1.5)) == nil)
        timeline.keyCues[0].isHidden = false
        #expect(timeline.keyCue(at: time(1.5))?.id == cue.id)
        timeline.keyStyle.isVisible = false
        #expect(timeline.keyCue(at: time(1.5)) == nil)
    }

    /// Return on its own is noise until the project says otherwise — and then it is a
    /// press like any other, on the lane and in the frame.
    @Test func namedKeysOnTheirOwnAreShownOnlyWhenAskedFor() {
        var timeline = timeline()
        let enter = KeyCue(start: time(1), key: "Return")
        let shortcut = KeyCue(start: time(3), modifiers: [.command], key: "Return")
        timeline.keyCues = [enter, shortcut]
        #expect(timeline.keyCue(at: time(1.5)) == nil)
        #expect(timeline.keyCue(at: time(3.5))?.id == shortcut.id, "⌘Return is a shortcut")
        #expect(timeline.shownKeyCues.map(\.id) == [shortcut.id])
        #expect(!timeline.boundaries.contains(enter.start), "not something a drag can snap to")

        timeline.keyStyle.showsNamedKeysAlone = true
        #expect(timeline.keyCue(at: time(1.5))?.id == enter.id)
        #expect(timeline.shownKeyCues.count == 2)
        #expect(timeline.boundaries.contains(enter.start))
    }

    @Test func aKeyCueIsMovedTrimmedAndDeletedLikeEveryOtherRegion() {
        var timeline = timeline()
        let cue = KeyCue(start: time(5), duration: time(1.2), modifiers: [.command], key: "K")
        #expect(Commands.AddKeyCue(cue).apply(to: &timeline))
        #expect(Commands.MoveRegion(id: cue.id, start: time(8)).apply(to: &timeline))
        #expect(timeline.keyCues[0].start == time(8))
        #expect(timeline.keyCues[0].duration == time(1.2), "a move keeps the length")
        #expect(Commands.MoveRegion(id: cue.id, start: time(8), duration: time(2)).apply(to: &timeline))
        #expect(timeline.keyCues[0].duration == time(2))
        #expect(Selection.keyCue(cue.id).range(in: timeline) == CMTimeRange(start: time(8), duration: time(2)))
        #expect(timeline.range(ofRegion: cue.id) == CMTimeRange(start: time(8), duration: time(2)))
        #expect(Commands.DeleteRegion(id: cue.id).apply(to: &timeline))
        #expect(timeline.keyCues.isEmpty)
        #expect(!Selection.keyCue(cue.id).isValid(in: timeline))
    }

    @Test func theLaneIsKeptInTimeOrder() {
        var timeline = timeline()
        let late = KeyCue(start: time(10), modifiers: [.command], key: "A")
        let early = KeyCue(start: time(2), modifiers: [.command], key: "B")
        Commands.AddKeyCue(late).apply(to: &timeline)
        Commands.AddKeyCue(early).apply(to: &timeline)
        #expect(timeline.keyCues.map(\.id) == [early.id, late.id])
        Commands.MoveRegion(id: early.id, start: time(20)).apply(to: &timeline)
        #expect(timeline.keyCues.map(\.id) == [late.id, early.id], "dragged past its neighbour")
        Commands.RestyleKeyCue(id: early.id, name: "Move") { $0.start = .zero }.apply(to: &timeline)
        #expect(timeline.keyCues.map(\.id) == [early.id, late.id])
    }

    @Test func addingRefusesWhatCannotBeReached() {
        var timeline = timeline(seconds: 10)
        #expect(!Commands.AddKeyCue(KeyCue(start: time(12), key: "K")).apply(to: &timeline), "off the end")
        #expect(!Commands.AddKeyCue(KeyCue(start: time(2), duration: time(0.01), key: "K")).apply(to: &timeline),
                "too short to grab")
        #expect(timeline.keyCues.isEmpty)
    }

    @Test func restylingIsOneEditAndANoOpIsNotOne() {
        var timeline = timeline()
        let cue = KeyCue(start: time(5), modifiers: [.command], key: "K")
        timeline.keyCues = [cue]
        #expect(Commands.RestyleKeyCue(id: cue.id, name: "Hide Shortcut") { $0.isHidden = true }.apply(to: &timeline))
        #expect(timeline.keyCues[0].isHidden)
        #expect(!Commands.RestyleKeyCue(id: cue.id, name: "Hide Shortcut") { $0.isHidden = true }.apply(to: &timeline))
        #expect(!Commands.RestyleKeyCue(id: UUID(), name: "Keys") { $0.key = "Z" }.apply(to: &timeline))
        // Whatever the change did, what is stored is drawable.
        Commands.RestyleKeyCue(id: cue.id, name: "Keys") { $0.key = " z "; $0.count = -4 }.apply(to: &timeline)
        #expect(timeline.keyCues[0].key == "z")
        #expect(timeline.keyCues[0].count == 1)
    }

    @Test func replacingEveryCueIsOneEdit() {
        var timeline = timeline()
        let cues = [KeyCue(start: time(9), key: "A"), KeyCue(start: time(3), key: "B")]
        #expect(Commands.SetKeyCues(cues, name: "Restore").apply(to: &timeline))
        #expect(timeline.keyCues.map(\.start) == [time(3), time(9)], "sorted on the way in")
        #expect(!Commands.SetKeyCues(cues, name: "Restore").apply(to: &timeline), "the same again is not an edit")
        #expect(Commands.SetKeyCues([], name: "Remove All Shortcuts").apply(to: &timeline))
        #expect(timeline.keyCues.isEmpty)
    }

    @Test func aCueTravelsWithTheFootageItSitsOver() {
        var timeline = timeline()
        timeline.keyCues = [KeyCue(start: time(25), modifiers: [.command], key: "K"),
                            KeyCue(start: time(45), modifiers: [.command], key: "V")]
        ClipSequence.delete(&timeline, range: CMTimeRange(start: time(20), end: time(30)))
        #expect(timeline.keyCues.count == 1, "the one inside the deleted stretch went with it")
        #expect(timeline.keyCues[0].start == time(35), "the later one moved up by the ten seconds removed")

        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, duration: time(50)), speed: 2)
        #expect(timeline.keyCues[0].start == time(17.5), "squeezed with the footage it sits on")
    }

    @Test func aCueOffTheEndIsClampedAway() {
        var timeline = timeline(seconds: 20)
        timeline.keyCues = [KeyCue(start: time(19.5), duration: time(1.2), key: "K")]
        ClipSequence.clampRegions(&timeline)
        #expect(timeline.keyCues[0].end == time(20))
        timeline.keyCues = [KeyCue(start: time(21), key: "K")]
        ClipSequence.clampRegions(&timeline)
        #expect(timeline.keyCues.isEmpty)
    }

    // MARK: - Copying

    @Test func aCopiedCueKeepsItsKeysAndItsCount() throws {
        var timeline = timeline()
        let cue = KeyCue(start: time(5), modifiers: [.command], key: "Z", count: 3, isHidden: true)
        timeline.keyCues = [cue]
        let copied = try #require(CopiedRegion(.keyCue(cue.id), in: timeline))
        #expect(copied == .key(cue))
        #expect(copied.title == "Shortcut")
        #expect(copied.summary.contains("⌘Z ×3"))
        let placed = try #require(copied.placed(at: time(20), in: timeline))
        guard case .key(let copy) = placed else { Issue.record("kind changed"); return }
        #expect(copy.id != cue.id)
        #expect(copy.start == time(20))
        #expect(copy.modifiers == cue.modifiers && copy.key == cue.key && copy.count == cue.count)
        #expect(copy.isHidden, "a copy that came back visible would be the copy undoing an edit")
        #expect(placed.selection == .keyCue(copy.id))
        #expect(Commands.InsertRegion(placed, name: "Paste Shortcut").apply(to: &timeline))
        #expect(timeline.keyCues.count == 2)
    }

    @Test func aCopiedCueCrossesThePasteboard() throws {
        let cue = KeyCue(start: time(5), modifiers: [.command, .option], key: "Left", count: 2)
        let data = try #require(CopiedRegion.key(cue).encoded())
        #expect(CopiedRegion.decoded(from: data) == .key(cue))
    }

    @Test func footageCarriesTheCuesThatLieWhollyOverIt() throws {
        var timeline = timeline()
        timeline.keyCues = [KeyCue(start: time(12), duration: time(1), key: "K"),
                            KeyCue(start: time(19.5), duration: time(1), key: "V")]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(10), end: time(20)), in: timeline))
        #expect(footage.keyCues.count == 1, "the one straddling the edge stays behind")
        #expect(footage.keyCues[0].start == time(2), "measured from the start of the copy")
        #expect(footage.carried == 1)
        let data = try #require(footage.encoded())
        #expect(CopiedFootage.decoded(from: data)?.keyCues.count == 1)

        let pasted = footage.freshened()
        #expect(pasted.keyCues[0].id != footage.keyCues[0].id)
        var destination = timeline
        #expect(ClipSequence.insert(&destination, pasted, at: time(30)))
        #expect(destination.keyCues.contains { $0.start == time(32) })
    }

    // MARK: - On disk

    @Test func aProjectWrittenBeforeKeysExistedOpensWithNone() throws {
        let json = """
        {"sourceDuration": {"value": 18000, "timescale": 600, "flags": 1, "epoch": 0}, "clips": []}
        """
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(timeline.keyCues.isEmpty)
        #expect(timeline.keyStyle == KeyStyle())
        #expect(timeline.keyStyle.isVisible)
        #expect(!timeline.keyStyle.showsNamedKeysAlone)
    }

    @Test func aCueMissingFieldsDecodesToDefaults() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "start": {"value": 600, "timescale": 600, "flags": 1, "epoch": 0}, "key": "K"}
        """
        let cue = try JSONDecoder().decode(KeyCue.self, from: Data(json.utf8))
        #expect(cue.key == "K")
        #expect(cue.modifiers.isEmpty)
        #expect(cue.count == 1)
        #expect(!cue.isHidden)
        #expect(cue.duration == KeyCue.defaultDuration)
    }

    @Test func aStyleWithAValueThisBuildDoesNotKnowFallsBackForThatFieldAlone() throws {
        let json = #"{"isVisible": false, "look": "hologram", "size": 0.1, "position": "topLeft"}"#
        let style = try JSONDecoder().decode(KeyStyle.self, from: Data(json.utf8))
        #expect(!style.isVisible)
        #expect(style.look == .keycaps, "the unknown look fell back")
        #expect(style.size == 0.1)
        #expect(style.position == .topLeft)
        #expect(KeyStyle(size: 40).sanitised.size == KeyStyle.sizeRange.upperBound)
    }

    @Test func keysRoundTripThroughAFile() throws {
        var timeline = timeline()
        timeline.keyCues = [KeyCue(start: time(5), duration: time(1), modifiers: [.command, .shift], key: "K", count: 2, isHidden: true)]
        timeline.keyStyle = KeyStyle(isVisible: true, position: .topRight, size: 0.09, look: .pill, showsNamedKeysAlone: true)
        let data = try JSONEncoder().encode(timeline)
        let read = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(read.keyCues == timeline.keyCues)
        #expect(read.keyStyle == timeline.keyStyle)
        #expect(read == timeline)
    }
}

/// The recorded presses, turned into cues.
struct KeyCueBuilderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func shortcut(_ t: Double, _ key: String, _ modifiers: KeyModifiers = [.command]) -> InputSample {
        .shortcut(t: t, modifiers: modifiers, key: key)
    }

    private let builder = KeyCueBuilder()

    private func cues(_ input: [InputSample], seconds: Double = 60) -> [KeyCue] {
        builder.cues(from: input, in: Timeline(sourceDuration: time(seconds)))
    }

    @Test func aPressShowsForAMoment() {
        let made = cues([shortcut(10, "K")])
        #expect(made.count == 1)
        #expect(made[0].start == time(10))
        #expect(abs(made[0].duration.seconds - 1.2) < 0.01)
        #expect(made[0].modifiers == [.command])
        #expect(made[0].key == "K")
        #expect(made[0].count == 1)
    }

    @Test func typingAndClicksMakeNoCues() {
        let made = cues([.key(t: 1, modifiers: 0), .key(t: 1.2, modifiers: 0),
                         .mouseDown(t: 2, button: 0, x: 1, y: 1), .scroll(t: 3, dx: 0, dy: 1)])
        #expect(made.isEmpty)
    }

    @Test func theSameShortcutAgainSoonCounts() {
        let made = cues([shortcut(10, "Z"), shortcut(10.4, "Z"), shortcut(10.7, "Z")])
        #expect(made.count == 1)
        #expect(made[0].count == 3)
        #expect(made[0].title == "⌘Z ×3")
        #expect(abs(made[0].end.seconds - 11.9) < 0.01, "shown for a moment past the last of them")
    }

    @Test func theSameShortcutAgainLaterIsANewPress() {
        let made = cues([shortcut(10, "Z"), shortcut(10.9, "Z")])
        #expect(made.count == 2)
        #expect(made[0].count == 1)
        #expect(made[0].end == time(10.9), "cut short by the press that followed")
    }

    @Test func aDifferentShortcutCutsTheEarlierOneShort() {
        let made = cues([shortcut(10, "C"), shortcut(10.5, "V")])
        #expect(made.count == 2)
        #expect(made[0].end == time(10.5))
        #expect(made[1].start == time(10.5))
        #expect(abs(made[1].duration.seconds - 1.2) < 0.01)
    }

    @Test func shiftMakesADifferentShortcut() {
        let made = cues([shortcut(10, "Z"), shortcut(10.3, "Z", [.command, .shift])])
        #expect(made.count == 2, "⌘Z and ⇧⌘Z are two presses")
    }

    @Test func aPressCutToLessThanAMomentIsDropped() {
        let made = cues([shortcut(10, "C"), shortcut(10.05, "V")])
        #expect(made.count == 1)
        #expect(made[0].key == "V")
    }

    /// A named key on its own is drawn only when the style asks, so it never cuts a
    /// shortcut short in the file — the frame decides. It does cut another lone key.
    @Test func aNamedKeyOnItsOwnCutsOnlyItsOwnKind() {
        let made = cues([shortcut(10, "K"), shortcut(10.3, "Return", []), shortcut(10.6, "Down", [])])
        #expect(made.count == 3)
        #expect(abs(made[0].end.seconds - 11.2) < 0.01, "the shortcut runs its full length")
        #expect(made[1].key == "Return")
        #expect(made[1].end == time(10.6), "cut by the next lone key")
        #expect(made[2].key == "Down")
        // And the frame settles the overlap: with lone keys off the shortcut shows all
        // the way through; with them on, the later press wins.
        var timeline = Timeline(sourceDuration: time(60))
        timeline.keyCues = made
        #expect(timeline.keyCue(at: time(10.4))?.key == "K")
        timeline.keyStyle.showsNamedKeysAlone = true
        #expect(timeline.keyCue(at: time(10.4))?.key == "Return")
        #expect(timeline.keyCue(at: time(10.7))?.key == "Down")
    }

    @Test func aShortcutCutsALoneKeyAndEndsItsRun() {
        let made = cues([shortcut(10, "Return", []), shortcut(10.3, "K"), shortcut(10.5, "Return", [])])
        #expect(made.map(\.key) == ["Return", "K", "Return"])
        #expect(made[0].end == time(10.3))
        #expect(made[2].count == 1, "the shortcut in between started a new run")
    }

    @Test func aRepeatedShortcutCutsALoneKeyThatCameBetween() {
        let made = cues([shortcut(10, "Z"), shortcut(10.2, "Return", []), shortcut(10.4, "Z")])
        #expect(made.count == 2)
        #expect(made[0].count == 2, "⌘Z twice within the window is still one press that counts")
        #expect(made[1].key == "Return")
        #expect(made[1].end == time(10.4), "over once the shortcut was pressed again")
    }

    @Test func pressesArePutOnTheEditsClock() {
        var timeline = Timeline(sourceDuration: time(60))
        // Ten seconds cut from the front, and the rest at double speed.
        ClipSequence.delete(&timeline, range: CMTimeRange(start: .zero, end: time(10)))
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(50)), speed: 2)
        let made = builder.cues(from: [shortcut(5, "A"), shortcut(30, "B"), shortcut(30.5, "B")], in: timeline)
        #expect(made.count == 1, "the press in the cut footage is gone")
        #expect(made[0].key == "B")
        #expect(made[0].start == time(10), "recording 30 is edit (30 − 10) / 2")
        #expect(made[0].count == 2, "a quarter of a second apart on the edit's clock")
    }

    @Test func aPressAtTheVeryEndIsCutToTheEnd() {
        let made = cues([shortcut(59.5, "K")])
        #expect(made.count == 1)
        #expect(made[0].end == time(60))
        #expect(cues([shortcut(60, "K")]).isEmpty, "and one on the end itself has no room")
    }

    @Test func pressesAreReadInTimeOrderWhateverOrderTheyArrivedIn() {
        let made = cues([shortcut(12, "V"), shortcut(10, "C")])
        #expect(made.map(\.key) == ["C", "V"])
    }
}
