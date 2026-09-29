import CoreImage
import CoreMedia
import Foundation
import TimelineKit

/// Works out where a mask has to go to stay on what it covers.
///
/// From the playhead forwards to the mask's end, and back to its start, one frame of the
/// recording at a time — see `ContentTracker` for how a frame is followed and why that
/// way. The answer is a `MaskPath` in the recording's own coordinates, so a crop and a
/// zoom treat it exactly as they treat a still mask, and it is drawn by `SceneBuilder`
/// like any other mask: the preview and the export cannot disagree about it.
///
/// Reads the file straight through with the exporter's reader rather than seeking, so a
/// long mask costs one decode per frame; the backwards half reads short stretches forwards
/// and walks each one back.
public enum MaskFollower {
    /// Where following starts, and the path from there.
    public struct Result: Equatable, Sendable {
        /// The mask where it is at the playhead: the `rect` the path is measured from.
        public var rect: CGRect
        public var path: MaskPath
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The playhead is not over the mask.
        case notAtPlayhead
        /// What is under the mask is a flat colour: there is nothing to follow.
        case nothingToFollow
        /// The recording could not be read.
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notAtPlayhead: "Move the playhead over the mask, then try again."
            case .nothingToFollow: "There is nothing under this mask to follow. Put it over text or a picture."
            case .unreadable(let reason): "The recording could not be read. \(reason)"
            }
        }
    }

    /// The largest picture followed in. A 4K frame followed at full size costs four times as
    /// much and moves the mask by the same whole pixels a half-size one does, less one.
    static let workingSize = CGSize(width: 1_920, height: 1_200)
    /// Frames read at a time on the way back.
    static let backwardsStretch = 30

    /// Follows `mask` from `time`.
    ///
    /// - Parameters:
    ///   - frameRate: how often to look, per second — the recording's own rate. Following
    ///     is done on the timeline's frames at this rate, which are the frames an export at
    ///     this rate (or half of it) draws, so the mask is exact on every one of them.
    ///   - progress: 0…1, called from whatever thread the work is on.
    /// - Throws: `Failure`, or `CancellationError` when the task is cancelled.
    public static func follow(_ mask: BlurRegion, in timeline: Timeline, from time: CMTime,
                              videoURL: URL, frameRate: Double,
                              progress: @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        guard mask.contains(time) || time == mask.start else { throw Failure.notAtPlayhead }
        let reader: ExportFrameReader
        do {
            reader = try await ExportFrameReader(url: videoURL)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        defer { reader.cancel() }
        let size = await reader.naturalSize()
        guard size.width >= 1, size.height >= 1 else { throw Failure.unreadable("It has no picture.") }
        let scale = min(1, workingSize.width / size.width, workingSize.height / size.height)
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

        let step = 1 / min(max(frameRate.isFinite ? frameRate : 60, 10), 120)
        let first = Int((mask.start.seconds / step - 1e-6).rounded(.up))
        let last = max(first, Int(((mask.end.seconds - 1e-6) / step).rounded(.down)))
        let origin = min(max(Int((time.seconds / step + 1e-6).rounded(.down)), first), last)
        let total = max(1, last - first)
        var done = 0
        // A hundred reports at most: a report per frame is a hop to the main thread per
        // frame, for a bar that moves by a fraction of a pixel.
        var reported = -1.0
        func report() {
            let fraction = min(1, Double(done) / Double(total))
            guard fraction - reported >= 0.01 || fraction == 1 else { return }
            reported = fraction
            progress(fraction)
        }

        func seconds(_ index: Int) -> Double { Double(index) * step }
        func plane(_ index: Int) throws -> LumaPlane? {
            // Half a millisecond late, as `FrameSource` asks: `k / rate` in seconds is a
            // hair short of the frame's own timestamp often enough to be handed the frame
            // before — which then looks like the content standing still for a frame.
            let moment = CMTime(seconds: seconds(index) + 0.000_5, preferredTimescale: 600_000)
            // Content is followed through the recording only: an imported clip is another
            // file's picture, and following stops where one begins, as it does where the
            // picture runs out.
            guard timeline.mediaTime(at: moment)?.source == nil else { return nil }
            let source = timeline.sourceTime(at: moment) ?? moment
            do {
                guard let frame = try reader.frame(at: source) else { return nil }
                return LumaPlane(frame, scale: scale, context: context)
            } catch {
                throw Failure.unreadable(error.localizedDescription)
            }
        }

        guard let start = try plane(origin) else { throw Failure.unreadable("There is no picture at the playhead.") }
        let shown = mask.rect(at: time)
        let startRect = PixelRect(x: Int((shown.minX * CGFloat(start.width)).rounded()),
                                  y: Int((shown.minY * CGFloat(start.height)).rounded()),
                                  width: max(4, Int((shown.width * CGFloat(start.width)).rounded())),
                                  height: max(4, Int((shown.height * CGFloat(start.height)).rounded())))
        guard let tracker = ContentTracker(plane: start, rect: startRect) else { throw Failure.nothingToFollow }

        func offset(of rect: PixelRect) -> CGVector {
            CGVector(dx: Double(rect.x - startRect.x) / Double(start.width),
                     dy: Double(rect.y - startRect.y) / Double(start.height))
        }
        let regionStart = mask.start.seconds
        var samples = [MaskPath.Sample(time: seconds(origin) - regionStart, offset: .zero)]
        var losses: [Double] = []

        // Forwards, to the end of the mask.
        var ahead = tracker
        var index = origin + 1
        while index <= last {
            try Task.checkCancellation()
            guard let next = try plane(index) else { break }
            done += 1
            report()
            guard case .found(let rect) = ahead.step(to: next) else {
                losses.append(seconds(index) - regionStart)
                break
            }
            samples.append(MaskPath.Sample(time: seconds(index) - regionStart, offset: offset(of: rect)))
            index += 1
        }
        done = max(done, last - origin)
        report()

        // Backwards, to its start: a short stretch read forwards, then walked back.
        var behind = tracker
        var high = origin - 1
        backwards: while high >= first {
            let low = max(first, high - backwardsStretch + 1)
            var stretch: [LumaPlane?] = []
            for index in low...high {
                try Task.checkCancellation()
                stretch.append(try plane(index))
            }
            for index in stride(from: high, through: low, by: -1) {
                try Task.checkCancellation()
                done += 1
                report()
                guard let frame = stretch[index - low] else { break backwards }
                guard case .found(let rect) = behind.step(to: frame) else {
                    losses.append(seconds(index) - regionStart)
                    break backwards
                }
                samples.append(MaskPath.Sample(time: seconds(index) - regionStart, offset: offset(of: rect)))
            }
            high = low - 1
        }
        done = total
        report()

        // Half a pixel of the picture followed in: below that a straight line is as good as
        // the frames, and anything that wiggles less is noise. Half the mask in one frame is
        // a jump, kept as a step; a fast scroll moves less than that and stays a line.
        let tolerance = CGVector(dx: 0.6 / Double(start.width), dy: 0.6 / Double(start.height))
        let jump = CGVector(dx: max(shown.width / 2, 24 / Double(start.width)),
                            dy: max(shown.height / 2, 24 / Double(start.height)))
        let path = MaskPath(samples: samples, losses: losses, tolerance: tolerance, jump: jump)
        return Result(rect: shown, path: path)
    }
}
