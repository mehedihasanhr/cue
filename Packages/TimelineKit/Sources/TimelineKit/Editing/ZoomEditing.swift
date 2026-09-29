import CoreMedia
import Foundation

/// The arithmetic of the second pass over a take: splitting a zoom, joining two, putting
/// one back to the defaults, and re-running auto-zoom over work somebody has already done.
///
/// A namespace of pure functions over values rather than methods on `Commands`, for the
/// reason `ClipSequence` is one: these are the parts that can be quietly wrong, and they
/// have to be testable without a document, an undo stack or a renderer. The commands in
/// `Commands` are thin wrappers that find the regions and hand them here.
public enum ZoomLane {
    /// One zoom cut in two at `time`, the earlier half first.
    ///
    /// The point of the whole exercise is that the two halves *look like the one that was
    /// there*: a long push-in becomes two you can aim separately without the picture
    /// moving at the moment you split it. That is what the seam ramps are for. The first
    /// half is still ramping out at its end and the second still ramping in at its start,
    /// as every region does — so a naive split would dip the camera all the way back out
    /// to 1× and in again at the cut, which is a lurch nobody asked for and the one thing
    /// that would make this verb useless. Setting the two ramps that meet at the seam to
    /// zero says "already arrived", and the pair then reads as one movement.
    ///
    /// `nil` when the cut would leave a piece too short to see or grab again — the same
    /// floor `Commands.AddZoom` refuses on. A zoom four frames wide is not a zoom, it is
    /// something the user has lost.
    ///
    /// The earlier half keeps the id, so an inspector open on the zoom stays open on the
    /// part the playhead is behind. Both halves keep their `source`: splitting a suggestion
    /// does not make it a hand-made zoom, and what protects a zoom from the next suggestion
    /// run is the lock, not the history of how it was cut.
    public static func split(_ region: ZoomRegion, at time: CMTime) -> (ZoomRegion, ZoomRegion)? {
        let head = time - region.start
        let tail = region.end - time
        guard head >= Clip.minimumDuration, tail >= Clip.minimumDuration else { return nil }

        var first = region
        first.duration = head
        // Zero rather than `nil`: `nil` means "whatever `transition` says", which is the
        // ramp being removed.
        first.transitionOut = .zero

        var second = ZoomRegion(start: time,
                                duration: tail,
                                center: region.center,
                                easing: region.easing,
                                transition: region.transition,
                                transitionIn: .zero,
                                transitionOut: region.transitionOut,
                                followsCursor: region.followsCursor,
                                source: region.source,
                                isLocked: region.isLocked,
                                isInstant: region.isInstant)
        // Assigned rather than passed because the initialiser clamps `scale` into 1…8, and
        // this has to come through untouched: a split must not quietly restyle a zoom that
        // a hand edit or a newer build put outside that range.
        second.scale = region.scale
        return (first, second)
    }

    /// Two zooms as one.
    ///
    /// The result starts where the earlier one started and ends where the later one ended,
    /// and it keeps the outer ramps: the camera arrives exactly as the first one made it
    /// arrive and leaves exactly as the second one made it leave, so the framing at either
    /// end of the pair is untouched. Where the two agree about scale and aim — which is
    /// every pair that came from a split — the result is indistinguishable from the region
    /// they were cut from, and merging is precisely the inverse of splitting.
    ///
    /// Where they disagree, the longer one's look wins outright rather than being averaged:
    /// the average of 1.4× and 3× is a zoom neither of them was, and the region holding
    /// more of the timeline is the one the edit is mostly about. Ties go to the earlier,
    /// because that is the one the reader met first.
    ///
    /// A gap between them is spanned rather than refused. "Merge these two" means one
    /// continuous push-in over the stretch they cover, and a caller that only ever offers
    /// the immediate neighbour is asking about a gap of a few frames — refusing on it would
    /// be a button that does nothing for reasons only the code knows.
    ///
    /// The lock survives if either had it: a lock is a promise about a stretch of the
    /// timeline, and dropping it here would be a way to quietly unlock a zoom.
    public static func merge(_ a: ZoomRegion, _ b: ZoomRegion) -> ZoomRegion? {
        guard a.id != b.id else { return nil }
        let (first, second) = a.start <= b.start ? (a, b) : (b, a)
        let end = max(first.end, second.end)
        let donor = second.duration > first.duration ? second : first

        var merged = first
        merged.duration = end - first.start
        merged.scale = donor.scale
        merged.center = donor.center
        merged.easing = donor.easing
        merged.followsCursor = donor.followsCursor
        merged.source = donor.source
        merged.isLocked = first.isLocked || second.isLocked
        merged.transition = donor.transition
        merged.isInstant = donor.isInstant

        // The ramps the pair actually showed at its two ends, expressed against the donor's
        // `transition` so that a pair whose ends both want the plain ramp stores nothing at
        // all — which is what makes split-then-merge hand back the original value, keys and
        // all, rather than one that merely renders the same.
        let wantedIn = first.transitionIn ?? first.transition
        let wantedOut = second.transitionOut ?? second.transition
        merged.transitionIn = wantedIn == merged.transition ? nil : wantedIn
        merged.transitionOut = wantedOut == merged.transition ? nil : wantedOut
        return merged
    }

