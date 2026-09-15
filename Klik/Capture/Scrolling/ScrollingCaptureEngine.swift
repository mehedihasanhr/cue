import os
import CoreGraphics

/// A slice of one captured frame that contributes rows to the stitched result.
nonisolated struct StitchPiece: Sendable {
    let frame: Bitmap
    var from: Int
    var rows: Int
}

/// Incremental stitcher: feed it every frame captured from the region while the
/// content scrolls (up or down, by hand) and it keeps a growing, gap-free list of pieces.
///
/// The engine tracks where the most recent frame sits inside the stitched result.
/// Frames that only show already-captured rows (scrolling back over them, the bounce
/// at the end of a page) move that position without adding anything; frames that reach
/// past the top or bottom contribute exactly the rows that are new; frames that changed
/// without scrolling (animations) add nothing. When the matcher cannot place a frame
/// the engine stops adding rows rather than guess, and tries to find the frame in what
/// it has stitched so far to pick up again.
nonisolated final class ScrollingCaptureEngine {
    enum Ingest: Sendable {
        case first
        case appended
        case prepended
        /// The frame lies entirely within what was captured already.
        case covered
        /// Nothing scrolled (the frame may still differ: an animation, a hover state).
        case unchanged
        /// The frame could not be placed; nothing was added.
        case unmatched
        /// The frame has a different size than the first one and was ignored.
        case dropped
    }

    private(set) var pieces: [StitchPiece] = []
    /// First stitched row whose content changed in the last ingest that grew the result;
    /// lets a preview redraw only what is new.
    private(set) var dirtyFrom = 0
    private var lastFrame: Bitmap?
    /// Stitched row at which `lastFrame`'s row 0 sits — meaningful only while `anchored`.
    private var lastTop = 0
    /// `false` once the frame-to-frame matcher lost track; then `lastTop` is unknown and
    /// frames only add rows again after `relocate` finds one in the stitched result.
    private var anchored = true
    private var unmatchedStreak = 0
    private var framesSinceRelocation = 0
    private var failedRelocations = 0
    /// The stitched result as it was when tracking was lost; relocation searches in it.
    private var lostReference: Bitmap?

    /// Consecutive unplaceable frames before the engine looks for the frame in the
    /// whole result instead of relative to the previous frame.
    static let resyncAfter = 6
    private static let relocateEvery = 4
    /// Failed relocations after which a verified *downward* scroll re-anchors the frame
    /// at the bottom of the result: the user moved on to new content, so the capture
    /// continues from there (with a gap, never a repeat).
    static let resumeAfterFailures = 2

    var frameCount: Int { pieces.count }
    var totalRows: Int { pieces.reduce(0) { $0 + $1.rows } }

    func ingest(_ frame: Bitmap) -> Ingest {
        guard let last = lastFrame else {
            lastFrame = frame
            lastTop = 0
            pieces = [StitchPiece(frame: frame, from: 0, rows: frame.height)]
            dirtyFrom = 0
            return .first
        }
        guard frame.width == last.width, frame.height == last.height else {
            Log.capture.notice("Scrolling capture: ignoring a \(frame.width)×\(frame.height) frame (expected \(last.width)×\(last.height))")
            return .dropped
        }
        if FrameStitcher.framesMatch(last, frame) {
            return .unchanged
        }

        switch FrameStitcher.shift(from: last, to: frame) {
        case .none:
            // The page looks different now; later scrolls are measured from this look.
            lastFrame = frame
            return .unchanged

        case .moved(let delta, let seam):
            lastFrame = frame
            unmatchedStreak = 0
            guard anchored else {
                if delta > 0, failedRelocations >= Self.resumeAfterFailures {
                    Log.capture.notice("Scrolling capture: not found in the result; continuing below it")
                    resume(at: totalRows - frame.height)
                    return place(frame, below: totalRows - frame.height + delta, header: seam.header)
                }
                return relocateIfDue(frame)
            }
            let newTop = lastTop + delta
            return delta > 0
                ? place(frame, below: newTop, header: seam.header)
                : place(frame, above: newTop, header: seam.header, footer: seam.footer)

        case .ambiguous:
            unmatchedStreak += 1
            if !anchored { return relocateIfDue(frame) }
            guard unmatchedStreak >= Self.resyncAfter else { return .unmatched }
            Log.capture.notice("Scrolling capture: \(self.unmatchedStreak) frames could not be placed; looking for the frame in the result")
            unmatchedStreak = 0
            lastFrame = frame
            if let placed = relocate(frame) { return placed }
            anchored = false
            lostReference = compose()
            failedRelocations = 1
            framesSinceRelocation = Self.relocateEvery - 1 // try again on the very next frame
            return .unmatched
        }
    }

    /// The full-resolution stitched result.
    func compose() -> Bitmap? {
        FrameStitcher.compose(pieces)
    }

    // MARK: - Relocation

    /// While lost, every few frames: is this frame somewhere in what was captured?
    private func relocateIfDue(_ frame: Bitmap) -> Ingest {
        framesSinceRelocation += 1
        guard framesSinceRelocation >= Self.relocateEvery else { return .unmatched }
        framesSinceRelocation = 0
        if let placed = relocate(frame) { return placed }
        failedRelocations += 1
        return .unmatched
    }

    private func resume(at top: Int) {
        anchored = true
        lostReference = nil
        failedRelocations = 0
        lastTop = top
    }

    /// Finds `frame` in the stitched result and, if found, resumes tracking from there.
    private func relocate(_ frame: Bitmap) -> Ingest? {
        guard let stitched = lostReference ?? compose(),
              let position = FrameStitcher.locate(frame, in: stitched)
        else { return nil }
        Log.capture.info("Scrolling capture: frame found at stitched row \(position); resuming")
        resume(at: position)
        lastFrame = frame
        let top = Int(Double(frame.height) * FrameStitcher.topGuard)
        let bottom = Int(Double(frame.height) * FrameStitcher.bottomGuard)
        if position < 0 {
            return place(frame, above: position, header: top, footer: bottom)
        }
        return place(frame, below: position, header: top)
    }

    // MARK: - Position bookkeeping

    /// `frame`'s row 0 sits at stitched row `newTop` (≥ 0); `header` rows at its top are
    /// not used because the content above supplies them.
    private func place(_ frame: Bitmap, below newTop: Int, header: Int) -> Ingest {
        lastTop = newTop
        let total = totalRows
        guard newTop + frame.height > total else { return .covered }

        // Existing content ends where the new frame's content begins (just below its
        // sticky header); anything past that — including a sticky footer — is replaced.
        let cut = min(newTop + header, total)
        trimBottom(to: cut)
        let from = max(header, cut - newTop)
        pieces.append(StitchPiece(frame: frame, from: from, rows: frame.height - from))
        dirtyFrom = cut
        return .appended
    }

    /// `frame`'s row 0 sits at stitched row `newTop` (< 0 reaches above the result).
    private func place(_ frame: Bitmap, above newTop: Int, header: Int, footer: Int) -> Ingest {
        guard newTop < 0 else {
            lastTop = newTop
            return .covered
        }

        // The new frame supplies everything down to where the existing top piece's content
        // begins (its sticky header, if still present, is replaced), but never its own
        // sticky footer.
        let contentStart = max(0, header - (pieces.first?.from ?? 0))
        var rows = contentStart - newTop
        rows = min(rows, frame.height - footer)
        rows = max(rows, -newTop)
        trimTop(to: newTop + rows)   // stitched rows [0, newTop + rows) are now supplied by the new frame
        pieces.insert(StitchPiece(frame: frame, from: 0, rows: rows), at: 0)
        lastTop = 0
        dirtyFrom = 0
        return .prepended
    }

    /// Drops rows from the end so the result is exactly `end` rows tall.
    private func trimBottom(to end: Int) {
        var total = totalRows
        while total > end, let last = pieces.last {
            let excess = total - end
            if excess >= last.rows {
                pieces.removeLast()
                total -= last.rows
            } else {
                pieces[pieces.count - 1].rows -= excess
                total -= excess
            }
        }
    }

    /// Drops the first `count` rows (rows the prepended frame now supplies).
    private func trimTop(to count: Int) {
        var remaining = count
        while remaining > 0, let first = pieces.first {
            if remaining >= first.rows {
                pieces.removeFirst()
                remaining -= first.rows
            } else {
                pieces[0].from += remaining
                pieces[0].rows -= remaining
                remaining = 0
            }
        }
    }
}
