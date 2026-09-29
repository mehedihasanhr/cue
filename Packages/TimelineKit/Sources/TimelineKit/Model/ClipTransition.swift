import CoreMedia
import Foundation

/// How one clip gives way to the next.
///
/// Centred on the cut: half of it is spent at the end of the clip before and half at the
/// start of the clip after, so the cut stays exactly where it was and nothing on any other
/// lane has to move for a transition to be added, changed or taken away. That is the
/// whole reason it is shaped this way. A transition that overlapped the two clips would
/// shorten the edit by its own length, and every zoom, caption and sound after it would
/// slide off the footage it was placed against.
///
/// A crossfade needs a picture from each side at once, and a clip has no footage beyond
/// its own ends to lend. So each side lends the frame at its edge: the incoming clip's
/// first frame is faded up over the end of the outgoing one, and the outgoing clip's last
/// frame is faded out over the start of the incoming one. A screen recording is mostly
/// still across half a second, so that reads as a crossfade — and it asks nothing of the
/// recording that is not already in the edit.
public struct ClipTransition: Equatable, Codable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// The two pictures blended.
        case crossfade
        /// Out to black, and in from it.
        case dipToBlack
        /// Out to the project's background, and in from it: the picture goes, the frame
        /// around it stays.
        case dipToBackground

        public var title: String {
            switch self {
            case .crossfade: "Crossfade"
            case .dipToBlack: "Dip to Black"
            case .dipToBackground: "Dip to Background"
            }
        }
    }

    public var style: Style
    /// The whole length, both halves.
    public var duration: CMTime

    public static let defaultDuration = CMTime(value: 2, timescale: 5)
    public static let minimumDuration = CMTime(value: 1, timescale: 10)
    /// Longer than this is not a transition between two clips; it is a third thing
    /// happening between them.
    public static let maximumDuration = CMTime(value: 2, timescale: 1)

    public init(_ style: Style, duration: CMTime = ClipTransition.defaultDuration) {
        self.style = style
        self.duration = Self.clamped(duration)
    }

    static func clamped(_ duration: CMTime) -> CMTime {
        guard duration.isNumeric else { return defaultDuration }
        return max(minimumDuration, min(duration, maximumDuration))
    }

    private enum CodingKeys: String, CodingKey { case style, duration }

    /// The style is the transition, so a style this build cannot read throws — and
    /// `Clip` turns that into "a plain cut" for this one clip. A bad length costs only the
    /// length.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let style = try container.decode(Style.self, forKey: .style)
        let duration = ((try? container.decodeIfPresent(CMTime.self, forKey: .duration)) ?? nil)
            ?? Self.defaultDuration
        self.init(style, duration: duration)
    }
}

/// A transition in progress, as the picture and the sound need it.
public struct TransitionMoment: Equatable, Sendable {
    public let style: ClipTransition.Style
    /// Where the cut is on the timeline.
    public let cut: CMTime
    /// The length actually used, which is the one asked for held inside both clips.
    public let duration: CMTime
    /// The clip before the cut and the clip after it.
    public let outgoing: Int
    public let incoming: Int
    /// 0 at the start of the transition, 0.5 at the cut, 1 at its end.
    public let progress: Double

    /// Whether this moment is on the incoming side of the cut.
    public var isAfterCut: Bool { progress >= 0.5 }

    /// How far the picture has gone towards a dip's colour: nothing at either end, all of
    /// it at the cut.
    public var dip: Double { 1 - abs(progress - 0.5) * 2 }
}

extension Timeline {
    /// The transition into the clip at `index`, in the length it will actually take.
    ///
    /// Held to the shorter of the two clips it joins, so neither half can reach past the
    /// far end of its clip into a third one — a crossfade that ran into the clip before
    /// last would be showing footage that is not next to the cut at all. `nil` on the
    /// first clip, on a plain cut, and where a clip is too short to give any time to it.
    public func transition(into index: Int) -> (style: ClipTransition.Style, duration: CMTime)? {
        guard index > 0, clips.indices.contains(index),
              let transition = clips[index].transition else { return nil }
        let room = min(clips[index - 1].duration, clips[index].duration)
        let duration = min(transition.duration, room)
        guard duration >= ClipTransition.minimumDuration else { return nil }
        return (transition.style, duration)
    }

    /// The transition under a moment, if one is.
    ///
    /// Asked on every frame of the preview and the export, so a project with no
    /// transitions — every project written before they existed — answers after one pass
    /// over the clips that finds none.
    public func transition(at time: CMTime) -> TransitionMoment? {
        guard clips.dropFirst().contains(where: { $0.transition != nil }) else { return nil }
        var cut = CMTime.zero
        for index in clips.indices {
            defer { cut = cut + clips[index].duration }
            guard let (style, duration) = transition(into: index) else { continue }
            let half = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
            let from = cut - half
            guard time >= from, time < cut + half else { continue }
            let progress = (time - from).seconds / duration.seconds
            return TransitionMoment(style: style, cut: cut, duration: duration,
                                    outgoing: index - 1, incoming: index,
                                    progress: min(1, max(0, progress)))
        }
        return nil
    }

    /// Every cut that has a transition, with the length it will take.
    ///
    /// What the sound needs: one ramp down and one ramp up per cut, rather than a
    /// question asked of every sample.
    public var transitions: [TransitionMoment] {
        var moments: [TransitionMoment] = []
        var cut = CMTime.zero
        for index in clips.indices {
            defer { cut = cut + clips[index].duration }
            guard let (style, duration) = transition(into: index) else { continue }
            moments.append(TransitionMoment(style: style, cut: cut, duration: duration,
                                            outgoing: index - 1, incoming: index, progress: 0.5))
        }
        return moments
    }
}
