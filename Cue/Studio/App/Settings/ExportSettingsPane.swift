import AppKit
import RenderKit
import SwiftUI

/// What the export sheet starts with, where the file goes, and what happens once it lands.
///
/// The sheet already remembers what was last exported with. This pane edits those same
/// remembered choices — through an `ExportModel`, so the codec that a format cannot hold
/// is corrected here exactly as it is in the sheet — rather than keeping a second set of
/// "defaults" that the sheet would then have to decide between.
struct ExportSettingsPane: View {
    @Environment(StudioSettings.self) private var settings
    @State private var export = ExportModel()
    @State private var folder = UserDefaults.standard.url(forKey: ExportModel.Key.folder)

    var body: some View {
        @Bindable var app = settings.app
        @Bindable var export = export

        StudioSettingsPane(.export) {
            StudioSettingsGroup("The export sheet starts with") {
                StudioSettingsRow("Preset", subtitle: export.preset?.detail ?? "Your own settings.") {
                    Picker("Preset", selection: preset) {
                        if export.preset == nil { Text("Custom").tag(ExportPreset?.none) }
                        ForEach(ExportPreset.allCases) { Text($0.title).tag(ExportPreset?.some($0)) }
                    }
                    .fixedSize()
                }
                StudioSettingsRow("Format", subtitle: export.settings.format.detail) {
                    Picker("Format", selection: $export.settings.format) {
                        ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                StudioSettingsRow("Size") {
                    Picker("Size", selection: dimension) {
                        ForEach(ExportSettings.dimensionChoices, id: \.title) { choice in
                            Text(choice.title).tag(choice.value ?? 0)
                        }
                        // A preset may ask for a size that is not on the list — the GIF one
                        // does — and a picker with no matching tag shows an empty box.
                        if !ExportSettings.dimensionChoices.contains(where: { $0.value == export.settings.maximumDimension }),
                           let cap = export.settings.maximumDimension {
                            Text("\(Int(cap)) across").tag(cap)
                        }
                    }
                    .fixedSize()
                }
                StudioSettingsRow("Frame rate", subtitle: export.settings.format == .gif ? "A GIF plays at no more than \(ExportSettings.maximumGIFFrameRate) fps." : nil) {
                    Picker("Frame rate", selection: $export.settings.frameRate) {
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                // ProRes has a quality of its own and its codec is its name, so neither
                // question is asked of it — as in the sheet.
                if export.settings.format.offersCodecChoice {
                    StudioSettingsRow("Quality") {
                        Picker("Quality", selection: $export.settings.quality) {
                            ForEach(ExportQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    StudioSettingsRow("Codec") {
                        Picker("Codec", selection: $export.settings.codec) {
                            ForEach(ExportCodec.choices(for: export.settings.format), id: \.self) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                    }
                }
                if export.settings.format == .gif {
                    SettingsToggleRow("Loop forever", isOn: $export.settings.loops)
                } else {
                    SettingsToggleRow("Include sound", isOn: $export.settings.includesAudio)
                }
            }

            StudioSettingsGroup("After exporting") {
                StudioSettingsRow("When an export finishes",
                            subtitle: "The editor's toolbar always says so. An export that lands after its editor has closed is shown in the Finder.",
                            symbol: "checkmark.circle.fill", tint: .green) {
                    Picker("When an export finishes", selection: $app.afterExport) {
                        ForEach(StudioAppPreferences.AfterExport.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                StudioSettingsRow(folder?.lastPathComponent ?? "Save exports to",
                            subtitle: folder?.path(percentEncoded: false) ?? "Where the save panel opens. Not chosen yet — it opens wherever macOS last had it.",
                            symbol: "folder.fill", tint: .orange) {
                    HStack(spacing: 8) {
                        Button("Choose") { chooseFolder() }
                        if let folder {
                            RevealButton(help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    }
                }
                SettingsToggleRow("Follow the last export",
                                  subtitle: app.remembersExportFolder
                                  ? "The save panel opens wherever the last export went."
                                  : "The save panel always opens in the folder above, wherever the last export went.",
                                  isOn: $app.remembersExportFolder)
            }
        }
    }

    /// The preset the choices are, if they are one — and choosing one applies it, as a
    /// tile in the sheet does.
    private var preset: Binding<ExportPreset?> {
        Binding {
            export.preset
        } set: { preset in
            if let preset { export.apply(preset) }
        }
    }

    /// Zero is how "the project's own size" is tagged, as in the sheet.
    private var dimension: Binding<Double> {
        Binding {
            export.settings.maximumDimension ?? 0
        } set: { value in
            export.settings.maximumDimension = value > 0 ? value : nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url, forKey: ExportModel.Key.folder)
        folder = url
    }
}
