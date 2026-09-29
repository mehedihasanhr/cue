import SwiftUI

/// The editor's own slider.
///
/// The system's is built for a settings window: a tall bar and a large knob, sized so it
/// can be found on a page full of text. This panel is nine of them in a column, so the
/// track is a three-point trough rather than a bar, the part you have set is the app's
/// blue — the same blue that marks the chosen tab, because a slider's fill is the same
/// statement — and the knob is the only thing with any weight, because the knob is the
/// part you aim at.
///
/// It also says what it is set to, but only while you are touching it: the number lives
/// in a slot that is always there and only inked on hover or during a drag, so reading a
/// value costs nothing and a column at rest is still just names and lines.
struct StudioSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Told at the start and end of a drag, which is how one drag becomes one undo.
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(value: Binding<Double>,
         in range: ClosedRange<Double>,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.onEditingChanged = onEditingChanged
    }

    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    @State private var isHovering = false

    private static let track: CGFloat = 3
    private static let knob: CGFloat = 12

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(0, width - Self.knob)
            let knobX = travel * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: Self.track)

                Capsule()
                    .fill(isEnabled
                          ? AnyShapeStyle(Color.accentColor.opacity(isHovering || isDragging ? 1 : 0.85))
                          : AnyShapeStyle(Color.primary.opacity(0.2)))
                    .frame(width: knobX + Self.knob / 2, height: Self.track)

                Circle()
                    .fill(.white)
                    .overlay { Circle().strokeBorder(.black.opacity(0.12)) }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: Self.knob, height: Self.knob)
                    .scaleEffect(isDragging ? 1.18 : 1)
                    .offset(x: knobX)
                    .opacity(isEnabled ? 1 : 0.45)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        set(from: drag.location.x, travel: travel)
                    }
                    .onEnded { drag in
                        set(from: drag.location.x, travel: travel)
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        // Tall enough to hit, whatever the 4-point track suggests — and no taller,
        // because the slack sits under the last track in a section and reads as padding
        // that is not there.
        .frame(height: 16)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.state, value: isHovering)
        .animation(StudioMotion.selection, value: isDragging)
        .accessibilityElement()
        .accessibilityValue(Text(percentText))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    /// Where the knob's *centre* is, not where the pointer is: aiming at the middle of
    /// the knob and having the value jump by half a knob width is the thing that makes a
    /// hand-built slider feel wrong.
    private func set(from x: CGFloat, travel: CGFloat) {
        guard travel > 0 else { return }
        let position = min(1, max(0, (x - Self.knob / 2) / travel))
        value = range.lowerBound + position * (range.upperBound - range.lowerBound)
    }

    private var percentText: String { "\(Int((fraction * 100).rounded()))%" }
}
