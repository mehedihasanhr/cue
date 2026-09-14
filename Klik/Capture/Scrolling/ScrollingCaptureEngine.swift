import os
import CoreGraphics

/// A slice of one captured frame that contributes rows to the stitched result.
nonisolated struct StitchPiece: Sendable {
    let frame: Bitmap
    var from: Int
    var rows: Int
}

/// Incremental stitcher: feed it every frame captured from the region while the
/// content scrolls (by Klik or by the user, up or down) and it keeps a growing,
/// gap-free list of pieces.
///
/// The engine tracks where the most recent frame sits inside the stitched result.
/// Frames that only show already-captured rows (scrolling back over them) move that
/// position without adding anything; frames that reach past the top or bottom
/// contribute exactly the rows that are new. Sticky headers/footers reported by
/// `FrameStitcher` are dropped from the later frame so they appear once.
nonisolated final class ScrollingCaptureEngine {
    enum Ingest {
        case first
        case appended
        case prepended
        /// The frame lies entirely within what was captured already.
        case covered
        case unchanged
        case unmatched
    }

    private(set) var pieces: [StitchPiece] = []
    private var lastFrame: Bitmap?
    /// Stitched row at which `lastFrame`'s row 0 sits.
    private var lastTop = 0
    private var unmatchedStreak = 0
    /// Overlap predicted for the next frame — the last verified shift, i.e. scroll velocity.
    private var expectedOverlap: Int

    /// Consecutive unmatched frames before the engine re-syncs on the newest frame,
    /// assuming it sits at the bottom of what was captured (the user jumped ahead).
    private static let resyncAfter = 6

    init(expectedOverlap: Int) {
        self.expectedOverlap = expectedOverlap
    }

    var frameCount: Int { pieces.count }
    var totalRows: Int { pieces.reduce(0) { $0 + $1.rows } }

    func ingest(_ frame: Bitmap) -> Ingest {
        guard let last = lastFrame else {
            lastFrame = frame
            lastTop = 0
            pieces = [StitchPiece(frame: frame, from: 0, rows: frame.height)]
            return .first
        }
        if FrameStitcher.framesMatch(last, frame) {
            return .unchanged
        }

        let down = FrameStitcher.overlap(previous: last, next: frame, expected: expectedOverlap)
        if down.verified {
            unmatchedStreak = 0
            lastFrame = frame
            expectedOverlap = down.overlap
            return moveDown(frame, match: down)
        }
        let up = FrameStitcher.overlap(previous: frame, next: last, expected: expectedOverlap)
        if up.verified {
            unmatchedStreak = 0
            lastFrame = frame
            expectedOverlap = up.overlap
            return moveUp(frame, match: up)
        }

        unmatchedStreak += 1
        if unmatchedStreak >= Self.resyncAfter {
            Log.capture.notice("Scrolling capture: \(self.unmatchedStreak) unmatched frames; re-syncing on the latest frame")
            lastFrame = frame
            lastTop = totalRows - frame.height
            unmatchedStreak = 0
        }
        return .unmatched
    }

    /// The full-resolution stitched result.
    func compose() -> Bitmap? {
        FrameStitcher.compose(pieces)
    }

    // MARK: - Position bookkeeping

    /// `frame` is below `lastFrame` by `height − overlap` rows.
    private func moveDown(_ frame: Bitmap, match: FrameStitcher.Match) -> Ingest {
        let newTop = lastTop + frame.height - match.overlap
        lastTop = newTop
        let total = totalRows
        guard newTop + frame.height > total else { return .covered }

        // Existing content ends where the new frame's content begins (just below its
        // sticky header); anything past that — including a sticky footer — is replaced.
        let cut = min(newTop + match.header, total)
        trimBottom(to: cut)
        let from = max(match.header, cut - newTop)
        pieces.append(StitchPiece(frame: frame, from: from, rows: frame.height - from))
        return .appended
    }

    /// `frame` is above `lastFrame` by `height − overlap` rows.
    private func moveUp(_ frame: Bitmap, match: FrameStitcher.Match) -> Ingest {
        let newTop = lastTop - (frame.height - match.overlap)
        guard newTop < 0 else {
            lastTop = newTop
            return .covered
        }

        // The new frame supplies everything down to where the existing top piece's content
        // begins (its sticky header, if still present, is replaced), but never its own
        // sticky footer.
        let contentStart = max(0, match.header - (pieces.first?.from ?? 0))
        var rows = contentStart - newTop
        rows = min(rows, frame.height - match.footer)
        rows = max(rows, -newTop)
        trimTop(to: newTop + rows)   // stitched rows [0, newTop + rows) are now supplied by the new frame
        pieces.insert(StitchPiece(frame: frame, from: 0, rows: rows), at: 0)
        lastTop = 0
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
