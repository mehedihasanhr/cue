import CoreMedia
import Foundation
import RecordKit

/// The markers dropped while recording, as places on the timeline.
///
/// A marker is a fact about the recording — "something happened here" — so it is kept in
/// the recording's time and never edited. Where it shows on the timeline is worked out
/// from the clips each time: trim the start and every marker moves left with the footage,
/// speed a stretch up and the markers in it close together, cut a stretch out and the
/// markers in it go with it. Nothing has to be kept in step, because nothing is stored
/// twice.
public enum RecordedMarkers {
    /// Where each marker falls on the timeline, earliest first. A marker in footage that
    /// was cut out has no place and is left out.
    public static func times(of markers: [MarkerSample], in timeline: Timeline) -> [CMTime] {
        let times = markers.compactMap { marker in
            timeline.timelineTime(atSource: CMTime(seconds: marker.t, preferredTimescale: 600))
        }
        return times.sorted()
    }

    /// How close two moments can be and still count as one: a hundredth of a second, the
    /// same allowance Previous Cut and Next Cut make for a playhead parked on an edge.
    public static let tolerance = CMTime(value: 1, timescale: 100)

    /// The last marker before `time`, not counting one the playhead is already on.
    public static func previous(before time: CMTime, in times: [CMTime]) -> CMTime? {
        times.last { $0 < time - tolerance }
    }

    /// The first marker after `time`, not counting one the playhead is already on.
    public static func next(after time: CMTime, in times: [CMTime]) -> CMTime? {
        times.first { $0 > time + tolerance }
    }
}

extension Commands {
    /// Cuts the footage at every marker, in one step Undo takes back in one step.
    ///
    /// A marker on an existing cut, at either end, or too close to a cut for a clip to fit
    /// is passed over — the same refusals `Split` makes — rather than failing the rest.
    public struct SplitAtMarkers: TimelineCommand {
        public let times: [CMTime]
        public var name: String { "Split at Markers" }

        public init(at times: [CMTime]) { self.times = times }

        public func apply(to timeline: inout Timeline) -> Bool {
            var changed = false
            for time in times.sorted() where ClipSequence.split(&timeline, at: time) {
                changed = true
            }
            return changed
        }
    }
}
