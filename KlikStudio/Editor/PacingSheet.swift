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
        Picker(title, selection: value) {
            ForEach(choices, id: \.self) { Text(Self.speed($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
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
                .toggleStyle(.checkbox)
                .labelsHidden()
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
            Button {
                model.scrub(to: item.range.start)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .help("Go to this stretch")
            .accessibilityLabel("Go to \(Self.time(item.range.start.seconds))")
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
            Button("Speed Up") { model.applyPacing() }
                .keyboardShortcut(.defaultAction)
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
