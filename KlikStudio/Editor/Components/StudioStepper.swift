import SwiftUI
import TimelineKit

/// A value with a step either way: a caption's start, a clip's out-point, a zoom's start.
///
/// Two small squircle buttons around a monospaced readout, so a nudge looks and behaves
/// the same wherever it is. The system stepper is a pair of arrows stacked in a bezel the
/// height of a text line — a fiddly target for the one control people press ten times in
/// a row — and its readout is somebody else's text field.
///
/// The steps are closures rather than arithmetic on a number, because most of what is
/// nudged here is a time, and what one step of a time is — a frame, a tenth — is the
/// caller's business.
struct StudioStepper: View {
    let value: String
    let decrementHelp: String
    let incrementHelp: String
    var decrementSymbol = "chevron.left"
    var incrementSymbol = "chevron.right"
    var canDecrement = true
    var canIncrement = true
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        HStack(spacing: StudioTheme.Spacing.tight) {
            step(decrementSymbol, help: decrementHelp, isEnabled: canDecrement, action: decrement)
            Text(value)
                .font(.system(size: StudioTheme.FontSize.label).monospacedDigit())
                .foregroundStyle(StudioTheme.Palette.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 58)
                .accessibilityHidden(true)
            step(incrementSymbol, help: incrementHelp, isEnabled: canIncrement, action: increment)
        }
    }

    private func step(_ symbol: String, help: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
        }
        // No press-and-hold repeat: every step is its own undo entry, and a held button
        // that queued forty of them would bury everything else on the stack.
        .buttonStyle(StudioButtonStyle(variant: .secondary, size: .small, isIconOnly: true))
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension StudioStepper {
    /// A stepper over a number: the steps and the readout come from the value itself.
    init(value: Binding<Double>,
         in range: ClosedRange<Double>,
         step: Double,
         format: @escaping (Double) -> String,
         decrementHelp: String = "Decrease",
         incrementHelp: String = "Increase") {
        self.init(value: format(value.wrappedValue),
                  decrementHelp: decrementHelp,
                  incrementHelp: incrementHelp,
                  decrementSymbol: "minus",
                  incrementSymbol: "plus",
                  canDecrement: value.wrappedValue > range.lowerBound,
                  canIncrement: value.wrappedValue < range.upperBound,
                  decrement: {
                      value.wrappedValue = SliderMath.nudged(value.wrappedValue, direction: -1, in: range, step: step)
                  },
                  increment: {
                      value.wrappedValue = SliderMath.nudged(value.wrappedValue, direction: 1, in: range, step: step)
                  })
    }
}
