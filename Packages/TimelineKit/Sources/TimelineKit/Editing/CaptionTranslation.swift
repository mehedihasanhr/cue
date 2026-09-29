import Foundation

extension Commands {
    /// Every caption's words replaced at once — a translation — as one edit.
    ///
    /// One step on the undo stack, like generating them, because it is one thing the user
    /// asked for: ⌘Z puts the original language back. Each cue keeps its timing; its timed
    /// words go, because they belong to the words that were spoken and not to these — the
    /// word-by-word highlight and the transcript tidy-up both read them, and both would
    /// otherwise be pointing at words that are no longer on screen.
    public struct ReplaceCaptionTexts: TimelineCommand {
        public let texts: [UUID: String]
        public let name: String

        public init(_ texts: [UUID: String], name: String = "Translate Captions") {
            self.texts = texts
            self.name = name
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            var changed = false
            for index in timeline.captions.indices {
                let cue = timeline.captions[index]
                guard let text = texts[cue.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text != cue.text else { continue }
                timeline.captions[index].text = text
                timeline.captions[index].words = []
                changed = true
            }
            return changed
        }
    }
}
