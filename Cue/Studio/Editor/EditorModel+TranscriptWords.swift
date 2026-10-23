import AppKit
import CoreMedia
import Foundation
import Observation
import TimelineKit

/// The words picked out in the transcript, to be cut from the video.
///
/// Kept apart from the timeline's selection because they are a different kind of thing —
/// moments in what was said, not regions on a lane — and because picking one must not
/// leave a zoom selected underneath it for Delete to take instead. The two never hold
/// anything at once: picking words lets go of the timeline's selection, and picking on the
/// timeline lets go of the words.
///
/// Each word is kept with where it was when it was picked. A cut or an undo renumbers the
/// words of a line, and a selection held by number alone would then point at whichever word
/// had moved into the place — so only a word still where it was picked is ever cut.
@MainActor
@Observable
final class TranscriptWordSelection {
    private(set) var picked: [TranscriptEditing.WordID: TranscriptEditing.SpokenWord] = [:]
    /// Where a Shift-click runs from: the word clicked last without Shift.
    private(set) var anchor: TranscriptEditing.WordID?

    var isEmpty: Bool { picked.isEmpty }

    func contains(_ id: TranscriptEditing.WordID) -> Bool { picked[id] != nil }

    /// The picked words that are still the words they were when they were picked.
    func current(among words: [TranscriptEditing.SpokenWord]) -> Set<TranscriptEditing.WordID> {
        Set(words.filter { picked[$0.id] == $0 }.map(\.id))
    }

    /// Picks `word`: alone, or added to or taken from what is picked (⌘), or as the end of a
    /// run from the last word clicked (⇧) — what every list on this platform does.
    func pick(_ word: TranscriptEditing.SpokenWord,
              among words: [TranscriptEditing.SpokenWord],
              extending: Bool,
              toggling: Bool) {
        if extending, let anchor,
           let from = words.firstIndex(where: { $0.id == anchor }),
           let to = words.firstIndex(where: { $0.id == word.id }) {
            for spoken in words[min(from, to)...max(from, to)] { picked[spoken.id] = spoken }
            return
        }
        if toggling {
            if picked[word.id] != nil {
                picked[word.id] = nil
            } else {
                picked[word.id] = word
            }
        } else {
            picked = [word.id: word]
        }
        anchor = word.id
    }

    func clear() {
        guard !picked.isEmpty || anchor != nil else { return }
        picked = [:]
        anchor = nil
    }
}

extension EditorModel {
    /// Every word the recogniser timed, in the order it is heard. Only these can be picked
    /// in the transcript: see `TranscriptEditing.wordCutRanges`.
    var spokenWords: [TranscriptEditing.SpokenWord] {
        TranscriptEditing.spokenWords(in: timeline)
    }

    /// Picks a word in the transcript. A plain click also takes the playhead to it, because
    /// the next thing wanted after finding a word is nearly always to hear it.
    func pickWord(_ word: TranscriptEditing.SpokenWord) {
        let flags = NSEvent.modifierFlags
        let extending = flags.contains(.shift)
        let toggling = flags.contains(.command)
        clearSelection()
        transcriptWords.pick(word, among: spokenWords, extending: extending, toggling: toggling)
        if !extending && !toggling { scrub(to: word.range.start) }
    }

    /// The picked words that can be cut: still where they were picked, and timed.
    var wordsToCut: Set<TranscriptEditing.WordID> {
        transcriptWords.current(among: spokenWords)
    }

    var canCutWords: Bool { !wordsToCut.isEmpty }

    /// Cuts the picked words out of the video — picture, sound, captions and everything
    /// laid over them — as one step Undo takes back, and leaves the playhead a second before
    /// the first join, so pressing Play is how to hear whether it sounds right.
    func cutPickedWords() {
        guard let command = Commands.cutWords(wordsToCut, in: timeline) else { return }
        let join = command.ranges.map(\.start).min()
        clearSelection()
        transcriptWords.clear()
        apply(command)
        if let join { scrub(to: max(.zero, join - CMTime(seconds: 1, preferredTimescale: 600))) }
    }
}
