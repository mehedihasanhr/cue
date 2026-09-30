import CoreMedia
import Foundation

/// The camera travelling straight from one zoom to the next.
///
/// Two zooms a moment apart used to be two complete movements: the camera pulled all the
/// way back out to the whole picture at the end of the first and pushed all the way in
/// again at the start of the second, however short the gap. That is the single most
/// visible difference between a polished zoom and an amateur one, and this is the rule
/// that removes it.
///
/// **The rule.** Two zooms glide when they are neighbours on the lane — the next
/// switched-on zoom after this one, with no other switched-on zoom in force anywhere in
/// the move — and the gap between the end of the first and the start of the second is
/// shorter than the two ramps that would meet in it: the first's ramp out plus the
/// second's ramp in. Touching counts as a gap of nothing. Overlapping zooms do not glide;
/// the strongest wins between them, as it always has. An instant zoom never glides,
/// because gliding is one movement turning into another and an instant zoom has asked for
/// no movement at all. With a longer gap the camera pulls back exactly as it did before.
///
/// **The move.** It begins where the first zoom's ramp out would have begun and ends
/// where the second's ramp in would have ended, so the camera sets off and arrives at
/// precisely the moments it always did; only the path between them changes. The scale
/// goes straight from the first zoom's to the second's and is never outside the two, and
/// the centre goes straight from the shot the first zoom would be holding at that moment
/// to the shot the second would — pointer-following and all, worked out by the renderer
/// for both — eased the way the second zoom asks to be arrived at. Because each end of
/// the path *is* the shot the neighbouring zoom holds, the camera's centre is continuous
/// at both ends of the move.
public struct ZoomGlide: Equatable, Sendable {
    public let from: ZoomRegion
    public let to: ZoomRegion
    /// When the camera leaves the first framing: where its ramp out would have begun.
    public let start: CMTime
    /// When it has arrived at the second: where its ramp in would have ended.
    public let end: CMTime
    /// When the camera actually sets off. The same as `start` for zooms whose ramps meet;
    /// later for a pair the camera stays zoomed in between, which hold the first shot
    /// through the gap and then move in the time a glide between touching zooms takes.
    public let moveStart: CMTime

    init(from: ZoomRegion, to: ZoomRegion, start: CMTime, end: CMTime, moveStart: CMTime? = nil) {
        self.from = from
        self.to = to
        self.start = start
        self.end = end
        self.moveStart = min(max(moveStart ?? start, start), end)
    }

    /// Whether the camera stays zoomed in across a gap here, rather than gliding between
    /// ramps that meet.
    public var isKeptZoomedIn: Bool { moveStart > start }

    public var duration: CMTime { end - start }

    public func contains(_ time: CMTime) -> Bool { time >= start && time < end }

    /// How far along the move the camera is at `time`, eased.
    ///
    /// Eased with the *arriving* zoom's curve, because arriving is what the eye judges.
    /// The curve never passes 1, so the centre never swings past the next shot and back —
    /// which it used to, when the spring overshot, as a sideways wobble before each glide
    /// settled.
    public func progress(at time: CMTime) -> Double {
        let moving = (end - moveStart).seconds
        guard moving > 0 else { return time < end ? 0 : 1 }
        let t = min(1, max(0, (time - moveStart).seconds / moving))
        return to.easing.apply(t)
    }

    /// How far in the camera is at `time`: between the two zooms' scales, never outside.
    ///
    /// Linear in scale, like the ramp it replaces. Clamped so a spring's overshoot cannot
    /// pull the camera back past the wider of the two shots for a frame — the whole point
    /// of the glide is that it never does.
    public func scale(at time: CMTime) -> Double {
        let progress = min(1, max(0, progress(at: time)))
        let scale = from.scale + (to.scale - from.scale) * progress
        return min(max(scale, min(from.scale, to.scale)), max(from.scale, to.scale))
    }

