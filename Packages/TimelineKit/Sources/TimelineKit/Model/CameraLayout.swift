import CoreMedia
import Foundation

/// How the camera and the screen share the frame.
///
/// A choice made over time rather than once: a video opens on the presenter full frame,
/// cuts to the screen with the bubble in a corner for the demonstration, and hides the
/// bubble while something in that corner has to be read. The bubble is what every stretch
/// without a `CameraLayoutRegion` gets, which is what every project written before layouts
/// existed draws.
public enum CameraLayout: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The screen, with the camera in its bubble — `WebcamSettings` says where and how big.
    case bubble
    /// The camera alone, filling the frame inside the padding. The screen is not shown.
    case cameraOnly
    /// The screen and the camera beside each other, each with its own share of the frame.
    case sideBySide
    /// The screen alone. The bubble keeps its place and settings for when it comes back.
    case hidden

    public var id: String { rawValue }

    /// What a menu, a chip and the undo stack call it.
    public var title: String {
        switch self {
        case .bubble: "Bubble"
        case .cameraOnly: "Camera Only"
        case .sideBySide: "Side by Side"
        case .hidden: "Hidden"
        }
    }

    public var symbol: String {
        switch self {
        case .bubble: "person.crop.circle"
        case .cameraOnly: "person.fill"
        case .sideBySide: "rectangle.split.2x1"
        case .hidden: "person.crop.circle.badge.xmark"
        }
    }

    /// Whether the screen is on show in this layout, which is what decides whether the
    /// pointer, the clicks and the picture's shadow are drawn.
    public var showsScreen: Bool { self != .cameraOnly }
}

/// A stretch of the timeline with its own camera layout.
public struct CameraLayoutRegion: TimelineRegion {
    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    public var layout: CameraLayout

    /// Five seconds: long enough to be a stretch you can see and grab on the lane, short
    /// enough that adding one does not quietly take over the rest of the video.
    public static let defaultDuration = CMTime(value: 5, timescale: 1)

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime, layout: CameraLayout) {
        self.id = id
        self.start = start
        self.duration = duration
        self.layout = layout
    }

    /// Field by field, for the reason `Timeline.init(from:)` gives. A layout this build
    /// has never heard of — written by a newer one — reads as the bubble, which is what
    /// the stretch would have shown without the region at all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: .zero)
        layout = value(.layout, default: .bubble)
    }

    enum CodingKeys: String, CodingKey {
        case id, start, duration, layout
    }
}

/// The layout on screen at one moment: settled, or on its way from one to another.
public struct CameraLayoutState: Equatable, Sendable {
    public var from: CameraLayout
    public var to: CameraLayout
    /// How far from `from` to `to`, 0…1, already eased — a renderer blends by this and
    /// nothing else, so the curve is decided once.
    public var progress: Double

    public init(from: CameraLayout, to: CameraLayout, progress: Double) {
        self.from = from
        self.to = to
        self.progress = min(1, max(0, progress))
    }

    /// One layout, fully in force.
    public static func steady(_ layout: CameraLayout) -> CameraLayoutState {
        CameraLayoutState(from: layout, to: layout, progress: 1)
    }

    /// Whether nothing is moving: one layout, all the way there.
    public var isSteady: Bool { from == to || progress >= 1 }

    /// The layout this moment is closer to. What the inspector names and what the bubble
    /// handle on the preview asks about.
    public var nearest: CameraLayout { progress >= 0.5 ? to : from }

    /// How much of the pair is `layout`, 0…1. Both ends at once when they are the same.
    public func share(of layout: CameraLayout) -> Double {
        (from == layout ? 1 - progress : 0) + (to == layout ? progress : 0)
    }
}

public extension Timeline {
    /// How long a change of layout takes, in seconds.
    ///
    /// About a third of a second: long enough to read as the camera *moving* rather than
    /// as a cut, short enough not to hold up what the change was for.
    static let cameraLayoutTransition = 0.35

