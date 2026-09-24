import CoreMedia
import Foundation

/// The edits that change what footage plays and for how long.
///
/// All of it is `inout` arithmetic over the clip array, with the regions on top carried
/// along so an edit does not leave a zoom pointing at footage that is no longer there.
/// Split out from the model so the rules can be read — and tested — in one place.
public enum ClipSequence {
    /// Cuts the clip at `time` in two.
    ///
    /// A cut has no duration: both halves keep their own piece of the source, so the
    /// timeline is exactly as long afterwards as it was before. Splitting at a cut that
    /// already exists does nothing rather than inserting an empty clip.
    @discardableResult
    public static func split(_ timeline: inout Timeline, at time: CMTime) -> Bool {
        guard let (index, clip, offset) = timeline.clip(at: time),
              offset > .zero, offset < clip.duration,
              offset >= Clip.minimumDuration,
              clip.duration - offset >= Clip.minimumDuration
        else { return false }

        let consumed = CMTimeMultiplyByFloat64(offset, multiplier: clip.speed)
        let first = Clip(id: clip.id,
                         sourceStart: clip.sourceStart,
                         sourceDuration: consumed,
                         speed: clip.speed)
        let second = Clip(sourceStart: clip.sourceStart + consumed,
                          sourceDuration: clip.sourceDuration - consumed,
                          speed: clip.speed)
        timeline.clips.replaceSubrange(index...index, with: [first, second])
        return true
    }

    /// Removes a stretch of the timeline and closes the gap.
    ///
    /// Everything after it moves earlier by exactly the length removed, and so do the
    /// regions — a zoom that sat over the deleted stretch goes with it, rather than
    /// surviving as a zoom over whatever slid into its place.
    @discardableResult
    public static func delete(_ timeline: inout Timeline, range: CMTimeRange) -> Bool {
        guard range.duration > .zero else { return false }
        let start = max(.zero, range.start)
        let end = min(timeline.duration, range.end)
        guard end > start else { return false }

        split(&timeline, at: start)
        split(&timeline, at: end)

        var kept: [Clip] = []
        var elapsed = CMTime.zero
        for clip in timeline.clips {
            let clipEnd = elapsed + clip.duration
            let insideDeletion = elapsed >= start && clipEnd <= end
            if !insideDeletion { kept.append(clip) }
            elapsed = clipEnd
        }
        guard kept.count != timeline.clips.count else { return false }
        guard !kept.isEmpty else { return false }   // never delete the whole recording

        timeline.clips = kept
        shiftRegions(&timeline, removing: CMTimeRange(start: start, end: end))
        return true
    }

    /// Plays a stretch faster or slower.
    ///
    /// Implemented as two cuts and a speed on the clips between them, which is why speed
    /// needs no region type of its own: a speed *is* a property of the footage that
    /// plays, and keeping it there means one source of truth for how long the edit runs.
    @discardableResult
    public static func setSpeed(_ timeline: inout Timeline,
                                range: CMTimeRange,
                                speed: Double,
                                movesRegions: Bool = true) -> Bool {
        guard range.duration > .zero, speed > 0 else { return false }
        let start = max(.zero, range.start)
        let end = min(timeline.duration, range.end)
        guard end > start else { return false }

        split(&timeline, at: start)
        split(&timeline, at: end)

        var changed = false
        var elapsed = CMTime.zero
        var newEnd = start
        for index in timeline.clips.indices {
            let clip = timeline.clips[index]
            let clipEnd = elapsed + clip.duration
            let inside = elapsed >= start && clipEnd <= end
            if inside, clip.speed != speed {
                timeline.clips[index] = Clip(id: clip.id,
                                             sourceStart: clip.sourceStart,
                                             sourceDuration: clip.sourceDuration,
                                             speed: speed)
                changed = true
            }
            if inside { newEnd = newEnd + timeline.clips[index].duration }
            elapsed = clipEnd
        }
        guard changed else { return false }

        // A zoom is a statement about a moment in the edit, so the ones *inside* the
        // range are stretched or squeezed with the footage they were placed on, and the
        // ones *after* it move by the length the range gained or lost. Leaving the later
        // ones where they were is what used to slide every downstream zoom off the thing
        // it was pointing at.
        if movesRegions {
            let factor = (end - start).seconds > 0
                ? (newEnd - start).seconds / (end - start).seconds
                : 1
            rescaleRegions(&timeline, in: CMTimeRange(start: start, end: end), about: start, by: factor)
            shiftRegions(&timeline, startingAtOrAfter: end, by: newEnd - end)
        }
        clampRegions(&timeline)
        return true
    }

