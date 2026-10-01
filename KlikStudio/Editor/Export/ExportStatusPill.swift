import AppKit
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

    @State private var isPresented = false
    /// The pill's own view, for the share picker to open from: the list Share is chosen
    /// in has closed by the time the picker opens.
    @State private var shareAnchor = ShareAnchor()

    /// The one worth showing: whatever is running, or else the most recent thing to have
    /// happened. Cancelled jobs are removed rather than reported — the person who
    /// cancelled it knows.
    private var job: ExportJob? {
        jobs.running ?? jobs.recent.first { $0.phase != .cancelled }
    }

    var body: some View {
        if let job {
            // The kit's list in a popover rather than a system menu: the same rows as
            // every other list in the editor, with the file's name — or what went wrong —
            // as the list's heading rather than a greyed-out item.
            Button { isPresented.toggle() } label: {
                label(for: job)
            }
            .buttonStyle(.studio(.secondary, size: .small))
            .background { ShareAnchorView(anchor: shareAnchor) }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                StudioMenuList(sections: sections(for: job), showsChecks: false)
            }
            .fixedSize()
            .help(help(for: job))
            .accessibilityHint("Shows what can be done with this export")
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
        .foregroundStyle(StudioTheme.Palette.textSecondary)
    }

    private func sections(for job: ExportJob) -> [StudioMenuList.Section] {
        func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> StudioMenuList.Row {
            StudioMenuList.Row(title: title, systemImage: symbol, thumbnail: nil,
                               isChecked: false, isEnabled: true, action: action)
        }
        let dismiss = row("Dismiss", "xmark") { jobs.dismiss(job) }

        if let url = job.finishedURL {
            let anchor = shareAnchor
            return [
                .init(title: job.fileName, rows: [
                    row("Show in Finder", "folder") { job.reveal() },
                    row("Open", "play.rectangle") { job.open() },
                    row("Copy File", "doc.on.doc") { job.copyFile() },
                    // The system's share picker and nothing else: Klik Studio sends this
                    // file nowhere the user has not chosen to send it.
                    row("Share…", "square.and.arrow.up") { anchor.share(url) },
                ]),
                .init(title: nil, rows: [dismiss]),
            ]
        } else if case .failed(let message) = job.phase {
            return [.init(title: message, rows: [dismiss])]
        } else {
            return [.init(title: job.fileName, rows: [
                row("Cancel Export", "stop.circle") { jobs.dismiss(job) },
            ])]
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
                .stroke(StudioTheme.Palette.track, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(StudioTheme.Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(StudioMotion.state, value: fraction)
    }
}

/// Where the share picker opens from: the pill, which is still on screen once the list
/// Share was chosen in has closed.
///
/// The system menu this replaced held a `ShareLink`, which finds its own anchor. A row in
/// the kit's list is a plain action, so the picker is opened by hand against the pill.
@MainActor
private final class ShareAnchor {
    weak var view: NSView?
    /// Held until the next share: nothing else keeps the picker while its menu is up.
    private var picker: NSSharingServicePicker?

    func share(_ url: URL) {
        // On the next turn of the run loop, once the popover has gone: a picker opened
        // while the popover is still closing can go with it.
        Task { @MainActor in
            guard let view, view.window != nil else { return }
            let picker = NSSharingServicePicker(items: [url])
            self.picker = picker
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

/// An empty view behind the pill that hands its `NSView` to the anchor.
private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
