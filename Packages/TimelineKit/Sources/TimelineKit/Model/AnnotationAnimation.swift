import CoreGraphics
import Foundation

/// How an annotation arrives and leaves.
///
/// Presets rather than keyframes: "fade in, slide out" is what nearly everybody wants, and
/// it should be two choices rather than four keyframes. Keyframes can come later on top of
/// this; the presets are not a special case of them that has to be migrated.
///
/// Evaluated, never simulated. A pose is a pure function of where in the annotation the
/// playhead is, so scrubbing to a frame gives exactly the frame playing to it would — and
/// the preview and the export, which both ask this, cannot disagree.
public struct AnnotationAnimation: Codable, Equatable, Sendable {
    public enum Entrance: String, Codable, Sendable, CaseIterable {
        case none, fade, scale, pop, slideUp, slideDown, slideLeft, slideRight

        public var title: String {
            switch self {
            case .none: "None"
            case .fade: "Fade"
            case .scale: "Scale"
            case .pop: "Pop"
            case .slideUp: "Slide Up"
            case .slideDown: "Slide Down"
            case .slideLeft: "Slide Left"
            case .slideRight: "Slide Right"
            }
        }
    }

    public enum Exit: String, Codable, Sendable, CaseIterable {
        case none, fade, scale, slideUp, slideDown, slideLeft, slideRight

        public var title: String {
            switch self {
            case .none: "None"
            case .fade: "Fade"
            case .scale: "Scale"
            case .slideUp: "Slide Up"
            case .slideDown: "Slide Down"
            case .slideLeft: "Slide Left"
            case .slideRight: "Slide Right"
            }
        }
    }

    public var entrance: Entrance
    public var exit: Exit
    /// Seconds. Each is held to half the annotation, so an entrance and an exit never
    /// overlap and a short annotation still reaches full strength in its middle.
    public var entranceDuration: Double
    public var exitDuration: Double
    /// The curve both ends travel. The editor's one `Easing`, shared with the zooms, so an
    /// annotation and a zoom that arrive together arrive the same way.
    public var easing: Easing

    /// A quarter-second fade each way — what every annotation did before it could be told
    /// to do anything else, so a project from then renders as it always has.
    public init(entrance: Entrance = .fade,
                exit: Exit = .fade,
                entranceDuration: Double = 0.25,
                exitDuration: Double = 0.25,
                easing: Easing = .linear) {
        self.entrance = entrance
        self.exit = exit
        self.entranceDuration = entranceDuration
        self.exitDuration = exitDuration
        self.easing = easing
        sanitise()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        entrance = value(.entrance, default: .fade)
        exit = value(.exit, default: .fade)
        entranceDuration = value(.entranceDuration, default: 0.25)
        exitDuration = value(.exitDuration, default: 0.25)
        easing = value(.easing, default: .linear)
        sanitise()
    }

    enum CodingKeys: String, CodingKey {
        case entrance, exit, entranceDuration, exitDuration, easing
    }

    /// The longest either end may take, in seconds.
    public static let maximumDuration = 5.0

    mutating func sanitise() {
        entranceDuration = entranceDuration.isFinite ? min(Self.maximumDuration, max(0, entranceDuration)) : 0.25
        exitDuration = exitDuration.isFinite ? min(Self.maximumDuration, max(0, exitDuration)) : 0.25
    }

    /// How far a slide travels, as a fraction of the frame along the way it moves. Far
    /// enough to read as movement, short enough that it reads as arriving rather than as
    /// flying in.
    public static let slideDistance = 0.06

    /// Where the annotation is `offset` seconds into its `duration`.
    public func pose(atOffset offset: Double, of duration: Double) -> AnnotationPose {
        guard duration > 0, offset.isFinite else { return AnnotationPose() }
        let offset = min(duration, max(0, offset))
        var pose = AnnotationPose()

        let inLength = min(entranceDuration, duration / 2)
        if entrance != .none, inLength > 0, offset < inLength {
            let t = offset / inLength
            apply(entrance: entrance, at: t, to: &pose)
        }

        let outLength = min(exitDuration, duration / 2)
        let remaining = duration - offset
        if exit != .none, outLength > 0, remaining < outLength {
            let t = remaining / outLength
            apply(exit: exit, at: t, to: &pose)
        }
        return pose
    }

    /// `t` runs 0 → 1 as the annotation arrives.
    private func apply(entrance: Entrance, at t: Double, to pose: inout AnnotationPose) {
        let eased = easing.apply(t)
        switch entrance {
        case .none:
            break
        case .fade:
            pose.opacity *= eased
        case .scale:
            pose.opacity *= eased
            pose.scale *= 0.6 + 0.4 * eased
        case .pop:
            // Always springy, whatever the chosen curve: a pop without the overshoot is
            // just a scale.
            pose.opacity *= min(1, t * 3)
            pose.scale *= 0.5 + 0.5 * Easing.spring.apply(t)
        case .slideUp:
            pose.opacity *= eased
            pose.offset.dy += Self.slideDistance * (1 - eased)
        case .slideDown:
            pose.opacity *= eased
            pose.offset.dy -= Self.slideDistance * (1 - eased)
        case .slideLeft:
            pose.opacity *= eased
            pose.offset.dx += Self.slideDistance * (1 - eased)
        case .slideRight:
            pose.opacity *= eased
            pose.offset.dx -= Self.slideDistance * (1 - eased)
        }
    }

    /// `t` runs 1 → 0 as the annotation leaves: it is how much of the exit is still to go.
    private func apply(exit: Exit, at t: Double, to pose: inout AnnotationPose) {
        let eased = easing.apply(t)
        switch exit {
        case .none:
            break
        case .fade:
            pose.opacity *= eased
        case .scale:
            pose.opacity *= eased
            pose.scale *= 0.6 + 0.4 * eased
        case .slideUp:
            pose.opacity *= eased
            pose.offset.dy -= Self.slideDistance * (1 - eased)
        case .slideDown:
            pose.opacity *= eased
            pose.offset.dy += Self.slideDistance * (1 - eased)
        case .slideLeft:
            pose.opacity *= eased
            pose.offset.dx -= Self.slideDistance * (1 - eased)
        case .slideRight:
            pose.opacity *= eased
            pose.offset.dx += Self.slideDistance * (1 - eased)
        }
    }
}

/// An annotation's state at one moment, on top of where it was put.
public struct AnnotationPose: Equatable, Sendable {
    public var opacity: Double = 1
    /// About the annotation's centre.
    public var scale: Double = 1
    /// How far from where it was put. `dx` as a fraction of the frame's width, `dy` of its
    /// height, top-left origin like the rect it moves.
    public var offset: CGVector = .zero

    public init(opacity: Double = 1, scale: Double = 1, offset: CGVector = .zero) {
        self.opacity = opacity
        self.scale = scale
        self.offset = offset
    }
}