    /// The glide between two neighbouring zooms, or `nil` when they are too far apart —
    /// or too close, or the wrong kind — to glide.
    ///
    /// The neighbour test itself is `ZoomLane.glides(in:)`'s; this only asks about the
    /// pair. `to` must not start before `from` ends: overlaps keep the strongest-wins rule.
    static func between(_ from: ZoomRegion, _ to: ZoomRegion, keepingZoomedFor kept: Double = 0) -> ZoomGlide? {
        guard from.isEnabled, to.isEnabled, !from.isInstant, !to.isInstant,
              from.duration > .zero, to.duration > .zero else { return nil }
        let gap = to.start - from.end
        guard gap >= .zero else { return nil }
        let needed = from.ramps.out + to.ramps.in
        // A gap as long as the ramps is where pulling back stops looking like a stumble
        // and starts looking like a pause. Two ramps of nothing that touch fail this too,
        // which is the seam a split leaves: a cut, as it always was.
        guard gap < needed else {
            // Farther apart than that, the camera still stays in when asked to — holding
            // the first shot through the gap and leaving for the second as late as a glide
            // between touching zooms would, so the move itself looks the same either way.
            guard kept > 0, gap.seconds <= kept else { return nil }
            let end = to.start + to.ramps.in
            return ZoomGlide(from: from, to: to,
                             start: from.end - from.ramps.out,
                             end: end,
                             moveStart: to.start - from.ramps.out)
        }
        return ZoomGlide(from: from, to: to,
                         start: from.end - from.ramps.out,
                         end: to.start + to.ramps.in)
    }
}

public extension ZoomLane {
    /// Every glide on a lane, in time order.
    ///
    /// Neighbours are found among the zooms that are switched on, in start order, so a
    /// zoom that has been switched off is looked straight past. A pair whose move any
    /// third zoom would be in force during is refused: two zooms cannot be travelling
    /// between while a third is deciding the shot. The moves never overlap one another,
    /// because a zoom's ramps together never exceed its length — so the move into it is
    /// over before the move out of it begins.
    static func glides(in zooms: [ZoomRegion], keepingZoomedFor kept: Double = 0) -> [ZoomGlide] {
        let lane = Commands.MoveRegion.inTimeOrder(zooms.filter { $0.isEnabled && $0.duration > .zero })
        guard lane.count > 1 else { return [] }

        var glides: [ZoomGlide] = []
        // The furthest any earlier zoom reaches, so one long zoom behind a pair cannot be
        // in force during their move without being noticed.
        var reachOfEarlier = CMTime.negativeInfinity
        for index in 1..<lane.count {
            let from = lane[index - 1]
            let to = lane[index]
            defer { reachOfEarlier = max(reachOfEarlier, from.end) }
            guard let glide = ZoomGlide.between(from, to, keepingZoomedFor: kept) else { continue }
            guard reachOfEarlier <= glide.start else { continue }
            if index + 1 < lane.count, lane[index + 1].start < glide.end { continue }
            glides.append(glide)
        }
        return glides
    }

    /// The move in force at `time`, if the camera is travelling between two zooms then.
    static func glide(at time: CMTime, in zooms: [ZoomRegion], keepingZoomedFor kept: Double = 0) -> ZoomGlide? {
        glides(in: zooms, keepingZoomedFor: kept).first { $0.contains(time) }
    }

    /// The zoom after this one along the lane, whatever state it is in — the neighbour
    /// "Merge with Next" and "Extend to Next Zoom" both mean.
    static func zoomAfter(_ id: UUID, in zooms: [ZoomRegion]) -> ZoomRegion? {
        let lane = Commands.MoveRegion.inTimeOrder(zooms)
        guard let index = lane.firstIndex(where: { $0.id == id }), index + 1 < lane.count else { return nil }
        return lane[index + 1]
    }
}

public extension Timeline {
    /// The move the camera is making between two zooms at `time`, or `nil` when it is not
    /// — including whenever the project has gliding switched off.
    func zoomGlide(at time: CMTime) -> ZoomGlide? {
        guard camera.glidesBetweenZooms else { return nil }
        return ZoomLane.glide(at: time, in: zooms, keepingZoomedFor: camera.sanitised.keepsZoomedInFor)
    }
}

extension Commands {
    /// Lengthens a zoom so it ends exactly where the next one begins.
    ///
    /// Touching is the surest way to make two zooms glide, and dragging a chip's edge
    /// onto its neighbour's is a fiddly way to ask for it. Refused — and so never on the
    /// undo stack — when there is no next zoom, or when this one already reaches or
    /// overlaps it: "extend" only ever makes a zoom longer. Allowed on a locked zoom for
    /// the reason a split is: it is aimed at one region from a menu, and the lock is there
    /// for the accidents.
    public struct ExtendZoomToNext: TimelineCommand {
        public let id: UUID
        public var name: String { "Extend to Next Zoom" }

        public init(id: UUID) { self.id = id }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard let index = timeline.zooms.firstIndex(where: { $0.id == id }),
                  let next = ZoomLane.zoomAfter(id, in: timeline.zooms),
                  next.start > timeline.zooms[index].end else { return false }
            timeline.zooms[index].duration = next.start - timeline.zooms[index].start
            return true
        }
    }
}
