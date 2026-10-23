import CoreGraphics
import CoreMedia
import Foundation
import Observation
import RenderKit
import TimelineKit

/// What a scan for sensitive text found, offered for hiding one line at a time.
struct SensitiveReview: Equatable {
    struct Item: Identifiable, Equatable {
        let finding: SensitiveFinding
        /// Where it is on the timeline, first moment to last.
        let range: CMTimeRange
        /// Where the Go To button lands: the first moment it was read, rather than the
        /// start of its mask, which begins a couple of frames early on purpose.
        let firstSeen: CMTime
        /// Masks already on the timeline cover it everywhere it was read. Offered unticked,
        /// so scanning again after hiding does not hide everything twice.
        let isHidden: Bool
        var isChosen: Bool

        var id: UUID { finding.id }
    }

    enum State: Equatable {
        /// The recording is being read. How far along is on the job, which changes far
        /// more often than anything else here.
        case scanning
        case ready
        case failed(String)
    }

    /// Room round the text, as a fraction of its height.
    enum Padding: Double, CaseIterable, Identifiable {
        case tight = 0.15
        case normal = 0.35
        case wide = 0.7

        var id: Double { rawValue }

        var title: String {
            switch self {
            case .tight: "Tight"
            case .normal: "Normal"
            case .wide: "Wide"
            }
        }
    }

    /// The kinds of mask that hide. A spotlight shows what it is over, so it is not one.
    static let styles: [BlurRegion.Style] = [.gaussian, .pixelate, .cover]

    var state: State = .scanning
    var items: [Item] = []
    /// Found, but not in the edit: in footage that was cut, or only outside the crop.
    var notShown = 0
    var style: BlurRegion.Style = .gaussian
    var padding: Padding = .normal

    var chosenCount: Int { items.filter(\.isChosen).count }
}

/// Finding sensitive text while it runs, and what was found once it has.
///
/// Its own object, as `MaskFollowingJob` is: one piece of work with one lifetime, which the
/// sheet and the menu bar both watch.
@MainActor
@Observable
final class SensitiveScanJob {
    /// The review sheet's state, while the sheet is up.
    var review: SensitiveReview?
    /// 0…1 while scanning.
    fileprivate(set) var progress: Double = 0
    fileprivate var work: Task<[SensitiveFinding], any Error>?

    var isScanning: Bool { work != nil }

    /// Stops the work and puts the sheet away. Nothing is written.
    func cancel() {
        work?.cancel()
        work = nil
        progress = 0
        review = nil
    }
}

/// Mask › Find Sensitive Information: the recording's text read for addresses, numbers,
/// keys and passwords, and each one found offered for hiding.
///
/// The reading is `SensitiveScanner`'s, off the main thread, kept in the package's
/// `derived` folder so the second look is instant. Nothing changes until Hide, and Hide is
/// one step on the undo stack however many masks it adds.
extension EditorModel {
    var canFindSensitiveInformation: Bool {
        duration > .zero && document.videoURL != nil && sensitive.review == nil
    }

    func findSensitiveInformation() {
        guard canFindSensitiveInformation, let url = document.videoURL else { return }
        let job = sensitive
        let package = document.package
        if let known = SensitiveScanCache.cached(in: package, source: url) {
            job.review = review(of: known)
            return
        }
        job.review = SensitiveReview()
        job.progress = 0
        let work = Task.detached(priority: .userInitiated) {
            let findings = try await SensitiveScanner.scan(videoURL: url) { done in
                Task { @MainActor in
                    guard job.work != nil else { return }
                    job.progress = done
                }
            }
            SensitiveScanCache.cache(findings, in: package, source: url)
            return findings
        }
        job.work = work

        Task {
            let outcome = await work.result
            // Cancelled, or replaced by another run: that one decides what happens.
            guard job.work == work else { return }
            job.work = nil
            job.progress = 0
            switch outcome {
            case .success(let findings):
                guard job.review != nil else { return }
                job.review = review(of: findings)
            case .failure(let error):
                if error is CancellationError { return }
                job.review?.state = .failed("Cue couldn't read the text in the recording. \(error.localizedDescription)")
            }
        }
    }

    /// Adds a mask for every chosen line, as one edit.
    func hideSensitiveInformation() {
        guard let review = sensitive.review else { return }
        let timeline = timeline
        let picture = document.pictureTrack
        let frame = recordedFrame ?? .zero
        let masks = review.items.filter(\.isChosen).flatMap { item in
            item.finding.masks(in: timeline, padding: review.padding.rawValue, videoSize: videoSize, style: review.style,
                               picture: picture, frame: frame)
        }
        sensitive.review = nil
        guard !masks.isEmpty else { return }
        clearSelection()
        apply(Commands.AddMasks(masks, name: "Hide Sensitive Information"))
    }

    func cancelSensitiveScan() {
        sensitive.cancel()
    }

    /// What the sheet lists: everything the edit shows, in the order the edit shows it.
    private func review(of findings: [SensitiveFinding]) -> SensitiveReview {
        var review = SensitiveReview()
        review.state = .ready
        let timeline = timeline
        // Where a resized window's picture sat, so the crop and the masks are measured
        // against what was on screen at each sighting — see `PictureTrack`.
        let picture = document.pictureTrack
        let frame = recordedFrame ?? .zero
        for finding in findings {
            guard finding.isShown(in: timeline, picture: picture, frame: frame), let range = finding.timelineRange(in: timeline) else {
                review.notShown += 1
                continue
            }
            let firstSeen = finding.sightings.lazy
                .compactMap { timeline.timelineTime(atSource: CMTime(seconds: $0.time, preferredTimescale: 600_000)) }
                .first ?? range.start
            let hidden = finding.isHidden(by: timeline.blurs, in: timeline, picture: picture, frame: frame)
            review.items.append(SensitiveReview.Item(finding: finding, range: range, firstSeen: firstSeen,
                                                     isHidden: hidden, isChosen: !hidden))
        }
        review.items.sort { $0.range.start < $1.range.start }
        return review
    }
}
