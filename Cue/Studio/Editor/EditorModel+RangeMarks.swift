import CoreMedia
import TimelineKit

/// Marking a stretch of the timeline from the playhead: the start with one key, the end
/// with another.
///
/// Until now the only range the editor could select was the whole of it (⌘A), which made
/// "the selection" a thing that existed in the model and nowhere on screen. Exporting
/// part of a video needs a part, and the keys every editor uses for it are I and O.
extension EditorModel {
    /// The selected stretch, if a stretch is what is selected.
    var selectedRange: CMTimeRange? {
        if case .range(let range) = selection, range.duration > .zero { return range }
        return nil
    }

    /// Makes the selection start at the playhead, keeping its end if it has one that is
    /// later — otherwise the stretch runs to the end of the edit.
    func markSelectionStart() {
        let start = min(playhead, duration)
        let end = selectedRange.map { $0.end > start ? $0.end : duration } ?? duration
        guard end > start else { return }
        select(.range(CMTimeRange(start: start, end: end)))
    }

    /// Makes the selection end at the playhead, keeping its start if it has one that is
    /// earlier — otherwise the stretch runs from the start of the edit.
    func markSelectionEnd() {
        let end = min(playhead, duration)
        let start = selectedRange.map { $0.start < end ? $0.start : .zero } ?? .zero
        guard end > start else { return }
        select(.range(CMTimeRange(start: start, end: end)))
    }
}
