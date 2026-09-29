import CoreMedia
import TimelineKit

/// The markers dropped while recording: where they are on the timeline, and moving the
/// playhead between them.
///
/// Worked out from the clips every time they are asked for, rather than kept — see
/// `RecordedMarkers` — so a trim or a cut moves them without anything to keep in step.
extension EditorModel {
    /// Where each marker is on the timeline now, earliest first.
    var markerTimes: [CMTime] {
        RecordedMarkers.times(of: document.recordedMarkers, in: timeline)
    }

    var hasMarkers: Bool { !markerTimes.isEmpty }

    var previousMarker: CMTime? { RecordedMarkers.previous(before: playhead, in: markerTimes) }
    var nextMarker: CMTime? { RecordedMarkers.next(after: playhead, in: markerTimes) }

    func goToPreviousMarker() {
        guard let time = previousMarker else { return }
        scrub(to: time)
    }

    func goToNextMarker() {
        guard let time = nextMarker else { return }
        scrub(to: time)
    }

    /// Cuts the footage at every marker, as one step Undo takes back.
    func splitAtMarkers() {
        apply(Commands.SplitAtMarkers(at: markerTimes))
    }
}
