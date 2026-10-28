import CoreMedia
import Foundation
import TimelineKit

/// Copying one setting across every region of its kind, the reference's "apply to all":
/// set one zoom or one clip the way it should be, then make the rest match in one step
/// Undo takes back.
extension EditorModel {
    /// Every unlocked zoom at the level of the one selected. A locked zoom keeps its own:
    /// the lock is somebody saying "not this one".
    func applyZoomLevelToAll() {
        guard let source = activeZoom else { return }
        let scale = source.scale
        apply(Commands.Restyle("Apply Zoom Level to All") { timeline in
            for index in timeline.zooms.indices where !timeline.zooms[index].isLocked {
                timeline.zooms[index].scale = scale
            }
        })
    }

    var canApplyZoomLevelToAll: Bool {
        guard let source = activeZoom else { return false }
        return timeline.zooms.contains { $0.id != source.id && !$0.isLocked && $0.scale != source.scale }
    }

    /// The whole edit at the speed of the selected clip.
    func applySpeedToAll() {
        guard let speed = selectedClip?.clip.speed, timeline.duration > .zero else { return }
        apply(Commands.SetSpeed(CMTimeRange(start: .zero, duration: timeline.duration), speed: speed))
    }

    var canApplySpeedToAll: Bool {
        guard let speed = selectedClip?.clip.speed else { return false }
        return timeline.clips.contains { $0.speed != speed }
    }
}