    /// The camera layout at a moment.
    ///
    /// Stateless, like everything the renderer asks: worked out from the lane and the time
    /// alone, so scrubbing to a frame and playing to it give the same answer.
    ///
    /// **Which region wins.** Where regions overlap, the one that starts later — it is the
    /// one added on top, and the one being looked at. Everywhere else it is the bubble.
    ///
    /// **Where a change happens.** Every change is animated, and every animation happens
    /// *inside a region's chip*: arriving in a region, its layout comes in over the first
    /// third of a second of it; leaving a region for the bubble, the bubble comes back over
    /// its last third of a second. So a stretch marked "Camera Only" is fully camera-only
    /// from just after it starts until just before it ends, and nothing it does leaks onto
    /// the stretch beside it. Two regions side by side change straight from one layout to
    /// the other, inside the later one, rather than stopping at the bubble on the way.
    ///
    /// A short region shares itself between its two changes — neither may take more than
    /// half of it — which is the rule `ZoomRegion.transition` follows. A region starting at
    /// the very beginning of the video has nothing to arrive from, so it is simply there.
    func cameraLayout(at time: CMTime) -> CameraLayoutState {
        guard !cameraLayouts.isEmpty else { return .steady(.bubble) }
        let segments = CameraLayoutSegment.segments(of: cameraLayouts)
        let t = time.seconds
        guard t.isFinite,
              let index = segments.lastIndex(where: { $0.start <= t }) else {
            return .steady(segments.first?.layout ?? .bubble)
        }
        let segment = segments[index]
        let length = segment.end - segment.start
        let ramp = min(Self.cameraLayoutTransition, length / 2)
        guard ramp > 0 else { return .steady(segment.layout) }

        // Arriving: from whatever came before, inside this region.
        if index > 0, segment.isRegion, !(segment.start <= 0 && !segments[index - 1].isRegion) {
            let into = t - segment.start
            if into < ramp {
                return CameraLayoutState(from: segments[index - 1].layout, to: segment.layout,
                                         progress: Easing.easeInOut.apply(into / ramp))
            }
        }
        // Leaving for the bubble: back to it, inside this region.
        if index + 1 < segments.count, segment.isRegion, !segments[index + 1].isRegion {
            let left = segment.end - t
            if left < ramp {
                return CameraLayoutState(from: segment.layout, to: segments[index + 1].layout,
                                         progress: Easing.easeInOut.apply(1 - left / ramp))
            }
        }
        return .steady(segment.layout)
    }

    /// The region the camera lane has in force at a moment, if any — the later-starting one
    /// where two overlap, as `cameraLayout(at:)` reads them.
    func cameraLayoutRegion(at time: CMTime) -> CameraLayoutRegion? {
        CameraLayoutSegment.winner(in: cameraLayouts, at: time.seconds)
    }
}

/// A stretch of the timeline where one layout is in force, ends included.
///
/// Worked in seconds rather than `CMTime` because the arithmetic is comparisons and a
/// division, and a camera change a microsecond off is not something anybody can see.
struct CameraLayoutSegment: Equatable {
    var start: Double
    var end: Double
    var layout: CameraLayout
    /// Whether any of this stretch is a region, as opposed to the bubble every stretch
    /// without one gets. A change animates inside the side that is a region.
    var isRegion: Bool

    /// The whole timeline as layouts, from minus infinity to plus infinity, neighbours with
    /// the same layout merged — so a region saying "bubble" next to plain bubble is not a
    /// change, and animates nothing.
    static func segments(of regions: [CameraLayoutRegion]) -> [CameraLayoutSegment] {
        let edges = Set(regions.flatMap { [$0.start.seconds, $0.end.seconds] }.filter(\.isFinite)).sorted()
        var bounds = [-Double.infinity] + edges + [Double.infinity]
        if bounds.count < 2 { bounds = [-Double.infinity, Double.infinity] }

        var segments: [CameraLayoutSegment] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) where end > start {
            // Asked in the middle of the stretch, or just inside a half-open end: every
            // region edge is a bound, so nothing changes inside it.
            let probe: Double = switch (start.isFinite, end.isFinite) {
            case (true, true): (start + end) / 2
            case (false, true): end - 1
            case (true, false): start + 1
            case (false, false): 0
            }
            let region = winner(in: regions, at: probe)
            let piece = CameraLayoutSegment(start: start, end: end,
                                            layout: region?.layout ?? .bubble,
                                            isRegion: region != nil)
            if var last = segments.last, last.layout == piece.layout {
                last.end = piece.end
                last.isRegion = last.isRegion || piece.isRegion
                segments[segments.count - 1] = last
            } else {
                segments.append(piece)
            }
        }
        return segments
    }

    /// The region in force at a moment: the latest to start among those containing it.
    /// Equal starts go to the one later in the lane, which is the one added later.
    static func winner(in regions: [CameraLayoutRegion], at seconds: Double) -> CameraLayoutRegion? {
        var best: CameraLayoutRegion?
        for region in regions where region.start.seconds <= seconds && seconds < region.end.seconds {
            if let current = best, current.start.seconds > region.start.seconds { continue }
            best = region
        }
        return best
    }
}