    /// Moves a clip to a different position in the order.
    ///
    /// The destination is an **index**, not a time: a timeline with no gaps has nowhere
    /// to drop something except between two other clips, and resolving a drag to a
    /// position would only re-derive an index from arithmetic that can round wrong.
    @discardableResult
    public static func move(_ timeline: inout Timeline, from index: Int, to destination: Int) -> Bool {
        guard timeline.clips.indices.contains(index) else { return false }
        let target = max(0, min(destination, timeline.clips.count - 1))
        guard target != index else { return false }
        let clip = timeline.clips.remove(at: index)
        timeline.clips.insert(clip, at: target)
        return true
    }

    /// Changes where a clip starts or ends within the footage available to it.
    ///
    /// Bounded by the source, not by the neighbours: there is no gap to grow into, so
    /// trimming a clip's head only reveals more of *its* recording, and the clips after
    /// it move as a consequence.
    @discardableResult
    public static func trim(_ timeline: inout Timeline,
                            clipID: UUID,
                            head: CMTime?,
                            tail: CMTime?,
                            movesRegions: Bool = true) -> Bool {
        guard let index = timeline.clips.firstIndex(where: { $0.id == clipID }) else { return false }
        let original = timeline.clips[index]
        let clipStart = timeline.start(ofClipAt: index)
        var clip = original

        if let head {
            let newStart = max(.zero, min(head, clip.sourceEnd - Clip.minimumDuration))
            let delta = newStart - clip.sourceStart
            clip.sourceStart = newStart
            clip.sourceDuration = clip.sourceDuration - delta
        }
        // How much shorter the clip got at its front, in timeline time — measured before
        // the tail is touched, because the two ends move different things.
        let headShift = original.duration - clip.duration

        if let tail {
            let newEnd = min(timeline.sourceDuration, max(tail, clip.sourceStart + Clip.minimumDuration))
            clip.sourceDuration = newEnd - clip.sourceStart
        }
        guard clip.sourceDuration >= Clip.minimumDuration, clip != original else { return false }

        timeline.clips[index] = clip

        // Footage taken off the head slides this clip's own contents — and everything
        // after them — earlier. Footage taken off the tail moves only what follows.
        // Treating both as "shift what comes after the clip" leaves a zoom pointing at
        // the wrong second the moment anyone drags the left handle.
        if movesRegions {
            if headShift != .zero {
                shiftRegions(&timeline, startingAtOrAfter: clipStart, by: .zero - headShift)
            }
            let afterHead = clipStart + original.duration - headShift
            let nowEnding = clipStart + clip.duration
            if nowEnding != afterHead {
                shiftRegions(&timeline, startingAtOrAfter: afterHead, by: nowEnding - afterHead)
            }
        }
        clampRegions(&timeline)
        return true
    }

    // MARK: - Regions

    /// Drops regions inside a deleted range and pulls the later ones back by its length.
    private static func shiftRegions(_ timeline: inout Timeline, removing range: CMTimeRange) {
        func adjust<Region: TimelineRegion>(_ regions: [Region]) -> [Region] {
            regions.compactMap { region in
                var region = region
                if region.start >= range.start && region.end <= range.end { return nil }
                if region.start >= range.end {
                    region.start = region.start - range.duration
                } else if region.end > range.start {
                    // Straddles the cut: keep the part that survived rather than
                    // dropping an effect the user placed deliberately.
                    let overlap = min(region.end, range.end) - max(region.start, range.start)
                    region.duration = max(Clip.minimumDuration, region.duration - overlap)
                }
                return region
            }
        }

        timeline.zooms = adjust(timeline.zooms)
        timeline.blurs = adjust(timeline.blurs)
        timeline.annotations = adjust(timeline.annotations)
        timeline.captions = adjust(timeline.captions)
        timeline.audio = adjust(timeline.audio)
        if let runs = timeline.detachedSound { timeline.detachedSound = adjust(runs) }
        timeline.cursorRegions = adjust(timeline.cursorRegions)
    }

