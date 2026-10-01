import CoreMedia
import SwiftUI
import TimelineKit

/// The waiting in a recording, offered for speeding up one stretch at a time.
///
/// A list rather than something applied on the spot: whether a pause is dead air or the
/// moment the viewer reads the screen is the author's call, and each line can be jumped to
/// and looked at before it is decided.
struct PacingSheet: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360, alignment: .top)
            Divider()
            buttons.padding(16)
        }
        .frame(width: 460)
    }

    private var review: PacingReview { model.pacing ?? PacingReview() }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "forward")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Speed Up Waiting").font(.headline)
                Text("Stretches where nothing happens, and typing nobody talks over")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch review.state {
        case .measuring:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Watching the recording for when the screen changes…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .padding(20)
        case .ready where review.items.isEmpty:
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 22)).foregroundStyle(.secondary)
                Text("Nothing here is waiting to be sped up.")
                    .font(.callout)
                Text("The pointer, the keys, the voice or the screen is busy all the way through.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                speeds.padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(review.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var speeds: some View {
        HStack(spacing: 18) {
            speedPicker("Still", value: Binding(get: { review.idleSpeed },
                                               set: { model.pacing?.idleSpeed = $0 }),
                        choices: EditorModel.idleSpeeds)
            speedPicker("Typing", value: Binding(get: { review.typingSpeed },
                                                set: { model.pacing?.typingSpeed = $0 }),
                        choices: EditorModel.typingSpeeds)
            Spacer()
        }
    }

    private func speedPicker(_ title: String, value: Binding<Double>, choices: [Double]) -> some View {
        SheetPicker(title, selection: value, options: choices) { Self.speed($0) }
    }

    private func row(_ item: PacingReview.Item) -> some View {
        let chosen = Binding(get: { item.isChosen },
                             set: { value in
                                 guard let index = model.pacing?.items.firstIndex(where: { $0.id == item.id }) else { return }
                                 model.pacing?.items[index].isChosen = value
                             })
        let speed = review.speed(for: item.reason)
        return HStack(spacing: 10) {
            Toggle(isOn: chosen) { EmptyView() }
                .toggleStyle(StudioCheckboxStyle(showsLabel: false))
                .accessibilityLabel("Speed up \(Self.time(item.range.start.seconds))")
            Image(systemName: item.reason == .idle ? "hourglass" : "keyboard")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Self.time(item.range.start.seconds)) – \(Self.time(item.range.end.seconds))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text(item.reason == .idle ? "Nothing happening" : "Typing")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Self.length(item.range.duration.seconds)) → \(Self.length(item.range.duration.seconds / speed))")
                .font(.caption).monospacedDigit()
                .foregroundStyle(item.isChosen ? .primary : .secondary)
            StudioIconButton(systemImage: "arrow.right.circle",
                             help: "Go to this stretch",
                             accessibilityName: "Go to \(Self.time(item.range.start.seconds))",
                             size: .small) {
                model.scrub(to: item.range.start)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.04)))
        .opacity(item.isChosen ? 1 : 0.7)
    }

    private var buttons: some View {
        HStack {
            if review.state == .ready, !review.items.isEmpty {
                Text(review.chosenCount == 0 ? "Nothing chosen"
                     : "\(review.chosenCount) of \(review.items.count) · saves \(Self.length(review.saving))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Cancel", role: .cancel) { model.cancelPacing() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.studio(.secondary))
            Button("Speed Up") { model.applyPacing() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.studio(.primary))
                .disabled(review.state != .ready || review.chosenCount == 0)
        }
    }

    // MARK: - Words

    static func speed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%.1f×", value)
    }

    static func time(_ seconds: Double) -> String {
        let whole = max(0, seconds)
        return String(format: "%d:%04.1f", Int(whole) / 60, whole.truncatingRemainder(dividingBy: 60))
    }

    static func length(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds)
                     : String(format: "%d:%02d", Int(seconds) / 60, Int(seconds.rounded()) % 60)
    }
}

/// A named pop-up along the top of a review sheet: the speeds here, the mask and its
/// padding in `SensitiveSheet`, the language in `TranslateCaptionsSheet`.
///
/// The name is a `Text` of its own beside the kit's field rather than the picker's built-in
/// label, the way the inspector's rows do it — the system's label comes with a system
/// pop-up attached. A value the list does not offer is added to it rather than shown as a
/// blank, as `InspectorPicker` does.
struct SheetPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String

    init(_ title: String,
         selection: Binding<Value>,
         options: [Value],
         name: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.name = name
    }

    var body: some View {
        let shown = options.contains(selection) ? options : options + [selection]
        HStack(spacing: StudioTheme.Spacing.regular) {
            Text(title)
                .font(.system(size: StudioTheme.FontSize.label))
                .foregroundStyle(StudioTheme.Palette.textSecondary)
                .accessibilityHidden(true)
            StudioMenuPicker(selection: $selection, options: shown, title: name)
                .accessibilityLabel(title)
        }
        .fixedSize()
    }
}
