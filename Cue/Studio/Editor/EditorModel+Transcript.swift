import CoreMedia
import Foundation
import TimelineKit

extension EditorModel {
    /// How much of a long pause is kept when it is shortened: enough to breathe, not
    /// enough to wait through.
    static let keptPause = 0.4

    /// Whether any caption knows when its words were said, which is what every cut made
    /// from the transcript is measured by.
    var hasTimedWords: Bool {
        timeline.captions.contains { !$0.words.isEmpty && $0.words == $0.timedWords }
    }

    var fillerRanges: [CMTimeRange] { TranscriptEditing.fillerRanges(in: timeline) }

    func removeFillerWords() {
        let ranges = fillerRanges
        guard !ranges.isEmpty else { return }
        clearSelection()
        apply(Commands.DeleteRanges(ranges, name: "Remove Filler Words"))
    }

    /// The pauses longer than `limit` that would be shortened: every silence between two
    /// words, except one in which something was clicked — that is somebody showing, and
    /// the silence is the demonstration.
    func pauseRanges(longerThan limit: Double) -> [CMTimeRange] {
        let clicked = document.cursorTrack.clicks.flatMap { click in
            timeline.timelineRanges(ofSource: max(0, click.t - 0.5)...(click.t + 0.5))
        }
        return TranscriptEditing.pauseRanges(in: timeline, longerThan: limit,
                                             keeping: Self.keptPause, busy: clicked)
    }

    func shortenPauses(longerThan limit: Double) {
        let ranges = pauseRanges(longerThan: limit)
        guard !ranges.isEmpty else { return }
        clearSelection()
        apply(Commands.DeleteRanges(ranges, name: "Shorten Pauses"))
    }

    /// Cuts the moment a line was said out of the video: the picture, the sound and the
    /// line itself.
    func removeCaptionFromVideo(_ id: UUID) {
        guard let cue = timeline.captions.first(where: { $0.id == id }) else { return }
        // Only the recording under the line: a caption that spans a title slide put in
        // under it (an insert stretches it across) must not take the slide with it.
        let ranges = TranscriptEditing.keepingHolds([CMTimeRange(start: cue.start, end: cue.end)], in: timeline)
        guard !ranges.isEmpty else { return }
        clearSelection()
        apply(Commands.DeleteRanges(ranges, name: "Remove Line from Video"))
    }
}

extension EditorModel {
    /// Puts translated words into the captions, as one step Undo takes back.
    func applyCaptionTranslation(_ texts: [UUID: String]) {
        apply(Commands.ReplaceCaptionTexts(texts))
    }
}
