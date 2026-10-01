import CoreGraphics
import Foundation
import RecordKit

/// Where a window recording's picture sat inside its frame over the take, and the part of
/// the frame to show so that nobody sees the black round it.
///
/// A window's file is sized before the countdown and cannot change size afterwards. A
/// window resized after that is scaled by ScreenCaptureKit to fit — shrunk when it grew,
/// left small when it shrank — and whatever the picture no longer covers is black. The
/// recorder writes down where the picture landed each time that changed (`PictureTracker`);
/// this reads it back and answers one question per moment: *which part of the frame is the
/// picture?* The renderer crops the source to that and scales it to fill the frame, and
/// everything placed in the frame's points — the pointer, its clicks, the focus rectangles
/// auto-zoom aims at — is put through the same crop, so it lands on the same pixel it was
/// over.
///
/// Empty for every take whose picture filled its frame throughout, which is every display,
/// every area, most windows and every recording made before this was written down. An
/// empty track answers "the whole frame" everywhere, and the renderer's arithmetic with the
/// whole frame is exactly the arithmetic it did before.
public struct PictureTrack: Sendable, Equatable {
    /// In time order. Each holds from its own `t` until the next one's.
    public let samples: [PictureSample]

    /// The stretches, in recording seconds, when a window recording's window was not the
    /// one in front — another app, or another window, had the person's attention — and
    /// the frame shows black rather than a window left behind. See `WindowPresence`.
    /// Empty for everything but a window recorded since that was written down.
    public let hidden: [ClosedRange<Double>]

    public init(samples: [PictureSample] = [], presence: [PresenceSample] = []) {
        hidden = Self.hiddenStretches(presence)
        // A sample that moves no edge by `noise` or more is the one before it, measured
        // again: kept, it re-crops the picture by a sliver and the whole video shivers.
        // Recordings made before the recorder learnt this are full of them — a window
        // that never changed, flipping between 1511.4 and 1512 points wide.
        var kept: [PictureSample] = []
        for sample in samples.sorted(by: { $0.t < $1.t }) {
            if let last = kept.last, !Self.differs(sample.rect, from: last.rect, by: Self.noise) { continue }
            kept.append(sample)
        }
        self.samples = kept
    }

    /// The smallest move of an edge, in points, that is a resize rather than rounding.
    static let noise: CGFloat = 2

    /// Whether a picture fills its frame, give or take rounding: within 2 points, or a
    /// quarter of a percent of the frame's longer side, on every edge. The one rule the
    /// renderer, the pointer and the masks all go by, so none of them crops for a sliver
    /// the others ignore.
    public static func fillsFrame(_ picture: CGRect, frame: CGSize) -> Bool {
        let noise = max(Self.noise, max(frame.width, frame.height) * 0.002_5)
        return !differs(picture, from: CGRect(origin: .zero, size: frame), by: noise)
    }

    static func differs(_ a: CGRect, from b: CGRect, by tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) >= tolerance || abs(a.minY - b.minY) >= tolerance
            || abs(a.maxX - b.maxX) >= tolerance || abs(a.maxY - b.maxY) >= tolerance
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Whether the window was behind something else at `seconds`, so the frame is black.
    public func isHidden(at seconds: Double) -> Bool {
        hidden.contains { $0.contains(seconds) }
    }

    /// The stretches between each "behind" and the next "in front". One still open at the
    /// end of the take runs on to the end of time, which the recording ends well before.
    static func hiddenStretches(_ presence: [PresenceSample]) -> [ClosedRange<Double>] {
        var stretches: [ClosedRange<Double>] = []
        var behindSince: Double?
        for sample in presence.sorted(by: { $0.t < $1.t }) {
            if !sample.front, behindSince == nil {
                behindSince = sample.t
            } else if sample.front, let since = behindSince {
                if sample.t > since { stretches.append(since...sample.t) }
                behindSince = nil
            }
        }
        if let since = behindSince { stretches.append(since...Double.greatestFiniteMagnitude) }
        return stretches
    }

    /// How far past a sample's time a frame still counts as showing it. A sample is dated
    /// by its frame's own timestamp, which is the time that frame has in the file, so the
    /// two should be equal to the tick; this only absorbs the rounding of a `CMTime` into
    /// seconds and back.
    static let tolerance = 0.000_5

    /// Where the picture sat inside the frame at `seconds`, in the frame's points — or `nil`
    /// before the first sample, where it filled the frame.
    public func picture(at seconds: Double) -> CGRect? {
        // The last sample at or before this moment. Binary, because the renderer asks per
        // frame and a live resize writes a sample per frame for as long as it lasts.
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].t <= seconds + Self.tolerance { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : samples[low - 1].rect
    }

