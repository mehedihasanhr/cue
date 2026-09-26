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
    ///
    /// # Its relationship to `insert`
    ///
    /// Worth stating exactly, because "ripple delete" and "ripple insert" are only inverses
    /// where the arithmetic lets them be, and confusing the two halves is how a timeline
    /// quietly drifts.
    ///
    /// **Insert then delete is exact**, in the strict `==` sense, when the delete names the
    /// stretch the insert created *and the insert landed on an existing cut*. Every later
    /// region moved forward by the inserted length and comes back by the same length; a
    /// region straddling the seam gained that length and has exactly that `overlap` taken
    /// back out; every clip the insert added falls wholly inside the deleted range and is
    /// removed. Where the insert had to open a *new* cut, the result is equal in every
    /// respect but one: the clip that was split stays split. Nothing here rejoins two clips
    /// that are contiguous in the source at one speed, and adding a coalescing pass to this
    /// function would change what an ordinary delete does to the clip count — a real
    /// improvement, and not one to smuggle in underneath a paste.
    ///
    /// **Delete then insert is not exact, and cannot be.** A delete drops the regions that
    /// sat wholly inside the range, and an insert has nothing to put back in their place —
    /// `Commands.DeleteRange` is undone from the snapshot on the undo stack rather than by
    /// running an inverse, which is precisely why `UndoStack` stores whole timelines.
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

    /// Puts a stretch of footage into the timeline, pushing everything after it along.
    ///
    /// The inverse of `delete`, and the only edit here that makes the timeline *longer*.
    /// Three things happen, in this order, and the order is the whole correctness argument:
    /// the sequence is cut at the insertion point so there is a seam to insert at, every
    /// region from that point onwards moves later by exactly the length being inserted, and
    /// then the footage and the regions that travelled with it are laid into the seam. Doing
    /// the ripple *before* the clips go in means the arithmetic never has to reason about a
    /// timeline that is half-edited.
    ///
    /// # Where it lands
    ///
    /// At a cut, always — never in the middle of a clip. `split` opens one at the requested
    /// time when it can, and where it refuses (the ends of the edit, a cut that already
    /// exists, a sliver shorter than `Clip.minimumDuration`) the insertion point becomes the
    /// nearest existing cut instead of the paste failing. That is worth the snap: the user
    /// asked to put footage somewhere, the length inserted is identical either way, and the
    /// position moves by less than a tenth of a second. Matching the boundary rather than
    /// comparing against the requested time is also what makes this robust at other speeds —
    /// a cut inside a 1.7× clip round-trips through `CMTimeMultiplyByFloat64` twice, and the
    /// result is not reliably `==` the time that was asked for.
    ///
    /// # What happens to a region spanning the insertion point
    ///
    /// It is **stretched over the inserted footage**: its start is left where it is and its
    /// length grows by the inserted length. That is `shiftRegions(startingAtOrAfter:by:)`'s
    /// existing rule, and it is the right one here for two reasons. A region's start is a
    /// moment the user chose and must not move; and its end is the moment it stops applying
    /// to footage that is still running up to there — a blur over somebody's face that
    /// suddenly stopped early would expose the face. It is also exactly what makes delete
    /// the inverse: delete takes `overlap` back out of a straddler's length, so inserting a
    /// stretch and deleting the same stretch leaves such a region's duration unchanged.
    ///
    /// # Detached sound
    ///
    /// See `rippled(_:at:by:)`. In short: an attached lane needs nothing done to it, because
    /// there the sound *is* the clips; a detached lane ripples, and a run spanning the
    /// insertion point is cut in two rather than stretched — because stretching a run makes
    /// it consume more source, which means playing words that were never there.
    ///
    /// Refuses footage naming source this recording has not got, which is the cross-project
    /// paste. See `CopiedFootage.sourceDuration` for why a length is the test and what the
    /// better test would be.
    @discardableResult
    public static func insert(_ timeline: inout Timeline,
                              _ footage: CopiedFootage,
                              at time: CMTime) -> Bool {
        let inserted = footage.duration
        guard !footage.clips.isEmpty, inserted >= Clip.minimumDuration else { return false }
        guard footage.sourceEnd <= timeline.sourceDuration else { return false }

        let requested = max(.zero, min(time, timeline.duration))
        split(&timeline, at: requested)

        // The seam nearest what was asked for, and the index in front of it. Seeded with
        // the start of the edit, so a paste at zero — where there is no cut to find and
        // none to make — lands at the front rather than at the first clip's far edge.
        var point = CMTime.zero
        var index = 0
        var nearest = CMTimeAbsoluteValue(requested)
        var elapsed = CMTime.zero
        for (offset, clip) in timeline.clips.enumerated() {
            elapsed = elapsed + clip.duration
            let distance = CMTimeAbsoluteValue(elapsed - requested)
            if distance < nearest {
                nearest = distance
                point = elapsed
                index = offset + 1
            }
        }

        // Lifted out before the generic ripple runs, and put back by hand afterwards,
        // because the sound lane is the one lane whose straddle rule differs — everything
        // else wants stretching and a run wants cutting. Assigning `nil` here is not a
        // statement that the lane is attached: nothing observes the timeline between these
        // two lines, and the value is restored below whenever there was one.
        let runs = timeline.detachedSound
        timeline.detachedSound = nil
        shiftRegions(&timeline, startingAtOrAfter: point, by: inserted)

        timeline.clips.insert(contentsOf: footage.clips, at: index)

        /// The travelling regions, moved from the copy's own clock into this timeline's.
        func arriving<Region: TimelineRegion>(_ regions: [Region]) -> [Region] {
            regions.map { region in
                var region = region
                region.start = region.start + point
                return region
            }
        }

        timeline.zooms.append(contentsOf: arriving(footage.zooms))
        timeline.blurs.append(contentsOf: arriving(footage.blurs))
        timeline.annotations.append(contentsOf: arriving(footage.annotations))
        timeline.captions.append(contentsOf: arriving(footage.captions))
        timeline.audio.append(contentsOf: arriving(footage.audio))
        timeline.cursorRegions.append(contentsOf: arriving(footage.cursorRegions))
        // Three lanes are kept in start order as an invariant rather than a convention —
        // the renderer sums zooms in order, `captionAtPlayhead` takes the last cue
        // containing the playhead, and an inspector open on a cursor region must not find
        // itself pointing at another. `Commands.InsertRegion` sorts exactly these three.
        timeline.zooms.sort { $0.start < $1.start }
        timeline.captions.sort { $0.start < $1.start }
        timeline.cursorRegions.sort { $0.start < $1.start }

        if let runs {
            timeline.detachedSound = (rippled(runs, at: point, by: inserted)
                                      + arriving(footage.soundRuns))
                .sorted { $0.start < $1.start }
        }

        clampRegions(&timeline)
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

    /// Moves a detached sound lane out of the way of inserted footage.
    ///
    /// # Whether a detached lane ripples at all
    ///
    /// It does, and this is the second judgement call the feature turns on, so here is the
    /// argument. `Timeline.detachedSound` says a detached lane is "the whole truth about the
    /// recording's sound: the picture's cuts say nothing about it any more", which reads at
    /// first like a licence to leave the lane alone when the picture grows. It is not. What
    /// detaching buys the user is the freedom to disagree with the picture *about a cut* —
    /// "let them keep talking over this one" — and that freedom is spent deliberately, run by
    /// run. Inserting ten seconds of footage at the playhead and leaving the lane where it
    /// was would make every word after the insertion disagree with the picture at once,
    /// which is not an edit anybody asked for; it is the whole take falling out of sync. So
    /// time inserted into the picture is time inserted into the lane, and the disagreements
    /// the user actually authored are preserved exactly, because each run keeps its own
    /// offset from the insertion point.
    ///
    /// # A run spanning the insertion point
    ///
    /// **Cut in two**, not stretched, and this is where the lane parts company with the
    /// other six. A `SoundRun`'s `sourceDuration` is derived from its length, so growing a
    /// run to cover inserted footage makes it consume more of the recording — it would play
    /// words that were never in that part of the take, and shift every word after the
    /// insertion point later inside the run. Cutting it keeps the front half exactly where
    /// it was, and gives the back half a `sourceStart` advanced by precisely the source the
    /// front half consumes, so every word lands on the picture it was detached from. What
    /// sits over the inserted footage is then whatever the paste lays down there — which is
    /// the copied footage's own sound, carried for exactly this moment.
    ///
    /// Where one of the halves would be shorter than `Clip.minimumDuration` the run is left
    /// whole and treated as beginning or ending at the seam, whichever it is closer to.
    /// There is no third answer: a run too short to grab is a run the user has lost, and
    /// producing one to be arithmetically tidy trades a real handle for a rounding error.
    static func rippled(_ runs: [SoundRun], at point: CMTime, by length: CMTime) -> [SoundRun] {
        runs.flatMap { run -> [SoundRun] in
            if run.start >= point {
                var moved = run
                moved.start = moved.start + length
                return [moved]
            }
            guard run.end > point else { return [run] }

            let front = point - run.start
            let back = run.end - point
            guard front >= Clip.minimumDuration, back >= Clip.minimumDuration else {
                guard front < back else { return [run] }
                var moved = run
                moved.start = moved.start + length
                return [moved]
            }

            var head = run
            head.duration = front
            let tail = SoundRun(start: point + length,
                                duration: back,
                                sourceStart: run.sourceTime(atOffset: front),
                                speed: run.speed)
            return [head, tail]
        }
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
