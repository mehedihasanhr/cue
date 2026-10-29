import SwiftUI

/// Frames for an animation in the open island, which stop once the island closes.
///
/// A view leaving the island can outlive its removal: SwiftUI keeps a removed view
/// while its transition plays, and now and then never lets it go. Clipped away under
/// the closed notch, its `TimelineView` went on redrawing thirty times a second for as
/// long as Cue ran. These frames run out when the island closes, so nothing out of
/// sight keeps the processor awake.
struct IslandFrames: TimelineSchedule {
    /// Whether the island is open (anything but collapsed); set by `IslandModel`.
    nonisolated(unsafe) static var open = false

    let interval: TimeInterval
    var paused = false
    /// Keeps running while the island is closed (what is shown on the closed island itself).
    var whileClosed = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        var first = true
        return AnyIterator {
            // The first frame always, so a paused or closed view still shows something.
            if first {
                first = false
            } else if paused || !(whileClosed || Self.open) {
                return nil
            }
            defer { next += interval }
            return next
        }
    }
}
