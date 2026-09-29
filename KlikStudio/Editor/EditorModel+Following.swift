import CoreGraphics
import CoreMedia
import Foundation
import Observation
import RenderKit
import TimelineKit

/// Following a mask's content while it runs: which mask, how far along, and how to stop it.
///
/// Its own object rather than a few more properties on `EditorModel`, because it is one
/// piece of work with one lifetime — started, reported on, finished or cancelled — and the
/// inspector and the menu bar both watch it.
@MainActor
@Observable
final class MaskFollowingJob {
    /// The mask being followed, while it is.
    fileprivate(set) var maskID: UUID?
    /// 0…1.
    fileprivate(set) var progress: Double = 0
    fileprivate var work: Task<MaskFollower.Result, any Error>?

    var isRunning: Bool { maskID != nil }

    /// Stops the work. Nothing is written: the mask stays as it was before it started.
    func cancel() {
        work?.cancel()
        work = nil
        maskID = nil
        progress = 0
    }
}

/// Masks that follow what they cover. See `MaskFollower` for how, and `MaskPath` for what
/// is stored.
///
/// The work runs off the main thread, reports how far it has got, and can be cancelled at
/// any point; nothing reaches the document until it has finished, and then it arrives as
/// one edit — "Follow Content" — that one Undo takes away.
extension EditorModel {
    /// Why the selected mask cannot be followed right now, in words for the panel — or
    /// `nil` when it can.
    var whyMaskCannotFollow: String? {
        guard let mask = selectedMask else { return "Select a mask first." }
        if following.isRunning { return "Already following a mask." }
        if document.videoURL == nil { return "This recording's video file is missing." }
        if !mask.contains(playhead) { return "Move the playhead over the mask first." }
        return nil
    }

    var canFollowSelectedMask: Bool { whyMaskCannotFollow == nil }

    /// Follows the selected mask's content from the playhead to both of its ends.
    func followSelectedMask() {
        guard canFollowSelectedMask, let mask = selectedMask, let url = document.videoURL else { return }
        let timeline = timeline
        let from = playhead
        let rate = 1 / frameDuration
        let job = following

        job.maskID = mask.id
        job.progress = 0
        let work = Task.detached(priority: .userInitiated) {
            try await MaskFollower.follow(mask, in: timeline, from: from, videoURL: url, frameRate: rate) { done in
                Task { @MainActor in
                    guard job.maskID == mask.id else { return }
                    job.progress = done
                }
            }
        }
        job.work = work

        Task {
            let outcome = await work.result
            // Cancelled, or replaced by another run: that one decides what happens.
            guard job.work == work else { return }
            job.work = nil
            job.maskID = nil
            job.progress = 0
            switch outcome {
            case .success(let result):
                finishFollowing(mask, from: from, over: timeline, with: result)
            case .failure(let error):
                if error is CancellationError { return }
                report(error)
            }
        }
    }

    /// Lands a finished run — unless the edit moved on underneath it, in which case the
    /// path would be for footage or a mask that is no longer there.
    private func finishFollowing(_ mask: BlurRegion, from: CMTime, over followed: Timeline,
                                 with result: MaskFollower.Result) {
        guard let now = timeline.blurs.first(where: { $0.id == mask.id }) else { return }
        guard now.start == mask.start, now.duration == mask.duration,
              now.rect(at: from) == result.rect, timeline.clips == followed.clips else {
            report(EditorProblem("The mask or the footage under it changed while it was being followed. "
                                 + "Choose Follow Content again."))
            return
        }
        apply(Commands.FollowContent(id: mask.id, rect: result.rect, path: result.path))
    }

    /// Stops the run in progress, if there is one.
    func cancelFollowing() {
        following.cancel()
    }

    /// Makes the selected mask still again, where it is at the playhead.
    func stopFollowingSelectedMask() {
        guard let mask = selectedMask, mask.follows else { return }
        apply(Commands.StopFollowing(id: mask.id, at: playhead))
    }

    /// Where the selected mask's following gave up, on the timeline's clock.
    var selectedMaskLosses: [CMTime] {
        guard let mask = selectedMask, let path = mask.path else { return [] }
        // Only the ones inside the mask: a trim can leave one on the part cut away.
        return path.losses.filter { $0 >= 0 && $0 <= mask.duration.seconds }
            .map { mask.start + CMTime(seconds: $0, preferredTimescale: 600) }
    }

    /// Whether a mask is at a moment its following had already given up on: past where it
    /// lost its content going forwards, or before where it lost it going back.
    func hasLostContent(_ mask: BlurRegion, at time: CMTime) -> Bool {
        guard let path = mask.path, let first = path.keys.first?.time, let last = path.keys.last?.time else { return false }
        let offset = (time - mask.start).seconds
        return path.losses.contains { loss in
            (loss > last - 1e-6 && offset >= loss) || (loss < first + 1e-6 && offset <= loss)
        }
    }

    /// Moves or resizes a mask by where it is on the picture now. A following mask takes
    /// its whole path along — see `BlurRegion.rect(showing:at:)`.
    func setMaskRect(_ id: UUID, shown: CGRect) {
        apply(Commands.PlaceMask(id: id, shown: shown, at: playhead))
    }

    var canSplitMask: Bool {
        guard let mask = selectedMask else { return false }
        return mask.split(at: playhead) != nil
    }

    func splitMaskAtPlayhead() {
        guard let mask = selectedMask else { return }
        apply(Commands.SplitMask(id: mask.id, at: playhead))
    }
}
