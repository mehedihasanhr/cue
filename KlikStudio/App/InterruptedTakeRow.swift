import AppKit
import RecordKit
import SwiftUI

/// A take that never finished, in Recordings.
///
/// Says so, offers to recover it, shows how far recovery has got, and — if it cannot be
/// recovered — says why in one sentence and offers the Finder, where the files still are.
/// Once recovered it is an ordinary recording and the list shows it as one.
struct InterruptedTakeRow: View {
    let take: InterruptedTake
    private var center: TakeRecoveryCenter { .shared }

    var body: some View {
        // Stopped before its first second: said straight away rather than after a press
        // of Recover that could only say the same.
        let status = center.status(of: take.url) ?? (take.hasFootage ? nil : .nothingToRecover)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 58, height: 36)
                .overlay {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(take.name).font(.callout.weight(.medium)).lineLimit(1)
                detail(status)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            action(status)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contextMenu {
            Button("Show in Finder") { reveal() }
        }
    }

    @ViewBuilder
    private func detail(_ status: TakeRecoveryCenter.Status?) -> some View {
        switch status {
        case nil:
            HStack(spacing: 0) {
                Text("Interrupted").foregroundStyle(.orange)
                Text(facts).foregroundStyle(.secondary)
            }
        case .recovering:
            Text("Recovering\u{2026}").foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).foregroundStyle(.secondary)
        case .nothingToRecover:
            Text("Nothing was recorded before it stopped.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func action(_ status: TakeRecoveryCenter.Status?) -> some View {
        switch status {
        case nil:
            Button("Recover") { center.recover(take.url) }
                .studioButton()
                .help("Make what was recorded into a normal recording")
        case .recovering(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(width: 90)
                .accessibilityLabel("Recovering")
        case .failed, .nothingToRecover:
            Button("Show in Finder") { reveal() }
                .studioButton()
        }
    }

    /// " · 24 Sep 2026 at 11.06 · 82.1 MB", after the word that matters.
    private var facts: String {
        let parts = [take.startedAt == .distantPast ? "" : take.startedAt.formatted(date: .abbreviated, time: .shortened),
                     LibraryCatalog.size(take.byteCount)]
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "" : " \u{00B7} " + parts.joined(separator: " \u{00B7} ")
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([take.url])
    }
}
