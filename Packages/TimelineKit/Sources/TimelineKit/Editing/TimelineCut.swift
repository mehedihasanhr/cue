import CoreMedia
import Foundation

public extension Timeline {
    /// The edit between two moments, as an edit of its own that starts at zero.
    ///
    /// What exporting part of a video exports. The promise is that frame *n* of the
    /// excerpt is frame *n + offset* of the whole video, sound included — the part someone
    /// watched and chose, not a re-edit of it — and every rule below serves that:
    ///
    /// - **Clips are cut exactly** at both ends, whatever cut lands inside a clip. This is
    ///   not `ClipSequence.split`, which refuses a sliver shorter than a tenth of a second
    ///   because nobody can grab one on the timeline; an export has nothing to grab and a
    ///   sliver is simply the first few frames.
    /// - **Sound is cut in step.** A run of the recording's own sound and an imported sound
    ///   both keep the place in their file that plays at each surviving moment, which means
    ///   an in-point advanced by exactly what was cut off the front. Both are cut at the
    ///   edges rather than left hanging, because the mixdown lays them into a composition
    ///   that has no time before zero and would otherwise run past the picture.
    /// - **Zooms are kept whole**, only moved. A zoom cut in the middle of its ramp has to
    ///   go on ramping from where it was rather than starting again from the whole
    ///   picture, and the camera between two zooms depends on both of them — a zoom that
    ///   ended just before the excerpt may be the very one the camera is still travelling
    ///   from at its first frame. Left where they were relative to the new zero, so the
    ///   lane is the same lane, a zoom may now begin before zero or end after the excerpt
    ///   does; the renderer asks nothing of a region that either breaks.
    /// - **Everything else on the picture keeps its timing too** — a caption that was on
    ///   screen is on screen from the first frame rather than fading in again, an
    ///   annotation mid-entrance is mid-entrance — and what never overlaps the excerpt is
    ///   dropped, since nothing could ask about it.
    ///
    /// An empty range has no edit in it to give back, so it gives back this one unchanged;
    /// the export sheet never offers one.
    func cut(to range: CMTimeRange) -> Timeline {
        let start = max(.zero, min(range.start, duration))
        let end = max(start, min(range.end, duration))
        guard end > start else { return self }

        var cut = self

        var kept: [Clip] = []
        var elapsed = CMTime.zero
        for clip in clips {
            let clipEnd = elapsed + clip.duration
            let from = max(elapsed, start)
            let to = min(clipEnd, end)
            if to > from {
                // A freeze frame or a title cut into keeps holding the same thing, for the
                // part of it inside the excerpt. See `Clip.piece(from:to:)`.
                kept.append(clip.piece(from: from - elapsed, to: to - elapsed))
            }
            elapsed = clipEnd
        }
        cut.clips = kept

        /// Moved onto the excerpt's clock, and kept only where it could be asked about.
        func moved<Region: TimelineRegion>(_ regions: [Region], droppingOutside: Bool) -> [Region] {
            regions.compactMap { region in
                if droppingOutside, region.end <= start || region.start >= end { return nil }
                var region = region
                region.start = region.start - start
                return region
            }
        }

        cut.zooms = moved(zooms, droppingOutside: false)
        cut.blurs = moved(blurs, droppingOutside: true)
        cut.annotations = moved(annotations, droppingOutside: true)
        cut.captions = moved(captions, droppingOutside: true)
        cut.cursorRegions = moved(cursorRegions, droppingOutside: true)
        // The shortcuts were left out of this list when their lane arrived, so an exported
        // selection drew every one of them at its time in the *whole* video — keys pressed
        // a minute in turned up a minute into a ten-second excerpt, and the ones inside it
        // were missing.
        cut.keyCues = moved(keyCues, droppingOutside: true)
        // Kept whole and only moved, like the zooms, and for their reason: the layout at
        // the excerpt's first frame can be half-way through a change that began before it,
        // and the region it is changing *from* has to still be there to say so.
        cut.cameraLayouts = moved(cameraLayouts, droppingOutside: false)

        cut.audio = audio.compactMap { region in
            let from = max(region.start, start)
            let to = min(region.end, end)
            guard to > from else { return nil }
            // A copy with its place changed rather than a new region spelled out field by
            // field: that spelling dropped the fades, and would have dropped anything
            // added to a sound after it was written.
            var kept = region
            kept.start = from - start
            kept.duration = to - from
            kept.sourceStart = region.sourceStart + (from - region.start)
            // Its fades as the full edit plays them: part-way through, where the excerpt
            // starts or ends inside one.
            kept.leadIn = region.leadIn + (from - region.start).seconds
            kept.leadOut = region.leadOut + (region.end - to).seconds
            return kept
        }
        cut.detachedSound = detachedSound.map { runs in
            runs.compactMap { run in
                let from = max(run.start, start)
                let to = min(run.end, end)
                guard to > from else { return nil }
                return SoundRun(id: run.id,
                                start: from - start,
                                duration: to - from,
                                sourceStart: run.sourceTime(atOffset: from - run.start),
                                speed: run.speed)
            }
        }
        return cut
    }
}
