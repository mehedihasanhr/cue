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
    ///
    /// A freeze frame splits into two freeze frames of the same moment, so either half can
    /// be deleted or lengthened on its own. A title does not split: it is one card with one
    /// entrance, and two halves of it would play the entrance twice.
    ///
    /// The first half keeps the clip's identity and the way it arrives; the second is a new
    /// clip arriving on a plain cut, because the cut it arrives on is new.
    @discardableResult
    public static func split(_ timeline: inout Timeline, at time: CMTime) -> Bool {
        guard let (index, clip, offset) = timeline.clip(at: time),
              !clip.isTitle,
              offset > .zero, offset < clip.duration,
              offset >= Clip.minimumDuration,
              clip.duration - offset >= Clip.minimumDuration
        else { return false }

        var first = clip
        let second: Clip
        if let hold = clip.hold {
            first.hold = offset
            second = Clip.still(of: clip.sourceStart, for: hold - offset, in: clip.source)
        } else {
            // The second half's length is what the first did not consume, subtracted
            // exactly, rather than re-derived from the offset: the two must add up to the
            // clip's source to the last tick, or a split and a rejoin drift.
            let consumed = CMTimeMultiplyByFloat64(offset, multiplier: clip.speed)
            first.sourceDuration = consumed
            second = Clip(sourceStart: clip.sourceStart + consumed,
                          sourceDuration: clip.sourceDuration - consumed,
                          speed: clip.speed,
                          source: clip.source)
        }
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
        // Where a cut was refused — within `Clip.minimumDuration` of one that exists, or
        // inside a title, which does not split — the edge goes to the nearest cut there is.
        // Left where it was asked for, the clip across it stayed whole and nothing of it
        // went: a second filler word a twentieth of a second after the first was not
        // removed at all.
        let (from, to) = (nearestCut(to: start, in: timeline), nearestCut(to: end, in: timeline))
        guard to > from else { return false }

        var kept: [Clip] = []
        // What actually went, measured from the clips rather than from the range: the
        // regions have to move by the time that really left the edit. They used to move by
        // the length asked for, and everything after the cut then sat early by whatever
        // part of it had stayed.
        var removedStart: CMTime?
        var removedEnd = CMTime.zero
        var elapsed = CMTime.zero
        for clip in timeline.clips {
            let clipEnd = elapsed + clip.duration
            let insideDeletion = elapsed >= from && clipEnd <= to
            if insideDeletion {
                if removedStart == nil { removedStart = elapsed }
                removedEnd = clipEnd
            } else {
                kept.append(clip)
            }
            elapsed = clipEnd
        }
        guard kept.count != timeline.clips.count, let removedStart else { return false }
        guard !kept.isEmpty else { return false }   // never delete the whole recording

        timeline.clips = kept
        shiftRegions(&timeline, removing: CMTimeRange(start: removedStart, end: removedEnd))
        return true
    }

    /// The cut nearest a moment, counting the start and the end of the edit as cuts.
    ///
    /// Where a range's edge lands once the sequence has been cut there if it could be.
    /// Found by distance rather than by equality, because a cut made inside a clip at
    /// another speed goes through `CMTimeMultiplyByFloat64` twice and is not reliably `==`
    /// the time that was asked for — the reason `insert` matches its seam the same way.
    static func nearestCut(to time: CMTime, in timeline: Timeline) -> CMTime {
        var nearest = CMTime.zero
        var distance = CMTimeAbsoluteValue(time)
        var elapsed = CMTime.zero
        for clip in timeline.clips {
            elapsed = elapsed + clip.duration
            let away = CMTimeAbsoluteValue(elapsed - time)
            if away < distance {
                distance = away
                nearest = elapsed
            }
        }
        return nearest
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
    /// better test would be. An imported clip is refused the same way when neither this
    /// timeline nor the copy knows the file it names; one the copy knows is recorded here
    /// as it lands, which is what makes a paste after undoing the import it came from work.
    @discardableResult
    public static func insert(_ timeline: inout Timeline,
                              _ footage: CopiedFootage,
                              at time: CMTime) -> Bool {
        let inserted = footage.duration
        guard !footage.clips.isEmpty, inserted >= Clip.minimumDuration else { return false }
        guard footage.sourceEnd <= timeline.sourceDuration else { return false }
        let known = Set(timeline.media.map(\.path) + footage.media.map(\.path))
        guard footage.clips.allSatisfy({ $0.source.map(known.contains) ?? true }) else { return false }
        for file in footage.media where !timeline.media.contains(where: { $0.path == file.path }) {
            timeline.media.append(file)
        }

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

        openTime(&timeline, at: point, length: inserted)
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
        timeline.keyCues.append(contentsOf: arriving(footage.keyCues))
        timeline.cameraLayouts.append(contentsOf: arriving(footage.cameraLayouts))
        // Three lanes are kept in start order as an invariant rather than a convention —
        // the renderer sums zooms in order, `captionAtPlayhead` takes the last cue
        // containing the playhead, and an inspector open on a cursor region must not find
        // itself pointing at another. `Commands.InsertRegion` sorts exactly these three.
        timeline.zooms.sort { $0.start < $1.start }
        timeline.captions.sort { $0.start < $1.start }
        timeline.cursorRegions.sort { $0.start < $1.start }
        timeline.keyCues.sort { $0.start < $1.start }
        timeline.cameraLayouts.sort { $0.start < $1.start }

        if let runs = timeline.detachedSound {
            timeline.detachedSound = (runs + arriving(footage.soundRuns))
                .sorted { $0.start < $1.start }
        }

        clampRegions(&timeline)
        return true
    }

    /// Makes room for `length` of new time at `point`: everything from there on moves
    /// later by that much.
    ///
    /// The ripple half of an insertion, and of a freeze frame growing. Every lane stretches
    /// a region spanning the point, except the sound lane, whose runs are cut there instead
    /// — see `rippled(_:at:by:)`. The lane is lifted out before the generic ripple runs and
    /// put back by hand, because it is the one lane whose straddle rule differs. Assigning
    /// `nil` in between is not a statement that the lane is attached: nothing observes the
    /// timeline between those lines, and the value is restored whenever there was one.
    static func openTime(_ timeline: inout Timeline, at point: CMTime, length: CMTime) {
        guard length > .zero else { return }
        let runs = timeline.detachedSound
        timeline.detachedSound = nil
        shiftRegions(&timeline, startingAtOrAfter: point, by: length)
        if let runs {
            timeline.detachedSound = rippled(runs, at: point, by: length).sorted { $0.start < $1.start }
        }
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
        // To the nearest cut where one was refused, as `delete` does and for its reason:
        // left where it was asked for, the clip across the edge kept its old speed while a
        // stretch a twentieth of a second short of it was treated as retimed.
        let (from, to) = (nearestCut(to: start, in: timeline), nearestCut(to: end, in: timeline))
        guard to > from else { return false }

        // The speed a clip will really get, so asking for a speed past the limits does not
        // count as a change on a clip that is already at the limit.
        let speed = max(Clip.minimumSpeed, min(speed, Clip.maximumSpeed))
        /// Each clip that changed: where it was, how long it is now, and its old speed.
        var changes: [(range: CMTimeRange, duration: CMTime, was: Double)] = []
        var elapsed = CMTime.zero
        for index in timeline.clips.indices {
            let clip = timeline.clips[index]
            let clipEnd = elapsed + clip.duration
            let inside = elapsed >= from && clipEnd <= to
            // A clip that holds has no footage to play faster, so it keeps its length:
            // a freeze frame in a stretch being sped up is still two seconds of stillness.
            if inside, clip.isFootage, clip.speed != speed {
                var faster = clip
                faster.speed = speed
                timeline.clips[index] = faster
                changes.append((CMTimeRange(start: elapsed, end: clipEnd), faster.duration, clip.speed))
            }
            elapsed = clipEnd
        }
        guard !changes.isEmpty else { return false }

        // A zoom is a statement about a moment in the edit, so the ones *inside* the
        // range are stretched or squeezed with the footage they were placed on, and the
        // ones *after* it move by the length the range gained or lost. Leaving the later
        // ones where they were is what used to slide every downstream zoom off the thing
        // it was pointing at.
        //
        // Clip by clip, last first, because the clips in a range need not all change by
        // the same factor: one at 1× and one at 2× both set to 4× shrink by four and by two.
        // Retimed as one stretch they were given one factor between them, and everything
        // inside drifted off its footage. Working back from the end means each clip is
        // retimed while the ones before it are still where they were measured.
        if movesRegions {
            for change in changes.reversed() {
                retimeRegions(&timeline, range: change.range, newEnd: change.range.start + change.duration,
                              speeds: (change.was, speed))
            }
        }
        clampRegions(&timeline)
        return true
    }

    /// Moves a clip to a different position in the order, with what was placed on it.
    ///
    /// The destination is an **index**, not a time: a timeline with no gaps has nowhere
    /// to drop something except between two other clips, and resolving a drag to a
    /// position would only re-derive an index from arithmetic that can round wrong. It is
    /// the clip's index once it has been taken out, which is what `Array.move` means too:
    /// moving the first of three clips to 2 makes it the last.
    ///
    /// # What goes with it
    ///
    /// It used to be only the clip: the zooms, blurs, captions and sounds placed on it
    /// stayed where they were in time and landed on whatever footage slid under them. So a
    /// move is now the three edits it is made of, run on a copy and kept only if all three
    /// succeed: the clip is lifted exactly as a copy lifts it, ripple-deleted, and inserted
    /// again in front of the clip it is going before. Which means the rules are the ones
    /// copy, delete and paste already keep and already test:
    ///
    /// - A region wholly on the clip travels with it, keeping its id, so a selected zoom is
    ///   still selected afterwards.
    /// - A region straddling the clip's edge stays behind, shortened by the part that was
    ///   over the clip — the rule a ripple delete keeps. Half a caption spoken over the end
    ///   of the clip loses the words the clip took away.
    /// - A region spanning the cut the clip is dropped into is stretched over it, as it is
    ///   when footage is pasted there.
    /// - The recording's own sound goes with the picture: attached it follows the clips by
    ///   construction, and detached, the runs over the clip are lifted and laid down again.
    @discardableResult
    public static func move(_ timeline: inout Timeline, from index: Int, to destination: Int) -> Bool {
        guard timeline.clips.indices.contains(index), timeline.clips.count > 1 else { return false }
        let target = max(0, min(destination, timeline.clips.count - 1))
        guard target != index else { return false }
        let clip = timeline.clips[index]
        let range = CMTimeRange(start: timeline.start(ofClipAt: index), duration: clip.duration)

        // The copy is the clip exactly — `CopiedFootage` cuts at the range's ends, and the
        // range's ends are this clip's own cuts — so it carries the clip's id and nothing else.
        guard let footage = CopiedFootage(range, in: timeline),
              footage.clips.map(\.id) == [clip.id] else { return false }

        var moved = timeline
        guard delete(&moved, range: range) else { return false }
        guard insert(&moved, footage, at: moved.start(ofClipAt: target)),
              moved.clips.firstIndex(where: { $0.id == clip.id }) == target
        else { return false }
        timeline = moved
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
        // A clip that holds has no in- or out-point to move; its length is `setHold`'s.
        guard original.isFootage else { return false }
        // Bounded by its own file: the recording for a clip of it, the imported movie for
        // one of those.
        let available = timeline.sourceDuration(of: original)
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
            let newEnd = min(available, max(tail, clip.sourceStart + Clip.minimumDuration))
            clip.sourceDuration = newEnd - clip.sourceStart
        }
        guard clip.sourceDuration >= Clip.minimumDuration, clip != original else { return false }

        timeline.clips[index] = clip

        // Footage taken off the head slides this clip's own contents — and everything
        // after them — earlier. Footage taken off the tail moves only what follows.
        // Treating both as "shift what comes after the clip" leaves a zoom pointing at
        // the wrong second the moment anyone drags the left handle.
        if movesRegions {
            if headShift > .zero {
                // What was on the footage cut off the front goes with it, like a ripple
                // delete of that stretch. Moved back instead, a zoom on the trimmed-away
                // second landed on the clip before this one.
                shiftRegions(&timeline, removing: CMTimeRange(start: clipStart, duration: headShift))
            } else if headShift < .zero {
                shiftRegions(&timeline, startingAtOrAfter: clipStart, by: .zero - headShift)
            }
            let afterHead = clipStart + original.duration - headShift
            let nowEnding = clipStart + clip.duration
            if nowEnding < afterHead {
                // The tail's twin of the head's rule above: what was on the footage cut off
                // the end goes with it. Moved instead, a zoom on the last second of a clip
                // trimmed shorter slid onto the start of the next clip's footage.
                shiftRegions(&timeline, removing: CMTimeRange(start: nowEnding, end: afterHead))
            } else if nowEnding > afterHead {
                shiftRegions(&timeline, startingAtOrAfter: afterHead, by: nowEnding - afterHead)
            }
        }
        clampRegions(&timeline)
        return true
    }

    /// Changes how long a freeze frame or a title lasts.
    ///
    /// Its own edit rather than a trim, because a trim moves an in- or out-point in the
    /// recording and a clip that holds has neither — only a length. It behaves as a trim
    /// of the clip's far end does: what is placed on the clip keeps its place, and what
    /// comes after moves by the difference. Longer opens time at the clip's end, the way an
    /// insertion there would; shorter takes the time out of the clip's end, the way a
    /// ripple delete of it would, so a zoom placed on the part that went goes too.
    @discardableResult
    public static func setHold(_ timeline: inout Timeline, clipID: UUID, to length: CMTime) -> Bool {
        guard let index = timeline.clips.firstIndex(where: { $0.id == clipID }),
              let hold = timeline.clips[index].hold else { return false }
        let wanted = Clip.clampedHold(length)
        guard wanted != hold else { return false }
        let end = timeline.start(ofClipAt: index) + hold

        if wanted > hold {
            openTime(&timeline, at: end, length: wanted - hold)
        } else {
            shiftRegions(&timeline, removing: CMTimeRange(start: end - (hold - wanted), end: end))
        }
        timeline.clips[index].hold = wanted
        clampRegions(&timeline)
        return true
    }

    // MARK: - Regions

    /// Moves every region to follow a stretch that now plays faster or slower.
    ///
    /// One mapping for both ends of every region: a moment before the stretch stays, a
    /// moment inside it is squeezed or stretched with it, a moment after it moves by what
    /// the stretch gained or lost. It used to be two steps — stretch what was inside, then
    /// move what was after — and a zoom stretched past the old end was then moved again:
    /// slowing 10–20 s to half speed sent a zoom at 16 s to 32 s instead of 22 s.
    ///
    /// A detached sound run is footage too, and has to keep playing the same seconds of
    /// the recording as the picture over it, so it is cut at the stretch's edges and the
    /// part inside takes the new speed — rather than being made longer at the old speed,
    /// which played ten seconds of sound under twenty seconds of picture.
    ///
    /// Captions are moved word by word through the same mapping — see
    /// `CaptionCue.retimed(_:)`. And where `speeds` says what the footage's speed was and
    /// is, a run that played at the old speed is given the new one exactly, rather than
    /// the old one divided by a factor measured off rounded lengths, which drifts.
    static func retimeRegions(_ timeline: inout Timeline, range: CMTimeRange, newEnd: CMTime,
                              speeds: (was: Double, now: Double)? = nil) {
        let length = range.duration.seconds
        guard length > 0 else { return }
        let factor = (newEnd - range.start).seconds / length
        guard factor > 0, abs(factor - 1) > 1e-9 else { return }
        let delta = newEnd - range.end

        func place(_ time: CMTime) -> CMTime {
            if time <= range.start { return time }
            if time >= range.end { return time + delta }
            return range.start + CMTimeMultiplyByFloat64(time - range.start, multiplier: factor)
        }
        func adjust<Region: TimelineRegion>(_ regions: [Region]) -> [Region] {
            regions.map { region in
                var region = region
                let end = place(region.end)
                region.start = place(region.start)
                region.duration = max(Clip.minimumDuration, end - region.start)
                return region
            }
        }

        timeline.zooms = adjust(timeline.zooms)
        // A followed path is re-timed with the footage under it. See `MaskFollowing`.
        timeline.blurs = MaskFollowing.retimed(adjust(timeline.blurs), from: timeline.blurs,
                                               breaks: [range.start, range.end], place: place)
        timeline.annotations = adjust(timeline.annotations)
        timeline.captions = timeline.captions.map { $0.retimed(place) }
        timeline.audio = adjust(timeline.audio)
        timeline.cursorRegions = adjust(timeline.cursorRegions)
        timeline.keyCues = adjust(timeline.keyCues)
        timeline.cameraLayouts = adjust(timeline.cameraLayouts)

        if let runs = timeline.detachedSound {
            let pieces = runs.flatMap { $0.split(at: [range.start, range.end]) }
            timeline.detachedSound = pieces.map { run in
                var run = run
                let inside = run.start >= range.start && run.end <= range.end
                let end = place(run.end)
                run.start = place(run.start)
                run.duration = max(Clip.minimumDuration, end - run.start)
                if inside {
                    if let speeds, abs(run.speed - speeds.was) < 1e-9 {
                        run.speed = speeds.now
                    } else {
                        run.speed /= factor
                    }
                }
                return run
            }
        }
    }

    /// Drops regions inside a deleted range and pulls the later ones back by its length.
    private static func shiftRegions(_ timeline: inout Timeline, removing range: CMTimeRange) {
        /// - Parameter trimmedHead: told how much was cut off the front of a region that
        ///   began inside the cut, for the kinds whose content has to move with it.
        func adjust<Region: TimelineRegion>(_ regions: [Region],
                                            trimmedHead: (inout Region, CMTime) -> Void = { _, _ in }) -> [Region] {
            regions.compactMap { region in
                var region = region
                if region.start >= range.start && region.end <= range.end { return nil }
                if region.start >= range.end {
                    region.start = region.start - range.duration
                } else if region.end > range.start {
                    // Straddles the cut: keep the part that survived rather than
                    // dropping an effect the user placed deliberately.
                    let overlap = min(region.end, range.end) - max(region.start, range.start)
                    if region.start > range.start {
                        // It began inside the cut, so what is left of it begins where
                        // the cut now is. Left where it was, it started late by however
                        // much of it had been cut: a zoom arrived after its click, a
                        // blur uncovered what it was hiding for that long.
                        trimmedHead(&region, range.end - region.start)
                        region.start = range.start
                    }
                    region.duration = max(Clip.minimumDuration, region.duration - overlap)
                }
                return region
            }
        }

        // The caption's words, placed before the cut changes the cues they are measured
        // against. See `CaptionCue.cut(_:)`.
        let captions = timeline.captions.map { $0.cut(range) }

        timeline.zooms = adjust(timeline.zooms)
        // What was under the cut is gone, so a followed path steps from the moment before
        // it to the moment after it, like the picture does.
        timeline.blurs = MaskFollowing.retimed(adjust(timeline.blurs), from: timeline.blurs,
                                               breaks: [range.start, range.end]) { time in
            time <= range.start ? time : time >= range.end ? time - range.duration : range.start
        }
        timeline.annotations = adjust(timeline.annotations)
        timeline.captions = captions.compactMap { $0 }
        // A sound whose front was cut plays from where the cut ends, not from the start
        // of its file again.
        timeline.audio = adjust(timeline.audio) { region, trimmed in
            region.sourceStart = region.sourceStart + trimmed
        }
        if let runs = timeline.detachedSound {
            // Cut where the picture was cut, so the sound after the cut is still the sound
            // of the picture after it. Shortened instead, a run spanning the cut went on
            // playing the seconds that had been taken out, and fell behind by that much.
            let pieces = runs.flatMap { $0.split(at: [range.start, range.end]) }
            timeline.detachedSound = adjust(pieces) { run, trimmed in
                run.sourceStart = run.sourceStart + CMTimeMultiplyByFloat64(trimmed, multiplier: run.speed)
            }
        }
        timeline.cursorRegions = adjust(timeline.cursorRegions)
        timeline.keyCues = adjust(timeline.keyCues)
        timeline.cameraLayouts = adjust(timeline.cameraLayouts)
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
        // Time taken out before `time` (a negative delta) is a removal, and a path's
        // moments inside it land where it now ends.
        let removedFrom = time + min(delta, .zero)
        timeline.blurs = MaskFollowing.retimed(adjust(timeline.blurs), from: timeline.blurs,
                                               breaks: [removedFrom, time]) { moment in
            moment >= time ? moment + delta : min(moment, removedFrom)
        }
        timeline.annotations = adjust(timeline.annotations)
        // A line spanning the point is stretched like any region, but word by word: the
        // words said after the point are said in the footage after it, and move with that
        // footage. Stretched as a whole, every word in the line slid by a share of the
        // opened time — "um" landed where the words before it are heard.
        timeline.captions = timeline.captions.map { cue in
            guard cue.start < time, cue.end > time else { return adjust([cue])[0] }
            return cue.retimed { $0 >= time ? $0 + delta : $0 }
        }
        timeline.audio = adjust(timeline.audio)
        if let runs = timeline.detachedSound { timeline.detachedSound = adjust(runs) }
        timeline.cursorRegions = adjust(timeline.cursorRegions)
        timeline.keyCues = adjust(timeline.keyCues)
        timeline.cameraLayouts = adjust(timeline.cameraLayouts)
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
        timeline.blurs = MaskFollowing.retimed(adjust(timeline.blurs), from: timeline.blurs) { time in
            anchor + CMTimeMultiplyByFloat64(time - anchor, multiplier: factor)
        }
        timeline.annotations = adjust(timeline.annotations)
        timeline.captions = adjust(timeline.captions)
        timeline.audio = adjust(timeline.audio)
        if let runs = timeline.detachedSound { timeline.detachedSound = adjust(runs) }
        timeline.cursorRegions = adjust(timeline.cursorRegions)
        timeline.keyCues = adjust(timeline.keyCues)
        timeline.cameraLayouts = adjust(timeline.cameraLayouts)
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
        // Cut rather than clamped, so the words said past the end go and the rest keep
        // their moments. Clamped, the line's words were squeezed into what was left of it.
        timeline.captions = clamp(timeline.captions.compactMap { cue in
            cue.end > end ? cue.cut(CMTimeRange(start: end, end: cue.end)) : cue
        })
        timeline.audio = clamp(timeline.audio)
        if let runs = timeline.detachedSound { timeline.detachedSound = clamp(runs) }
        timeline.cursorRegions = clamp(timeline.cursorRegions)
        timeline.keyCues = clamp(timeline.keyCues)
        timeline.cameraLayouts = clamp(timeline.cameraLayouts)
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
