import RenderKit
import SwiftUI

/// Where an export is set up and watched.
///
/// One sheet doing both jobs, rather than a settings dialog that hands off to a progress
/// window: the thing someone wants to know while it runs is what they asked for, and the
/// thing they want when it finishes is where it went.
struct ExportSheet: View {
    let editor: EditorModel
    @Bindable var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch model.phase {
                case .running(let progress): running(progress)
                case .finished(let url): finished(url)
                default: options
                }
            }
            .padding(20)
            Divider()
            buttons.padding(16)
        }
        .frame(width: 420)
        .onDisappear { model.reset() }
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

            summary
        }
    }

    /// What the file will actually be. Worth saying out loud: "1080p" and "30 fps" are
    /// choices, and their consequence is a number of pixels and a length.
    private var summary: some View {
        let size = editor.exportSize(for: model.settings)
        let rate = model.settings.effectiveFrameRate
        return HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("\(Int(size.width)) × \(Int(size.height)) at \(rate) fps · \(Timecode.length(editor.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 2)
    }

    private var dimension: Binding<Double> {
        Binding(get: { model.settings.maximumDimension ?? 0 },
                set: { model.settings.maximumDimension = $0 > 0 ? $0 : nil })
    }

    // MARK: - While it runs

    private func running(_ progress: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
        }
    }

    private static let remaining: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .short
        return formatter
    }()

    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Exported", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(url.lastPathComponent).font(.callout)
            Text(url.deletingLastPathComponent().path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            switch model.phase {
            case .running:
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .finished:
                Button("Show in Finder") { model.reveal() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { model.begin(from: editor) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
