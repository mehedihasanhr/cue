import AppKit
import SwiftUI
import TimelineKit

/// A slider with two knobs: a lower and an upper bound on one track.
///
/// For any setting that is a span rather than a point — a range of zoom, a band of
/// loudness. It is the single slider's look and manners with a second knob: the accent runs
/// between the two, a press takes the nearer knob (and, when the two sit on top of each
/// other, the one on the side you pressed from, so a range squeezed shut can still be
/// opened either way), and a knob stops at the other rather than pushing it or swapping
/// places with it. The rules are `RangeSliderMath`, in TimelineKit.
///
/// `onEditingChanged` brackets a drag exactly as `StudioSlider`'s does, so a drag of
/// either knob is one undo entry. From the keyboard, Tab reaches each knob in turn and
/// the arrows step it.
struct StudioRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let range: ClosedRange<Double>
    var step: Double?
    /// The least the two bounds may be apart.
    var minimumSpan: Double
    var size: StudioTheme.ControlSize
    var valueText: ((Double) -> String)?
    var onEditingChanged: (Bool) -> Void

    init(lower: Binding<Double>,
         upper: Binding<Double>,
         in range: ClosedRange<Double>,
         step: Double? = nil,
         minimumSpan: Double = 0,
         size: StudioTheme.ControlSize = .regular,
         valueText: ((Double) -> String)? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _lower = lower
        _upper = upper
        self.range = range
        self.step = step
        self.minimumSpan = minimumSpan
        self.size = size
        self.valueText = valueText
        self.onEditingChanged = onEditingChanged
    }

    private typealias Thumb = RangeSliderMath.Thumb

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Thumb?
    @State private var dragging: (thumb: Thumb, grab: CGFloat)?
    @State private var isHovering = false
    @State private var bracket = EditingBracket()

    private var metrics: SliderMetrics { SliderMetrics(size) }

    var body: some View {
        bracket.report = onEditingChanged

        return GeometryReader { proxy in
            let width = proxy.size.width
            let lowX = offset(for: lower, width: width)
            let highX = offset(for: upper, width: width)

            ZStack(alignment: .leading) {
                SliderTrack(metrics: metrics,
                            fillFrom: lowX + metrics.knob / 2,
                            fillTo: highX + metrics.knob / 2,
                            isLit: isHovering || dragging != nil)
                knob(.lower, at: lowX)
                knob(.upper, at: highX)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width, lowX: lowX, highX: highX))
        }
        .frame(height: metrics.height)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 && isEnabled }
        .onDisappear { bracket.close() }
        .animation(StudioMotion.hover, value: isHovering)
        .animation(StudioMotion.selection, value: dragging?.thumb)
        .accessibilityElement(children: .contain)
    }

    private func knob(_ thumb: Thumb, at x: CGFloat) -> some View {
        SliderKnob(metrics: metrics,
                   isDragging: dragging?.thumb == thumb,
                   isFocused: focused == thumb)
            .offset(x: x)
            .focusable(isEnabled, interactions: .activate)
            .focused($focused, equals: thumb)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let direction = press.key == .leftArrow || press.key == .downArrow ? -1 : 1
                nudge(thumb, direction, large: press.modifiers.contains(.shift))
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(thumb == .lower ? "Lower bound" : "Upper bound")
            .accessibilityValue(Text(text(for: thumb == .lower ? lower : upper)))
            .accessibilityAdjustableAction { direction in
                nudge(thumb, direction == .increment ? 1 : -1, large: true)
            }
    }

    // MARK: - Pointer

    private func dragGesture(width: CGFloat, lowX: CGFloat, highX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }
                if dragging == nil {
                    let at = value(atPointer: gesture.startLocation.x, width: width)
                    let thumb = RangeSliderMath.nearestThumb(to: at, lower: lower, upper: upper)
                    let centre = (thumb == .lower ? lowX : highX) + metrics.knob / 2
                    let onKnob = abs(gesture.startLocation.x - centre) <= metrics.knob / 2 + 3
                    dragging = (thumb, onKnob ? gesture.startLocation.x - centre : 0)
                    bracket.open()
                }
                guard let dragging else { return }
                move(dragging.thumb, to: value(atPointer: gesture.location.x - dragging.grab, width: width))
            }
            .onEnded { gesture in
                if let dragging {
                    move(dragging.thumb, to: value(atPointer: gesture.location.x - dragging.grab, width: width))
                    bracket.close()
                }
                dragging = nil
            }
    }

    // MARK: - Arithmetic

    private func offset(for value: Double, width: CGFloat) -> CGFloat {
        SliderMath.knobOffset(fraction: SliderMath.fraction(of: value, in: range),
                              trackLength: width, knob: metrics.knob)
    }

    private func value(atPointer x: CGFloat, width: CGFloat) -> Double {
        let at = SliderMath.fraction(atPointer: x, trackLength: width, knob: metrics.knob)
        return SliderMath.value(atFraction: at, in: range, step: nil)
    }

    private func nudge(_ thumb: Thumb, _ direction: Int, large: Bool) {
        guard isEnabled else { return }
        bracket.touch()
        let current = thumb == .lower ? lower : upper
        let delta = SliderMath.increment(in: range, step: step, large: large) * Double(direction)
        move(thumb, to: current + delta)
    }

    private func move(_ thumb: Thumb, to value: Double) {
        let moved = RangeSliderMath.moving(thumb, to: value, lower: lower, upper: upper,
                                           in: range, minimumSpan: minimumSpan, step: step)
        if moved.lower != lower { lower = moved.lower }
        if moved.upper != upper { upper = moved.upper }
    }

    private func text(for value: Double) -> String {
        valueText?(value) ?? "\(Int((SliderMath.fraction(of: value, in: range) * 100).rounded())) percent"
    }
}