    /// Moves everything from `time` onwards by `delta`.
    static func shiftRegions(_ timeline: inout Timeline, startingAtOrAfter time: CMTime, by delta: CMTime) {
        guard delta != .zero else { return }

        func adjust<Region: TimelineRegion>(_ regions: [Region]) -> [Region] {
            regions.map { region in
                var region = region
                if region.start >= time {
                    region.start = max(.zero, region.start + delta)
                } else if region.end > time {
                    // Straddles the edge: keep where it starts, take the change out of
                    // its length. Clamped rather than dropped — the user put it there.
                    region.duration = max(Clip.minimumDuration, region.duration + delta)
                }
                return region
            }
        }

        timeline.zooms = adjust(timeline.zooms)
        timeline.blurs = adjust(timeline.blurs)
        timeline.annotations = adjust(timeline.annotations)
        timeline.captions = adjust(timeline.captions)
        timeline.audio = adjust(timeline.audio)
        if let runs = timeline.detachedSound { timeline.detachedSound = adjust(runs) }
        timeline.cursorRegions = adjust(timeline.cursorRegions)
    }

    /// Stretches or squeezes everything inside `range` about `anchor`.
    static func rescaleRegions(_ timeline: inout Timeline, in range: CMTimeRange, about anchor: CMTime, by factor: Double) {
        guard factor > 0, abs(factor - 1) > 1e-9 else { return }

        func adjust<Region: TimelineRegion>(_ regions: [Region]) -> [Region] {
            regions.map { region in
                guard region.start >= range.start, region.end <= range.end else { return region }
                var region = region
                region.start = anchor + CMTimeMultiplyByFloat64(region.start - anchor, multiplier: factor)
                region.duration = max(Clip.minimumDuration,
                                      CMTimeMultiplyByFloat64(region.duration, multiplier: factor))
                return region
            }
        }

        timeline.zooms = adjust(timeline.zooms)
        timeline.blurs = adjust(timeline.blurs)
        timeline.annotations = adjust(timeline.annotations)
        timeline.captions = adjust(timeline.captions)
        timeline.audio = adjust(timeline.audio)
        if let runs = timeline.detachedSound { timeline.detachedSound = adjust(runs) }
        timeline.cursorRegions = adjust(timeline.cursorRegions)
    }

    /// Keeps every region inside the timeline it belongs to.
    public static func clampRegions(_ timeline: inout Timeline) {
        let end = timeline.duration

        func clamp<Region: TimelineRegion>(_ regions: [Region]) -> [Region] {
            regions.compactMap { region in
                var region = region
                if region.start >= end { return nil }
                if region.end > end { region.duration = end - region.start }
                return region.duration >= Clip.minimumDuration ? region : nil
            }
        }

        timeline.zooms = clamp(timeline.zooms)
        timeline.blurs = clamp(timeline.blurs)
        timeline.annotations = clamp(timeline.annotations)
        timeline.captions = clamp(timeline.captions)
        timeline.audio = clamp(timeline.audio)
        if let runs = timeline.detachedSound { timeline.detachedSound = clamp(runs) }
        timeline.cursorRegions = clamp(timeline.cursorRegions)
    }

    // MARK: - The sound lane

    /// Cuts the recording's sound loose from the picture.
    ///
    /// Deliberately not a no-op that merely flips a flag: the runs it writes are the sound
    /// exactly as the clips were already laying it down, one run per clip, at the same
    /// speeds. So the instant after detaching, the mixdown builds the same composition
    /// from the other branch of one `if` — which is the only way a user can trust the
    /// menu item enough to use it in the middle of a cut.
    ///
    /// One run per clip rather than one coalesced run per contiguous stretch of source,
    /// even though coalescing would be equally audible. The lane has to keep showing the
    /// cuts it was detached at, because those cuts are the handles: "let them keep talking
    /// over this cut" is dragging *this* run's right edge, and a lane with the cuts
    /// smoothed away has nowhere to start.
    @discardableResult
    public static func detachSound(_ timeline: inout Timeline) -> Bool {
        guard timeline.detachedSound == nil else { return false }
        timeline.detachedSound = timeline.soundRunsFollowingClips
        return true
    }

    /// Puts the sound back in step with the picture.
    ///
    /// Forgetting the runs rather than reconciling them, and that is the honest operation:
    /// "in step with the clips" is a thing `clips` already says completely, so the way to
    /// mean it is to stop keeping a second answer. Whether that throws away work is
    /// `Timeline.detachedSoundIsInStepWithClips`, which the caller asks *before* getting
    /// here so it can say what is about to be lost.
    @discardableResult
    public static func attachSound(_ timeline: inout Timeline) -> Bool {
        guard timeline.detachedSound != nil else { return false }
        timeline.detachedSound = nil
        return true
    }
}
