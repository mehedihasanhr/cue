import CoreGraphics
import CoreMedia
import Foundation

/// Writes down where a window recording's picture sat inside its frame, each time it moved.
///
/// The file is sized from a measured frame before the countdown (`WindowPicture`), and
/// after that its size is fixed — an `AVAssetWriter` cannot change its dimensions halfway
/// through. The window can. Resize it, zoom it, send it full screen, and ScreenCaptureKit,
/// told to `scalesToFit`, keeps all of it in the frame by scaling: a window that grew is
/// shrunk until it fits, one that shrank is left at its smaller size, and the part of the
/// frame the picture no longer covers is black. The pixels cannot say which part that is —
/// a dark window and the padding beside it look the same — but every frame's attachments
/// do, and the editor needs exactly that to crop the black away.
///
/// A class, fed from the capture queue by `ScreenRecorder`, for the same reason
/// `CursorMapper` is: the frame is the only thing that knows, and it is only known there.
/// Every method runs on that queue, which is also the queue `JSONLWriter` wants.
public final class PictureTracker: @unchecked Sendable {
    private let writer: JSONLWriter
    private let clock: RecordingClock
    private var rule: PictureRule

    /// - Parameters:
    ///   - frameSize: the file's frame in points — its pixels over `outputScale`. The space
    ///     every sample is written in, and the one the pointer's samples are in.
    ///   - outputScale: pixels in the file per point of that frame — the recording's
    ///     `displayScale`. A frame's attachments are in the points of whatever display the
    ///     window was on, which is not always this one.
    public init(writer: JSONLWriter, clock: RecordingClock, frameSize: CGSize, outputScale: CGFloat) {
        self.writer = writer
        self.clock = clock
        rule = PictureRule(frame: CGRect(origin: .zero, size: frameSize), outputScale: outputScale)
    }

    /// One complete frame's word on where its picture is. Written only when that differs
    /// from what was last written — see `PictureRule`.
    ///
    /// Dated by the frame's presentation time, through the recording's clock, which is what
    /// the file's own timeline is: a hold is taken out of this exactly as it is taken out of
    /// the picture, and a change made during one is dated to the moment recording resumed.
    public func place(_ frame: FrameGeometry, at time: CMTime) {
        guard let rect = rule.change(for: frame) else { return }
        writer.append(PictureSample(t: clock.elapsed(at: time), rect: rect))
    }
}

/// The rule `PictureTracker` writes by, on its own so it can be checked without a stream.
///
/// It starts out believing the picture fills the frame, because that is what the file was
/// sized for and what a take with no sidecar at all is read as. So a take whose window was
/// never touched writes nothing, the empty file is deleted when it closes, and the manifest
/// does not mention it. From then on a line is written only when some edge of the picture
/// has moved by more than half a point from the last line: a live resize still produces a
/// line per frame, which is the truth, but a picture that shimmers by a rounding error from
/// frame to frame does not fill the file with the same rectangle sixty times a second.
struct PictureRule {
    /// The file's frame in its own points, origin zero.
    let frame: CGRect
    let outputScale: CGFloat
    /// The rectangle last written — or the whole frame, before anything has been.
    private(set) var last: CGRect

    /// How far an edge has to move before it is a change, in points: 2, or a quarter of a
    /// percent of the frame's longer side if that is more.
    ///
    /// It was half a point, and ScreenCaptureKit's content rect is not that steady: a real
    /// take of a window that never changed flipped between 1511.4 and 1512 points wide
    /// twenty times, and each flip re-cropped the picture — the whole video shivering by a
    /// fraction of a pixel. No resize anyone makes is that small.
    var tolerance: CGFloat { max(2, max(frame.width, frame.height) * 0.002_5) }

    init(frame: CGRect, outputScale: CGFloat) {
        self.frame = frame
        self.outputScale = max(outputScale, 0.01)
        last = frame
    }

    /// The rectangle to write for this frame, or `nil` when nothing needs writing.
    mutating func change(for geometry: FrameGeometry) -> CGRect? {
        guard var rect = Self.picture(of: geometry, outputScale: outputScale, in: frame) else { return nil }
        // Within the tolerance of filling the frame is filling it: the rounding above is
        // the only thing that says otherwise.
        if !Self.differs(rect, from: frame, by: tolerance) { rect = frame }
        guard Self.differs(rect, from: last, by: tolerance) else { return nil }
        last = rect
        return rect
    }

    /// Where a frame says its picture is, in the file's points and kept inside the frame.
    ///
    /// The content rect is in the points of the display the window is on, so it goes through
    /// that display's scale into pixels and back out through the file's — the same
    /// conversion `CursorMapper.placement(for:outputScale:)` gives the pointer, so the two
    /// cannot disagree about where the picture's corner is. `nil` for a frame that describes
    /// nothing usable, which leaves the last answer standing.
    static func picture(of geometry: FrameGeometry, outputScale: CGFloat, in frame: CGRect) -> CGRect? {
        guard geometry.scaleFactor > 0, outputScale > 0 else { return nil }
        let ratio = geometry.scaleFactor / outputScale
        let content = geometry.contentRect
        let placed = CGRect(x: content.minX * ratio, y: content.minY * ratio,
                            width: content.width * ratio, height: content.height * ratio)
        let kept = placed.intersection(frame)
        guard !kept.isNull, kept.width >= 1, kept.height >= 1 else { return nil }
        return kept
    }

    static func differs(_ a: CGRect, from b: CGRect, by tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) >= tolerance || abs(a.minY - b.minY) >= tolerance
            || abs(a.maxX - b.maxX) >= tolerance || abs(a.maxY - b.maxY) >= tolerance
    }
}
