import AddOnKit
import AppKit
import RecordKit
import SwiftUI

/// The library: what has been recorded, and a way back to the bar.
///
/// The recorder itself is the floating bar, so this window has one job — find a take and
/// open it. It is also where the permission problem is explained, because that is the one
/// message too long to put on a bar.
struct LibraryWindow: View {
    @Environment(StudioService.self) private var studio
    @Environment(StudioSettings.self) private var settings
    let model: RecorderModel?

    var body: some View {
        VStack(spacing: 0) {
            if model?.permissionDenied == true, let model {
                PermissionBanner(model: model)
            }

            if let model, !model.recents.isEmpty {
                list(model)
            } else {
                empty
            }

            footer
        }
        .frame(minWidth: 440, minHeight: 420)
        .background(.background)
        .navigationTitle("Recordings")
        .task {
            await model?.refreshSources()
            model?.refreshRecents(limit: 50)
        }
        .onChange(of: studio.session.state) { _, state in
            if case .finished = state { model?.refreshRecents(limit: 50) }
        }
    }

    /// One scrolling list, and only one: the overlapping mess this window used to be came
    /// from stacking fixed-height lists inside a scroll view, where anything taller than
    /// its frame simply drew over its neighbours.
    private func list(_ model: RecorderModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.recents) { recording in
                    RecordingRow(recording: recording) {
                        StudioAppDelegate.openEditor(recording.url)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .studioScrollEdges()
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No recordings yet").font(.title3.weight(.medium))
            Text("Press Record on the bar. What you record lands here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(settings.library.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Show in Finder") { NSWorkspace.shared.open(settings.library) }
                .studioButton()
            Button("Recorder Bar") { StudioAppDelegate.showBar() }
                .studioButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One take.
private struct RecordingRow: View {
    let recording: RecorderModel.Recording
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 58, height: 36)
                    .overlay { Image(systemName: "film").font(.callout).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(recording.recorded.formatted(date: .abbreviated, time: .shortened)) · \(RecorderModel.length(recording.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
        }
    }
}

/// The one message too long for the bar.
private struct PermissionBanner: View {
    let model: RecorderModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Klik Studio can't see the screen yet").font(.callout.weight(.semibold))
                Text("Turn it on in Privacy & Security, then reopen Klik Studio — macOS applies the change on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { model.openScreenRecordingSettings() }
                .studioButton()
        }
        .padding(14)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
