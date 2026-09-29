import CoreMedia
import Foundation

/// What a drag is asking for, before anything decides whether it is allowed.
///
/// Deliberately small, and deliberately *not* where the clamping lives. A drag preview has
/// to show what will actually land when the mouse comes up, and the only way to be sure of
/// that is for one piece of code to decide it — which is the command. So this works out
/// what the gesture is asking for, the command says what happens, and there is no second
/// set of limits to drift out of step with the first.
///
/// Every frame of a drag is the *original* geometry plus the current offset, never the last
/// frame's answer plus a little more. That is what keeps a slow drag from accumulating
/// rounding into a visible drift, and it is why this takes the start and duration the item
/// had when the gesture began rather than the ones it has now.
public enum DragGeometry {
    /// What the pointer took hold of.
    public enum Grip: Equatable, Sendable {
        /// The body: the item slides and keeps its length.
        case body
        /// An end: that end moves and the other stays where it is.
        case head, tail
    }

    /// Where the gesture is asking for this item to be.
    ///
    /// The one limit applied here is the one the command cannot express: an end dragged
    /// past the other end. The command receives absolute positions, so by the time it sees
    /// a head dragged twenty seconds to the right it has no way to know which end the
    /// pointer had hold of.
    public static func proposal(start: CMTime,
                                duration: CMTime,
                                grip: Grip,
                                offset: CMTime) -> (start: CMTime, duration: CMTime) {
        let floor = Clip.minimumDuration
        let end = start + duration
        switch grip {
        case .body:
            return (start + offset, duration)
        case .head:
            // Read off the far end rather than adjusted alongside it: working out the start
            // and the length separately is how an edge ends up a frame from where it was
            // dropped.
            let settled = min(start + offset, end - floor)
            return (settled, end - settled)
        case .tail:
            return (start, max(floor, duration + offset))
        }
    }
}

public extension Timeline {
    /// Where a region sits, whichever lane it is on.
    ///
    /// The lanes are separate arrays because they hold different things, and this is the
    /// one question that does not care which: a drag preview needs to know where the thing
    /// it just moved ended up, and it knows only an id.
    func range(ofRegion id: UUID) -> CMTimeRange? {
        if let found = zooms.first(where: { $0.id == id }) { return found.range }
        if let found = blurs.first(where: { $0.id == id }) { return found.range }
        if let found = annotations.first(where: { $0.id == id }) { return found.range }
        if let found = captions.first(where: { $0.id == id }) { return found.range }
        if let found = audio.first(where: { $0.id == id }) { return found.range }
        if let found = cursorRegions.first(where: { $0.id == id }) { return found.range }
        if let found = detachedSound?.first(where: { $0.id == id }) { return found.range }
        return nil
    }
}