    /// The same zoom, placed and aimed as it is, looking the way a new one looks.
    ///
    /// Scale, easing and both ramps only. Where it is and what it points at are deliberately
    /// left alone: those are the two things the user chose on purpose, and a Reset that also
    /// recentred the shot would be a delete with extra steps. The seam ramps do go, which is
    /// the one part of this that is not obvious — a reset half of a split zoom becomes an
    /// ordinary zoom again, ramped at both ends, because it has stopped pretending to be
    /// half of a pair.
    public static func reset(_ region: ZoomRegion) -> ZoomRegion {
        var reset = region
        reset.scale = ZoomRegion.defaultScale
        reset.easing = ZoomRegion.defaultEasing
        reset.transition = ZoomRegion.defaultTransition
        reset.transitionIn = nil
        reset.transitionOut = nil
        // A cut is a way of ramping — none at all — so it goes back with the ramps.
        reset.isInstant = false
        return reset
    }

    /// Whether a suggestion run is allowed to throw this zoom away.
    ///
    /// A zoom is the user's if they placed it (`.manual`), if the build that wrote it had no
    /// opinion (`nil` — every project saved before `source` existed), or if they locked it.
    /// Everything else on the lane is the last run's output, and the next run's job is to
    /// replace it rather than to pile a second copy on top of it.
    /// Switching a suggestion off counts as the user's, and that is the policy rather than
    /// an accident of the predicate: "not a zoom here" is a decision about that stretch of
    /// the take, exactly as placing one by hand is, and a run that regenerated over it
    /// would overrule a judgement the user has already made. The way to take the decision
    /// back is to delete the zoom, which is aimed at it and cannot happen by surprise.
    ///
    /// Framing one by hand counts as the user's for the same reason, and without the cost
    /// of a lock: dragging a suggested zoom to where it should have been pointed is the
    /// single most valuable edit anybody makes on the second pass, and it was the one the
    /// next run silently undid. See `ZoomRegion.isEdited`.
    public static func isSuggestion(_ region: ZoomRegion) -> Bool {
        !region.isLocked && region.isEnabled && !region.isEdited
            && region.source != nil && region.source != .manual
    }

    /// What the zoom lane should hold after auto-zoom has run again.
    ///
    /// Re-running used to append, which is the bug this fixes: press the button twice and
    /// every suggestion existed twice, stacked exactly on top of itself, so deleting the one
    /// you could see left the one you could not. Worse, a suggestion laid over a zoom
    /// somebody had placed by hand won the frame wherever it was deeper — the renderer takes
    /// the strongest zoom at each moment — which silently overruled the edit.
    ///
    /// So: the user's zooms stay, the previous run's are thrown away, and a new suggestion
    /// that would overlap a zoom of the user's is dropped rather than trimmed. Dropped,
    /// because a hand-placed zoom is a statement about *that stretch* of the take, and a
    /// suggestion squeezed into the frames either side of it is a flicker rather than a
    /// camera move. The result is sorted by start, the invariant the whole lane is kept to.
    public static func reconciled(_ suggestions: [ZoomRegion],
                                  with existing: [ZoomRegion],
                                  duration: CMTime) -> [ZoomRegion] {
        let kept = existing.filter { !isSuggestion($0) }
        let fresh = suggestions.filter { candidate in
            candidate.duration >= Clip.minimumDuration
                && candidate.start < duration
                && !kept.contains { $0.start < candidate.end && candidate.start < $0.end }
        }
        return (kept + fresh).sorted { $0.start < $1.start }
    }
}
