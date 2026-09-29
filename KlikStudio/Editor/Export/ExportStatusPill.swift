import RenderKit
import SwiftUI

/// What the editor's title bar says about an export that is still going.
///
/// The reason it exists: an export used to happen inside a modal sheet, so the answer to
/// "what can I do while this runs" was nothing, and the answer to "where has it got to"
/// was "reopen the sheet". A running export belongs in the chrome — visible from anywhere
/// in the window, out of the way of the work, and carrying the two things worth doing
/// about it: stop it, or do something with the file it just produced.
///
/// Nothing when nothing is happening. A toolbar that permanently reserves room for a state
/// the app is almost never in is a toolbar that has been designed for the wrong minute.
struct ExportStatusPill: View {
    let jobs: ExportJobs

    /// The one worth showing: whatever is running, or else the most recent thing to have
    /// happened. Cancelled jobs are removed rather than reported — the person who
    /// cancelled it knows.
    private var job: ExportJob? {
        jobs.running ?? jobs.recent.first { $0.phase != .cancelled }
    }

    var body: some View {
        if let job {
            Menu {
                menu(for: job)
            } label: {
                label(for: job)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help(for: job))
            .transition(.opacity)
            .animation(StudioMotion.state, value: job.phase)
        }
    }

    // MARK: - The pill

    @ViewBuilder
    private func label(for job: ExportJob) -> some View {
        HStack(spacing: 6) {
            switch job.phase {
            case .queued:
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                Text("Queued").font(.system(size: 11, weight: .medium))
            case .running(let progress):
                // A ring rather than a bar: it is the shape that reads as "still going" at
                // 14 points, and the number beside it is the one anybody actually wants.
                ProgressRing(fraction: progress.fraction)
                    .frame(width: 13, height: 13)
                Text("\(Int(progress.fraction * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Exported").font(.system(size: 11, weight: .medium))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Export failed").font(.system(size: 11, weight: .medium))
            case .cancelled:
                EmptyView()
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.07))
        }
    }

    @ViewBuilder
    private func menu(for job: ExportJob) -> some View {
        if let url = job.finishedURL {
            Text(job.fileName)
            Button("Show in Finder") { job.reveal() }
            Button("Open") { job.open() }
            Button("Copy File") { job.copyFile() }
            // The system sheet and nothing else: Klik Studio sends this file nowhere the
            // user has not chosen to send it.
            ShareLink(item: url) { Text("Share…") }
            Divider()
            Button("Dismiss") { jobs.dismiss(job) }
        } else if case .failed(let message) = job.phase {
            Text(message)
            Divider()
            Button("Dismiss") { jobs.dismiss(job) }
        } else {
            Text(job.fileName)
            Button("Cancel Export") { jobs.dismiss(job) }
        }
    }

    private func help(for job: ExportJob) -> String {
        switch job.phase {
        case .queued: "\(job.fileName) is waiting its turn"
        case .running(let progress):
            progress.remaining.map { "\(job.fileName) — about \(Int($0.rounded())) seconds left" }
                ?? "Exporting \(job.fileName)"
        case .finished: "\(job.fileName) is ready"
        case .failed: "That export didn't finish"
        case .cancelled: ""
        }
    }
}

/// A circle that fills clockwise. Drawn rather than a `ProgressView`, which at this size
/// is either a bar that does not fit or a spinner that says nothing about how far along it
/// has got.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(StudioPalette.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(StudioMotion.state, value: fraction)
    }
}
