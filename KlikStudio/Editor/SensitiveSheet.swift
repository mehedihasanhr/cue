import CoreMedia
import SwiftUI
import TimelineKit

/// Sensitive text found in the recording, offered for hiding one line at a time.
///
/// A list rather than masks added on the spot, for the reason `PacingSheet` gives: whether
/// an address on screen is a secret or the point of the video is the author's call, and
/// each line can be jumped to and looked at before it is decided. It looks like that sheet
/// on purpose — the two are the same kind of question.
struct SensitiveSheet: View {
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
        .frame(width: 480)
    }

    private var job: SensitiveScanJob { model.sensitive }
    private var review: SensitiveReview { job.review ?? SensitiveReview() }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hide Sensitive Information").font(.headline)
                Text("Email addresses, phone and card numbers, keys and passwords on screen")
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
        case .scanning:
            VStack(spacing: 10) {
                ProgressView(value: job.progress)
                    .frame(width: 260)
                Text("Reading the text on screen… \(Int((job.progress * 100).rounded()))%")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .padding(20)
        case .ready where review.items.isEmpty:
            VStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 22)).foregroundStyle(.secondary)
                Text("Nothing sensitive was found.")
                    .font(.callout)
                Text("No email addresses, phone or card numbers, keys, IP addresses or passwords were read on screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                notShownNote
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                options.padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(review.items) { item in
                            row(item)
                        }
                        notShownNote.padding(.top, 6)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// Found in the recording, but nowhere in the edit — said, so a scan that finds fewer
    /// things than somebody remembers typing explains itself.
    @ViewBuilder
    private var notShownNote: some View {
        if review.notShown > 0 {
            Text(review.notShown == 1
                 ? "1 more is in footage cut from the edit, or outside the crop."
                 : "\(review.notShown) more are in footage cut from the edit, or outside the crop.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var options: some View {
        HStack(spacing: 18) {
            Picker("Mask", selection: Binding(get: { review.style },
                                              set: { job.review?.style = $0 })) {
                ForEach(SensitiveReview.styles, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker("Padding", selection: Binding(get: { review.padding },
                                                 set: { job.review?.padding = $0 })) {
                ForEach(SensitiveReview.Padding.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
        }
    }

    private func row(_ item: SensitiveReview.Item) -> some View {
        let chosen = Binding(get: { item.isChosen },
                             set: { value in
                                 guard let index = job.review?.items.firstIndex(where: { $0.id == item.id }) else { return }
                                 job.review?.items[index].isChosen = value
                             })
        let kind = item.finding.kind
        return HStack(spacing: 10) {
            Toggle(isOn: chosen) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Hide \(kind.title.lowercased()) at \(PacingSheet.time(item.firstSeen.seconds))")
            Image(systemName: kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(SensitiveText.obscured(item.finding.text, kind: kind))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(item))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(PacingSheet.time(item.range.start.seconds)) – \(PacingSheet.time(item.range.end.seconds))")
                .font(.caption).monospacedDigit()
                .foregroundStyle(item.isChosen ? .primary : .secondary)
            Button {
                model.scrub(to: item.firstSeen)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .help("Go to where this is on screen")
            .accessibilityLabel("Go to \(PacingSheet.time(item.firstSeen.seconds))")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.04)))
        .opacity(item.isChosen ? 1 : 0.7)
    }

    private func detail(_ item: SensitiveReview.Item) -> String {
        var parts = [item.finding.kind.title]
        if item.finding.moves { parts.append("moves") }
        if item.isHidden { parts.append("already hidden") }
        return parts.joined(separator: " · ")
    }

    private var hideTitle: String {
        switch review.chosenCount {
        case 0: "Hide Items"
        case 1: "Hide 1 Item"
        case let count: "Hide \(count) Items"
        }
    }

    private var buttons: some View {
        HStack {
            if review.state == .ready, !review.items.isEmpty {
                Text(review.chosenCount == 0 ? "Nothing chosen" : "\(review.chosenCount) of \(review.items.count) chosen")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Cancel", role: .cancel) { model.cancelSensitiveScan() }
                .keyboardShortcut(.cancelAction)
            Button(hideTitle) {
                model.hideSensitiveInformation()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(review.state != .ready || review.chosenCount == 0)
        }
    }
}

extension SensitiveKind {
    /// The glyph beside a line in the review sheet.
    var symbol: String {
        switch self {
        case .email: "envelope"
        case .phone: "phone"
        case .card: "creditcard"
        case .account: "building.columns"
        case .secret: "key"
        case .ipAddress: "network"
        case .password: "lock"
        }
    }
}
