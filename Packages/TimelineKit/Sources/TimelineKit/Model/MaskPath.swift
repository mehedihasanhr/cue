import CoreGraphics
import Foundation

/// Where a mask goes while it follows what it covers.
///
/// A still mask is one rectangle for its whole stretch. A mask that follows its content is
/// the same rectangle moved about: `BlurRegion.rect` is where it is at the moment the
/// following was worked out from, and each key says how far it has moved from there. So
/// the size is the region's own, and dragging or resizing the mask on the picture moves
/// every moment of the path with it — it is still one rectangle, placed differently.
///
/// **Coordinates.** Offsets are fractions of the *recording*, top-left origin, exactly like
/// `BlurRegion.rect` — so a crop and a zoom treat a moving mask exactly as they treat a
/// still one.
///
/// **Time.** Seconds from the start of the region, not of the timeline, so a copy, a paste
/// and a move carry the path with the region without anything having to say so. Edits that
/// take footage out from under a region re-time it: see `MaskFollowing.retimed`.
///
/// **Keys.** Only where the motion changes: a straight scroll is two keys however long it
/// lasts, and the path is straight lines between them. Two keys at the same moment are a
/// step — the first is where it was up to then, the second where it is from then on —
/// which is how a jump in the picture is kept a jump rather than a slide.
public struct MaskPath: Codable, Equatable, Sendable {
    public struct Key: Codable, Equatable, Sendable {
        /// Seconds from the start of the region.
        public var time: Double
        /// How far the mask is from `BlurRegion.rect`, as a fraction of the recording.
        public var offset: CGVector

        public init(time: Double, offset: CGVector) {
            self.time = time
            self.offset = offset
        }

        /// Three short keys rather than a nested vector: a path can hold a few hundred of
        /// these and the project file is read by a person now and then.
        enum CodingKeys: String, CodingKey { case t, x, y }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            time = try container.decode(Double.self, forKey: .t)
            offset = CGVector(dx: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0,
                              dy: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(time, forKey: .t)
            try container.encode(Double(offset.dx), forKey: .x)
            try container.encode(Double(offset.dy), forKey: .y)
        }

        var isFinite: Bool { time.isFinite && offset.dx.isFinite && offset.dy.isFinite }
    }

    /// In time order. See `init(keys:losses:)`.
    public private(set) var keys: [Key]
    /// Where following gave up and the mask held still, in seconds from the start of the
    /// region. At most one going forwards and one going back from where it began; kept so
    /// the panel can say where to look.
    public private(set) var losses: [Double]

    /// Keys are put in time order, keeping the order of two at the same moment — that
    /// order is what makes the pair a step. Anything not a number is dropped: one bad key
    /// costs the path that key, not the mask its path.
    public init(keys: [Key], losses: [Double] = []) {
        let finite = keys.filter(\.isFinite)
        let sorted = zip(finite, finite.dropFirst()).allSatisfy { $0.time <= $1.time }
        self.keys = sorted ? finite : finite.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        self.losses = losses.filter(\.isFinite).sorted()
    }

    /// Decoded key by key, so one unreadable key is skipped rather than costing the mask
    /// its whole path — and a path with nothing readable left decodes as empty, which
    /// `BlurRegion` reads as a still mask.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = (try? container.decodeIfPresent([Lenient<Key>].self, forKey: .keys)) ?? nil
        let losses = (try? container.decodeIfPresent([Lenient<Double>].self, forKey: .losses)) ?? nil
        self.init(keys: (keys ?? []).compactMap(\.value), losses: (losses ?? []).compactMap(\.value))
    }

    enum CodingKeys: String, CodingKey { case keys, losses }

    public var isEmpty: Bool { keys.isEmpty }

    /// How far the mask has moved at `time`, in seconds from the start of the region.
    ///
    /// Straight lines between keys, held flat before the first and after the last — so a
    /// region made longer than the stretch that was followed stays where following left it
    /// rather than drifting off on a guess.
    public func offset(at time: Double) -> CGVector {
        guard let first = keys.first, let last = keys.last else { return .zero }
        guard time >= first.time else { return first.offset }
        guard time < last.time else { return last.offset }
        // The last key at or before `time`. Of two at the same moment that is the second,
        // which is what makes the pair a step.
        var low = 0
        var high = keys.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if keys[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        let a = keys[low]
        let b = keys[low + 1]
        let span = b.time - a.time
        guard span > 0 else { return b.offset }
        let f = (time - a.time) / span
        return CGVector(dx: a.offset.dx + (b.offset.dx - a.offset.dx) * f,
                        dy: a.offset.dy + (b.offset.dy - a.offset.dy) * f)
    }

    /// A value that decodes to `nil` instead of throwing, so an array of them survives one
    /// bad element.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }
}
