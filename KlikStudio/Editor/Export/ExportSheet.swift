import RenderKit
import SwiftUI

/// Where an export is set up and watched.
///
/// One sheet doing both jobs, rather than a settings dialog that hands off to a progress
/// window: the thing someone wants to know while it runs is what they asked for, and the
/// thing they want when it finishes is where it went.
///
/// What the sheet no longer does is *hold* the export. The work belongs to `ExportJobs`,
/// so closing this — or the window behind it — leaves the file being written. The button
/// that says so is Keep Editing, and it is the default while one runs.
struct ExportSheet: View {
    let editor: EditorModel
    @Bindable var model: ExportModel
    let jobs: ExportJobs
    @Environment(\.dismiss) private var dismiss

    /// The settings are folded away once there are presets to choose from: the whole point
    /// of a preset is that most exports need none of this.
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                // A cancelled job puts the sheet back where it started, because that is
                // what cancelling meant: not this file, and now what?
                if let job = model.job, job.phase != .cancelled {
                    status(job)
                } else {
                    options
                }
            }
            .padding(20)
            Divider()
            buttons.padding(16)
        }
        .frame(width: 440)
        .onAppear { model.forgetSettledJob() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Export").font(.headline)
                Text(editor.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Setting it up

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            presets
            summary

            DisclosureGroup("Settings", isExpanded: $showsSettings) {
                settings.padding(.top, 12)
            }
            .font(.callout)
        }
    }

    /// Four errands, as four things to press.
    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(ExportPreset.allCases) { preset in
                    PresetTile(preset: preset,
                               isChosen: model.preset == preset) { model.apply(preset) }
                }
            }
            // The chosen preset's own sentence, or an admission that the settings below
            // are now somebody's own. Either way the space is always occupied, so opening
            // the settings does not make the sheet jump.
            Text(model.preset?.detail ?? "Your own settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 16, alignment: .top)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $model.settings.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.settings.format.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Size").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: dimension) {
                        ForEach(ExportSettings.dimensionChoices, id: \.title) { choice in
                            Text(choice.title).tag(choice.value ?? 0)
                        }
                        // A preset may ask for a size that is not on the list — the GIF one
                        // does — and a picker with no matching tag shows an empty box.
                        if !ExportSettings.dimensionChoices.contains(where: { $0.value == model.settings.maximumDimension }),
                           let cap = model.settings.maximumDimension {
                            Text("\(Int(cap)) across").tag(cap)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Frame rate").foregroundStyle(.secondary)
                    Picker("", selection: $model.settings.frameRate) {
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                }
                if model.settings.format != .gif {
                    GridRow {
                        Text("Quality").foregroundStyle(.secondary)
                        Picker("", selection: $model.settings.quality) {
                            ForEach(ExportQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Codec").foregroundStyle(.secondary)
                        Picker("", selection: $model.settings.codec) {
                            ForEach(ExportCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
            }

            if model.settings.format == .gif {
                Toggle("Loop forever", isOn: $model.settings.loops)
            } else {
                Toggle("Include sound", isOn: $model.settings.includesAudio)
            }
        }
    }

    /// What the file will actually be. Worth saying out loud: "1080p" and "30 fps" are
    /// choices, and their consequence is a number of pixels, a length and a file size
    /// somebody has to send.
    private var summary: some View {
        let estimate = model.estimate(for: editor)
        return HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("\(Int(estimate.size.width)) × \(Int(estimate.size.height)) at \(estimate.frameRate) fps · "
                 + "\(Timecode.length(editor.duration)) · "
                 + (estimate.isApproximate ? "roughly " : "about ") + estimate.formattedByteCount)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var dimension: Binding<Double> {
        Binding(get: { model.settings.maximumDimension ?? 0 },
                set: { model.settings.maximumDimension = $0 > 0 ? $0 : nil })
    }

    // MARK: - While it runs

    @ViewBuilder
    private func status(_ job: ExportJob) -> some View {
        if case .finished(let url) = job.phase {
            finished(job, url: url)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                progressBody(job)
                Text(job.fileName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func progressBody(_ job: ExportJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch job.phase {
            case .running(let progress):
                ProgressView(value: progress.fraction)
                HStack {
                    Text(progress.totalFrames > 0
                         ? "Frame \(progress.framesWritten) of \(progress.totalFrames)"
                         : "Getting ready…")
                    Spacer()
                    if let remaining = progress.remaining {
                        Text("about \(Self.remaining.string(from: remaining) ?? "") left")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .queued:
                ProgressView(value: 0)
                Text("Waiting for the export in front of it…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .cancelled:
                Label("Export cancelled. Nothing was written.", systemImage: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .finished:
                EmptyView()
            }
        }
    }

    private static let remaining: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .short
        return formatter
    }()

    // MARK: - Afterwards

    private func finished(_ job: ExportJob, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exported", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.callout)
                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let size = Self.sizeOnDisk(of: url) {
                    Text(size).font(.caption).foregroundStyle(.tertiary)
                }
            }
            // The three things anybody does next, side by side rather than buried in the
            // Finder. Share is the system sheet and nothing else: no account, no upload,
            // nothing that sends this file anywhere the user did not send it.
            HStack(spacing: 8) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    job.copyFile()
                } label: {
                    Label("Copy File", systemImage: "doc.on.doc")
                }
                Button {
                    job.open()
                } label: {
                    Label("Open", systemImage: "play.rectangle")
                }
            }
            .controlSize(.regular)
        }
    }

    /// What actually landed, which is the only honest answer to "how big is it".
    private static func sizeOnDisk(of url: URL) -> String? {
        guard let bytes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))[.size] as? Int else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            if let job = model.job, !job.phase.isSettled {
                // Dismissed rather than only cancelled: a job nobody is waiting for should
                // not sit in the app's list as a row that says it stopped.
                Button("Cancel Export") { jobs.dismiss(job) }
                // Keep Editing is the default, and deliberately: the export is already
                // safe, and the useful thing to do with the next few minutes is work.
                Button("Keep Editing") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if let job = model.job, job.finishedURL != nil {
                Button("Show in Finder") { job.reveal() }
                Button("Done") {
                    jobs.dismiss(job)
                    model.forgetSettledJob()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else if let job = model.job, case .failed = job.phase {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    jobs.dismiss(job)
                    model.forgetSettledJob()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { model.begin(from: editor, into: jobs) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// One preset, as a tile: the errand's name over its symbol, filled when it is the one
/// the settings currently are.
private struct PresetTile: View {
    let preset: ExportPreset
    let isChosen: Bool
    let choose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 5) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 16, weight: .medium))
                Text(preset.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isChosen ? AnyShapeStyle(StudioPalette.brand)
                                   : AnyShapeStyle(.white.opacity(isHovering ? 0.10 : 0.05)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.state, value: isChosen)
        .help(preset.detail)
        .accessibilityLabel("\(preset.title) preset")
        .accessibilityHint(preset.detail)
    }
}
