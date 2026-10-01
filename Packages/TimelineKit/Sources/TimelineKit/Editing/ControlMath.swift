import Foundation

/// The arithmetic behind the editor's hand-drawn controls, kept out of the views.
///
/// The studio draws its own sliders, range sliders and segmented rows rather than using
/// the system's, which means it also owns the sums the system used to do for it: where a
/// pointer puts a value, what one arrow press is worth, where a step lands at the end of a
/// range that it does not divide. Those are exactly the places a hand-built control goes
/// subtly wrong — a knob that jumps half its own width when grabbed, a stepped slider that
/// can never reach its maximum — and a view is the worst place to find that out. Here they
/// are plain functions with tests.

/// One value along one track.
public enum SliderMath {
    /// How far along the range `value` is, from 0 to 1. A range with no width — a slider
    /// whose minimum and maximum have met — reads as the start rather than as a division
    /// by zero.
    public static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    /// `value` held to the range, and to the step grid when there is one.
    ///
    /// The grid starts at the lower bound, not at zero: a slider from 1 to 10 in steps of
    /// 2 lands on 1, 3, 5. The upper bound is always reachable even when the step does not
    /// divide the span — a slider that stops one step short of its own maximum is the bug
    /// people notice first.
    public static func snapped(_ value: Double,
                               in range: ClosedRange<Double>,
                               step: Double?) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let held = min(range.upperBound, max(range.lowerBound, value))
        guard let step, step > 0 else { return held }
        if held == range.upperBound { return held }
        let steps = ((held - range.lowerBound) / step).rounded()
        return min(range.upperBound, range.lowerBound + steps * step)
    }

    /// The value at a fraction of the way along.
    public static func value(atFraction fraction: Double,
                             in range: ClosedRange<Double>,
                             step: Double?) -> Double {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let span = range.upperBound - range.lowerBound
        return snapped(range.lowerBound + clamped * span, in: range, step: step)
    }

    /// Where a pointer at `x` puts the knob, as a fraction of the track.
    ///
    /// Measured to the knob's *centre*: the knob travels the track less its own width, so
    /// a pointer resting on the middle of the knob leaves the value where it is rather
    /// than nudging it by half a knob.
    public static func fraction(atPointer x: Double, trackLength: Double, knob: Double) -> Double {
        let travel = trackLength - knob
        guard travel > 0, x.isFinite else { return 0 }
        return min(1, max(0, (x - knob / 2) / travel))
    }

    /// How far the knob's leading edge sits from the track's, for a fraction.
    public static func knobOffset(fraction: Double, trackLength: Double, knob: Double) -> Double {
        max(0, trackLength - knob) * min(1, max(0, fraction))
    }

    /// What one press of an arrow key is worth.
    ///
    /// A step when the slider has one, otherwise a hundredth of the range — fine enough to
    /// set a value exactly. The large increment (Shift, or VoiceOver's swipe) is a tenth,
    /// rounded up to a whole number of steps so it still lands on the grid.
    public static func increment(in range: ClosedRange<Double>, step: Double?, large: Bool) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        if let step, step > 0 {
            guard large else { return step }
            return max(step, ((span / 10) / step).rounded(.up) * step)
        }
        return large ? span / 10 : span / 100
    }

    /// `value` moved by one increment, up (`direction` > 0) or down.
    public static func nudged(_ value: Double,
                              direction: Int,
                              in range: ClosedRange<Double>,
                              step: Double?,
                              large: Bool = false) -> Double {
        let delta = increment(in: range, step: step, large: large) * Double(direction.signum())
        return snapped(value + delta, in: range, step: step)
    }
}

/// Two values along one track: a lower and an upper bound.
public enum RangeSliderMath {
    public enum Thumb: Equatable, Sendable {
        case lower, upper
    }

    /// Which thumb a press at `value` takes hold of: the nearer one, and — when the two
    /// sit on top of each other — the one on the side the press came from, so a range
    /// squeezed to nothing can still be opened in either direction.
    public static func nearestThumb(to value: Double, lower: Double, upper: Double) -> Thumb {
        if value <= lower { return .lower }
        if value >= upper { return .upper }
        return abs(value - lower) <= abs(upper - value) ? .lower : .upper
    }

    /// The pair after one thumb is moved to `value`.
    ///
    /// A thumb stops at the other one (less `minimumSpan`) rather than pushing it or
    /// swapping places with it: a bound that changes which end it is mid-drag is a bound
    /// you have lost hold of.
    public static func moving(_ thumb: Thumb,
                              to value: Double,
                              lower: Double,
                              upper: Double,
                              in range: ClosedRange<Double>,
                              minimumSpan: Double = 0,
                              step: Double? = nil) -> (lower: Double, upper: Double) {
        let span = range.upperBound - range.lowerBound
        let gap = max(0, min(minimumSpan, span))
        let target = SliderMath.snapped(value, in: range, step: step)
        switch thumb {
        case .lower:
            let moved = max(range.lowerBound, min(target, upper - gap))
            return (moved, upper)
        case .upper:
            let moved = min(range.upperBound, max(target, lower + gap))
            return (lower, moved)
        }
    }
}

/// How a row of equal-width segments breaks onto lines.
public enum SegmentGrid {
    /// How many segments go on each line, given the widest title's segment.
    ///
    /// One line is tried first, then two, then three: the first that fits every segment
    /// at the width of the widest is the one used. Segments never shrink their titles to
    /// fit — a row where "Color" is set larger than "Motion" beside it reads as broken —
    /// so when nothing fits, it is one to a line.
    public static func perRow(count: Int, widest: Double, available: Double, spacing: Double) -> Int {
        guard count > 1, available.isFinite else { return max(1, count) }
        for rows in 1...count {
            let perRow = Int((Double(count) / Double(rows)).rounded(.up))
            let needed = Double(perRow) * widest + Double(perRow - 1) * spacing
            // Half a point of slack: layout widths arrive as fractions, and a row that
            // misses by a rounding error should not fall onto two lines.
            if needed <= available + 0.5 { return perRow }
        }
        return 1
    }
}

/// A colour written as hex, the way people copy one out of a design file.
public enum HexColor {
    /// Red, green, blue and alpha, each from 0 to 1.
    public struct RGBA: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// Reads `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`, with or without the hash and with
    /// any surrounding space. Anything else is nil rather than a guess: a field that turns
    /// a typo into some colour is worse than one that leaves the colour alone.
    public static func parse(_ text: String) -> RGBA? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count <= 4 {
            digits = String(digits.flatMap { [$0, $0] })
        }
        guard let packed = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let channel = { (shift: UInt64) in Double((packed >> shift) & 0xFF) / 255 }
        if hasAlpha {
            return RGBA(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
        }
        return RGBA(red: channel(16), green: channel(8), blue: channel(0))
    }

    /// `#RRGGBB`, upper case, with the alpha appended only when asked for and not opaque.
    public static func format(_ colour: RGBA, includeAlpha: Bool = false) -> String {
        func byte(_ value: Double) -> String {
            let clamped = Int((min(1, max(0, value.isFinite ? value : 0)) * 255).rounded())
            let hex = String(clamped, radix: 16, uppercase: true)
            return hex.count == 1 ? "0" + hex : hex
        }
        var text = "#" + byte(colour.red) + byte(colour.green) + byte(colour.blue)
        if includeAlpha, colour.alpha < 1 { text += byte(colour.alpha) }
        return text
    }
}
