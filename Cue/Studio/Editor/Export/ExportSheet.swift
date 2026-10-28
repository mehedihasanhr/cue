import CoreMedia
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
    /// Whether the sheet opens on the selected stretch — File › Export Selection… —
    /// rather than the whole edit.
    var startsOnSelection = false
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
        .onAppear {
            model.forgetSettledJob()
            // Settings › Export may have changed the choices since this editor opened, and
            // the model read them once, when the window was made. Re-read them while the
            // sheet is only showing options — never over a job it is watching.
            if model.job == nil { model.settings = ExportModel().settings }
            model.scope = startsOnSelection && editor.selectedRange != nil ? .selection : .whole
        }
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
            // Only when there is a stretch to offer. With nothing selected the whole
            // edit is the only thing there is to export, and a picker with one choice
            // is a question nobody asked.
            if let range = editor.selectedRange {
                // Two choices that are one or the other, side by side in one trough: the
                // radio pair it used to be was the only thing in the sheet with a system
                // bezel, and stacked it took two lines to ask a yes-or-no.
                StudioSegmented(selection: $model.scope,
                                items: [ExportScope.whole, .selection]) { scope in
                    switch scope {
                    case .whole: "Whole video"
                    case .selection: "Selection (\(Timecode.short(range.start))–\(Timecode.short(range.end)), \(Timecode.length(range.duration)))"
                    }
                }
                .accessibilityLabel("Export")
            }
            summary
            transparency

            InspectorDisclosure("Settings", isExpanded: $showsSettings) {
                settings.padding(.top, 4)
            }
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
            StudioSegmented(selection: $model.settings.format,
                            items: ExportFormat.allCases) { $0.title }
                .accessibilityLabel("Format")

            Text(model.settings.format.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    settingName("Size").gridColumnAlignment(.trailing)
                    StudioMenuPicker(selection: dimension, sections: [StudioMenuSection(items: dimensionItems)])
                        .accessibilityLabel("Size")
                }
                GridRow {
                    settingName("Frame rate")
                    StudioMenuPicker(selection: $model.settings.frameRate,
                                     options: [15, 24, 30, 60]) { "\($0) fps" }
                        .accessibilityLabel("Frame rate")
                }
                // ProRes has a quality of its own and its codec is its name, so neither
                // question is asked of it.
                if model.settings.format.offersCodecChoice {
                    GridRow {
                        settingName("Quality")
                        StudioSegmented(selection: $model.settings.quality,
                                        items: ExportQuality.allCases) { $0.title }
                            .accessibilityLabel("Quality")
                    }
                    GridRow {
                        settingName("Codec")
                        StudioMenuPicker(selection: $model.settings.codec,
                                         options: ExportCodec.choices(for: model.settings.format)) { $0.title }
                            .accessibilityLabel("Codec")
                    }
                }
                if model.settings.offersTargetSize {
                    GridRow {
                        settingName("Target size")
                        StudioMenuPicker(selection: target, sections: [StudioMenuSection(items: targetItems)])
                            .accessibilityLabel("Target size")
                    }
                }
            }

            sizeNotes

            Group {
                if model.settings.format == .gif {
                    Toggle("Loop forever", isOn: $model.settings.loops)
                } else {
                    Toggle("Include sound", isOn: $model.settings.includesAudio)
                }
            }
            .toggleStyle(.studio)
        }
    }

    /// A setting's name, in the column down the left of the grid.
    private func settingName(_ title: String) -> some View {
        Text(title)
            .font(.system(size: StudioTheme.FontSize.label))
            .foregroundStyle(StudioTheme.Palette.textSecondary)
            .accessibilityHidden(true)
    }

    /// The sizes on offer, by name. Tagged by number with no limit as zero, because the
    /// binding they write through is.
    private var dimensionItems: [StudioMenuItem<Double>] {
        var items = ExportSettings.dimensionChoices.map { StudioMenuItem($0.value ?? 0, title: $0.title) }
        // A preset may ask for a size that is not on the list — the GIF one does — and a
        // picker with no matching choice shows an empty box.
        if !ExportSettings.dimensionChoices.contains(where: { $0.value == model.settings.maximumDimension }),
           let cap = model.settings.maximumDimension {
            items.append(StudioMenuItem(cap, title: "\(Int(cap)) across"))
        }
        return items
    }

    /// The size limits on offer, and a limit remembered from before that is not on the list.
    private var targetItems: [StudioMenuItem<Int>] {
        var items = ExportSettings.targetChoices.map { StudioMenuItem($0.value ?? 0, title: $0.title) }
        if let bytes = model.settings.targetByteCount,
           !ExportSettings.targetChoices.contains(where: { $0.value == bytes }) {
            items.append(StudioMenuItem(bytes, title: ExportEstimate.formatted(bytes)))
        }
        return items
    }

    /// What the file will actually be. Worth saying out loud: "1080p" and "30 fps" are
    /// choices, and their consequence is a number of pixels, a length and a file size
    /// somebody has to send.
    private var summary: some View {
        let estimate = model.estimate(for: editor)
        return HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("\(Int(estimate.size.width)) × \(Int(estimate.size.height)) at \(estimate.frameRate) fps · "
                 + "\(Timecode.length(model.duration(for: editor))) · "
                 + (estimate.isApproximate ? "roughly " : "about ") + estimate.formattedByteCount)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Said whenever the background is see-through, because what happens to it depends
    /// on the format: kept in two of them, black in the rest. Outside the folded settings,
    /// since it is the one thing about this export that could surprise somebody.
    @ViewBuilder
    private var transparency: some View {
        if editor.hasTransparentBackground {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: model.settings.keepsTransparency ? "checkerboard.rectangle" : "exclamationmark.triangle")
                    .foregroundStyle(model.settings.keepsTransparency ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Text(model.settings.keepsTransparency
                     ? "The background is transparent, and this file keeps it that way."
                     : "The background is transparent, but \(model.settings.format.title) has nowhere to keep that: it will be black.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !model.settings.keepsTransparency {
                    SectionButton(title: "Use ProRes 4444") { model.settings.format = .proRes4444 }
                        .help("Export ProRes 4444, which keeps the background see-through")
                }
            }
        }
    }

    /// What Smaller File and a size limit mean for this file, said where they are chosen.
    @ViewBuilder
    private var sizeNotes: some View {
        let settings = model.settings
        if settings.format.offersCodecChoice, settings.quality == .smaller, settings.codec == .automatic {
            Text("Smaller File writes HEVC at a low bitrate: about half the size, and it plays on Apple devices, phones and current browsers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let target = settings.targetByteCount, settings.offersTargetSize {
            let estimate = model.estimate(for: editor)
            if estimate.byteCount > target {
                Label("This is too long to fit in \(ExportEstimate.formatted(target)) and still be watchable: the smallest it can be is about \(estimate.formattedByteCount).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if settings.format == .gif {
                Text("A GIF can only be aimed at a size: it is drawn smaller, then with fewer frames, until it should fit. The file may come out a little either side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var target: Binding<Int> {
        Binding(get: { model.settings.targetByteCount ?? 0 },
                set: { model.settings.targetByteCount = $0 > 0 ? $0 : nil })
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
                // A `ShareLink` still, for the system's own picker, wearing the kit's
                // button: it takes a button style like any other button.
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.studio(.secondary))
                StudioButton("Copy File", systemImage: "doc.on.doc") { job.copyFile() }
                StudioButton("Open", systemImage: "play.rectangle") { job.open() }
            }
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
                    .buttonStyle(.studio(.secondary))
                // Keep Editing is the default, and deliberately: the export is already
                // safe, and the useful thing to do with the next few minutes is work.
                Button("Keep Editing") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.studio(.primary))
            } else if let job = model.job, job.finishedURL != nil {
                Button("Show in Finder") { job.reveal() }
                    .buttonStyle(.studio(.secondary))
                Button("Done") {
                    jobs.dismiss(job)
                    model.forgetSettledJob()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.studio(.primary))
            } else if let job = model.job, case .failed = job.phase {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.studio(.secondary))
                Button("Try Again") {
                    jobs.dismiss(job)
                    model.forgetSettledJob()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.studio(.primary))
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.studio(.secondary))
                Button("Export") { model.begin(from: editor, into: jobs) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.studio(.primary))
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
            .foregroundStyle(isChosen ? StudioTheme.Palette.onAccent : StudioTheme.Palette.textSecondary)
            .background {
                let shape = StudioTheme.squircle(StudioTheme.Radius.tab)
                // The kit's neutrals rather than white at a few per cent, which was a tile
                // on the dark sheet and nothing at all on the light one.
                shape
                    .fill(isChosen ? StudioTheme.Palette.accent
                                   : isHovering ? StudioTheme.Palette.fillHover : StudioTheme.Palette.fill)
                    .overlay { shape.strokeBorder(isChosen ? Color.clear : StudioTheme.Palette.stroke) }
            }
            .contentShape(StudioTheme.squircle(StudioTheme.Radius.tab))
        }
        .buttonStyle(StudioPressStyle())
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hover, value: isHovering)
        .animation(StudioMotion.state, value: isChosen)
        .help(preset.detail)
        .accessibilityLabel("\(preset.title) preset")
        .accessibilityHint(preset.detail)
    }
}