    /// The part of the frame to show at `seconds`, in the frame's points: the picture, cut
    /// to the frame's own shape. The whole frame when the picture fills it.
    public func shown(at seconds: Double, in frame: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: frame)
        guard let picture = picture(at: seconds) else { return whole }
        // A picture within rounding of the whole frame fills it; cropping to it would
        // enlarge the video by a fraction of a percent, and back, each time it flickers.
        guard !Self.fillsFrame(picture, frame: frame) else { return whole }
        return Self.filling(picture, frame: frame)
    }

    /// The largest rectangle of the frame's shape inside `picture`, centred on it.
    ///
    /// Scaled up to the frame, this fills it edge to edge — no black anywhere — and it is
    /// scaled evenly, so nothing is stretched. When the picture already has the frame's
    /// shape, which is the ordinary case (a window that grew or shrank in proportion, or the
    /// picture's shape measured correctly at the start and only its size changing), this is
    /// the picture itself and nothing is lost.
    ///
    /// When the shape changed as well — a window made taller, so it was shrunk to fit the
    /// height and leaves a band down the side — something has to give, and there are three
    /// choices. Stretching it to the frame distorts every letter in it, which is the one
    /// thing a screen recording must not do. Fitting it whole leaves the band, which is
    /// the fault being fixed. Filling it evenly loses a strip off two opposite edges of the
    /// picture — the same strip a crop would — and that is what this does: the loss is
    /// usually a few percent, it is at the picture's edges rather than its middle, and it is
    /// in the one direction the window was changed in, which is the direction its content
    /// has room to spare. Centred rather than anchored to a side, because nothing about a
    /// window says which of its edges matters more.
    ///
    /// A picture of no size, or a frame of none, answers the whole frame: there is nothing
    /// to crop to, and cropping to nothing would draw nothing.
    public static func filling(_ picture: CGRect, frame: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: frame)
        let picture = picture.intersection(whole)
        guard !picture.isNull, picture.width > 0, picture.height > 0,
              frame.width > 0, frame.height > 0 else { return whole }
        let aspect = frame.width / frame.height
        var size = picture.size
        if size.width / size.height > aspect {
            size.width = size.height * aspect
        } else {
            size.height = size.width / aspect
        }
        return CGRect(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Where a point in the recorded frame is drawn once the part shown at `seconds` has
    /// been scaled up to fill the frame.
    ///
    /// For anything recorded in the frame's points — a click, a focus rectangle — that has
    /// to land on what it was over. A point in the black maps outside the frame, which is
    /// right: it was not over the picture.
    public func place(_ point: CGPoint, at seconds: Double, in frame: CGSize) -> CGPoint {
        let shown = shown(at: seconds, in: frame)
        guard shown.width > 0, shown.height > 0 else { return point }
        return CGPoint(x: (point.x - shown.minX) * frame.width / shown.width,
                       y: (point.y - shown.minY) * frame.height / shown.height)
    }

    /// The part of the frame shown at `seconds`, as a fraction of the frame — the unit
    /// square when the picture fills it. `SceneBuilder.pictureCrop(at:)` is the renderer's
    /// version of the same rectangle, rounded inwards to whole pixels; this one is for the
    /// questions asked without pixels to hand (is a click in the picture, is a sighting in
    /// the crop), where a pixel's difference cannot change the answer that matters.
    public func shownFraction(at seconds: Double, in frame: CGSize) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard !isEmpty, frame.width > 0, frame.height > 0 else { return unit }
        let shown = shown(at: seconds, in: frame)
        return CGRect(x: shown.minX / frame.width, y: shown.minY / frame.height,
                      width: shown.width / frame.width, height: shown.height / frame.height)
    }

    /// The picture itself at `seconds` — where the window's content sat, uncut — as a
    /// fraction of the frame; the unit square when it filled the frame.
    ///
    /// What a still mask is measured against: see `BlurRegion.recordingRect(at:source:picture:frame:)`.
    public func pictureFraction(at seconds: Double, in frame: CGSize) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard frame.width > 0, frame.height > 0, let points = picture(at: seconds),
              !Self.fillsFrame(points, frame: frame) else { return unit }
        let picture = points.intersection(CGRect(origin: .zero, size: frame))
        guard !picture.isNull, picture.width > 0, picture.height > 0 else { return unit }
        return CGRect(x: picture.minX / frame.width, y: picture.minY / frame.height,
                      width: picture.width / frame.width, height: picture.height / frame.height)
    }

    /// A rectangle given as a fraction of `part`, as a fraction of the whole — or, the other
    /// way, `inside(_:of:)`. With `part` the unit square both are the rectangle as it is.
    public static func within(_ rect: CGRect, of part: CGRect) -> CGRect {
        CGRect(x: part.minX + rect.minX * part.width, y: part.minY + rect.minY * part.height,
               width: rect.width * part.width, height: rect.height * part.height)
    }

    /// A rectangle of the whole, as a fraction of `part`. See `within(_:of:)`.
    public static func inside(_ rect: CGRect, of part: CGRect) -> CGRect {
        guard part.width > 0, part.height > 0 else { return rect }
        return CGRect(x: (rect.minX - part.minX) / part.width, y: (rect.minY - part.minY) / part.height,
                      width: rect.width / part.width, height: rect.height / part.height)
    }

    /// A rectangle in the recorded frame, placed as `place(_:at:in:)` places a point: its
    /// corner moved and its size scaled with the picture.
    public func place(_ rect: CGRect, at seconds: Double, in frame: CGSize) -> CGRect {
        let shown = shown(at: seconds, in: frame)
        guard shown.width > 0, shown.height > 0 else { return rect }
        let origin = place(rect.origin, at: seconds, in: frame)
        return CGRect(x: origin.x, y: origin.y,
                      width: rect.width * frame.width / shown.width,
                      height: rect.height * frame.height / shown.height)
    }
}
