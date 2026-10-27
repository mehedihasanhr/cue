import SwiftUI
import UniformTypeIdentifiers

/// Transform's window, drawn as Droppy's: a light pane of glass 360 pt wide, the files
/// as tiles, the actions as a grid of tiles with the chosen one in blue, its options
/// on a grey card, what the files will weigh, presets, and one wide blue button.
struct TransformView: View {
    static let width: CGFloat = 360

    @Bindable var model: TransformModel
    let run: () -> Void
    let close: () -> Void

    @State private var shown = false
    @State private var naming = false
    @State private var presetName = ""

    private static let tile = CGSize(width: 76, height: 40)
    private static let columns = Array(repeating: GridItem(.fixed(76), spacing: 8, alignment: .top), count: 4)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            // Gaps measured off Droppy's window.
            files.padding(.top, 16)
            actions.padding(.top, 13)
            options.padding(.top, 12)
            if let estimate = model.estimate { estimateRow(estimate).padding(.top, 16).transition(.opacity) }
            presets.padding(.top, 17)
            button.padding(.top, 13)
        }
        .padding(16)
        .frame(width: Self.width)
        .foregroundStyle(TransformPalette.text)
        .background { TransformGlass(shape: shape) }
        .clipShape(shape)
        .scaleEffect(shown ? 1 : 0.94, anchor: .top)
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.settings.action)
        .animation(.easeOut(duration: 0.2), value: model.estimate?.after)
        .onAppear { withAnimation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.72)) { shown = true } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add([url]) }
                }
            }
            return true
        }
        .alert("Save preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") { model.savePreset(named: presetName); presetName = "" }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Keeps \(model.settings.action.title) as it is set now.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            TransformAppIcon()
            VStack(alignment: .leading, spacing: 1) {
                Text("Transform").font(.system(size: 13.5, weight: .semibold))
                Text(model.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(TransformPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TransformPalette.glyph)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(TransformPalette.close))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
    }

    // MARK: - Files

    private var files: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.files, id: \.self) { url in
                    cell(label: "\(url.lastPathComponent)\n\(TransformModel.bytes(TransformEngine.fileSize(url)))") {
                        TransformTile { FileGlyph(url: url) }
                    }
                    .contextMenu { Button("Remove") { model.remove(url) } }
                }
                cell(label: "Add") {
                    Button(action: addFiles) {
                        TransformTile { Image(systemName: "plus").font(.system(size: 16, weight: .regular)) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        NSApp.activate()
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    // MARK: - Actions

    private var actions: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 4) {
            ForEach(TransformModel.Action.allCases, id: \.self) { action in
                let selected = model.settings.action == action
                let available = model.isAvailable(action)
                cell(label: action.title, selected: selected) {
                    Button { model.settings.action = action } label: {
                        TransformTile(selected: selected) {
                            Image(systemName: action.symbol).font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .opacity(available ? 1 : 0.4)
                .disabled(!available)
            }
        }
    }

    /// A tile and its label under it, two lines at most.
    private func cell(label: String, selected: Bool = false, @ViewBuilder tile: () -> some View) -> some View {
        VStack(spacing: 6) {
            tile()
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? TransformPalette.text : TransformPalette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: Self.tile.width + 6, height: 28, alignment: .top)
        }
        .frame(width: Self.tile.width)
    }

    // MARK: - Options

    @ViewBuilder
    private var options: some View {
        VStack(spacing: 0) {
            switch model.settings.action {
            case .compress: compressOptions
            case .convert: convertOptions
            case .resize: resizeOptions
            case .removeBackground: note("Cuts out the subject and saves it as a PNG with a clear background.")
            case .rotate: rotateOptions
            case .removeMetadata: note("Takes out the location, camera and other details, leaving the picture as it is.")
            case .combine: nameRow(placeholder: "Combined")
            case .zip: nameRow(placeholder: model.files.count == 1 ? model.files[0].deletingPathExtension().lastPathComponent : "Archive")
            case .rename: renameOptions
            }
            row("Save to") { saveToPicker }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TransformPalette.card))
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            control()
        }
        .frame(height: 34)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(TransformPalette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    private var compressOptions: some View {
        Group {
            row("Compress by") {
                Picker("Compress by", selection: $model.settings.compress.by) {
                    Text("Quality").tag(TransformEngine.CompressOptions.By.quality)
                    Text("File size").tag(TransformEngine.CompressOptions.By.fileSize)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if model.settings.compress.by == .quality {
                row("Image quality") {
                    Slider(value: $model.settings.compress.quality, in: 0.05...1).frame(width: 104).controlSize(.small)
                    Text("\(Int((model.settings.compress.quality * 100).rounded()))%")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(TransformPalette.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                row("Largest file") {
                    Picker("Largest file", selection: $model.settings.compress.targetBytes) {
                        ForEach([500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 25_000_000], id: \.self) { Text(TransformModel.bytes($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            row("Image format") { formatPicker($model.settings.compress.format) }
            row("Largest side") {
                Picker("Largest side", selection: $model.settings.compress.maxSide) {
                    Text("Keep").tag(Int?.none)
                    ForEach([4096, 2560, 2048, 1920, 1280, 1024], id: \.self) { Text("\($0) px").tag(Int?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Remove metadata") {
                Toggle("Remove metadata", isOn: $model.settings.compress.removeMetadata).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }

    private func formatPicker(_ selection: Binding<TransformEngine.Format>, automatic: Bool = true) -> some View {
        Picker("Format", selection: selection) {
            ForEach(TransformEngine.Format.available.filter { automatic || $0 != .automatic }, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var convertOptions: some View {
        Group {
            row("Convert to") { formatPicker($model.settings.convertFormat, automatic: false) }
            if model.settings.convertFormat.isLossy {
                row("Image quality") {
                    Slider(value: $model.settings.convertQuality, in: 0.05...1).frame(width: 104).controlSize(.small)
                    Text("\(Int((model.settings.convertQuality * 100).rounded()))%")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(TransformPalette.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private var resizeOptions: some View {
        Group {
            row("Resize by") {
                Picker("Resize by", selection: $model.settings.resize.by) {
                    Text("Largest side").tag(TransformEngine.ResizeOptions.By.side)
                    Text("Percent").tag(TransformEngine.ResizeOptions.By.percent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if model.settings.resize.by == .side {
                row("Largest side") {
                    Picker("Largest side", selection: $model.settings.resize.maxSide) {
                        ForEach([4096, 2560, 2048, 1920, 1600, 1280, 1024, 800, 512], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                row("Scale") {
                    Slider(value: $model.settings.resize.percent, in: 5...100, step: 5).frame(width: 104).controlSize(.small)
                    Text("\(Int(model.settings.resize.percent))%")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(TransformPalette.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private var rotateOptions: some View {
        Group {
            row("Turn") {
                Picker("Turn", selection: $model.settings.rotation.quarterTurns) {
                    Text("Left").tag(3)
                    Text("Right").tag(1)
                    Text("180°").tag(2)
                    Text("None").tag(0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            row("Flip horizontally") {
                Toggle("Flip horizontally", isOn: $model.settings.rotation.flipHorizontal).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            row("Flip vertically") {
                Toggle("Flip vertically", isOn: $model.settings.rotation.flipVertical).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }

    private func nameRow(placeholder: String) -> some View {
        row("Name") {
            TextField(placeholder, text: $model.outputName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    private var renameOptions: some View {
        Group {
            row("New name") {
                TextField(model.files.first?.deletingPathExtension().lastPathComponent ?? "Name", text: $model.settings.rename.base)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            row("Number them") {
                Toggle("Number them", isOn: $model.settings.rename.numbered).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if let first = TransformEngine.newNames(for: Array(model.files.prefix(1)), model.settings.rename).first {
                row("Becomes") {
                    Text(first).font(.system(size: 12)).foregroundStyle(TransformPalette.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var saveToPicker: some View {
        Picker("Save to", selection: Binding(get: { model.saveTo }, set: { choice in
            if choice == .folder { model.chooseFolder() } else { model.saveTo = choice }
        })) {
            ForEach([TransformModel.SaveTo.shelf, .pictures, .downloads], id: \.self) { Text($0.title).tag($0) }
            Divider()
            Text(model.folderTitle).tag(TransformModel.SaveTo.folder)
        }
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Estimate, presets, button

    private func estimateRow(_ estimate: (before: Int, after: Int)) -> some View {
        let saving = estimate.before > 0 ? 1 - Double(estimate.after) / Double(estimate.before) : 0
        return HStack(spacing: 8) {
            Text(TransformModel.bytes(estimate.before)).foregroundStyle(TransformPalette.red)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(TransformPalette.secondary)
            Text(TransformModel.bytes(estimate.after)).foregroundStyle(TransformPalette.blue)
            Spacer()
            Text(saving >= 0.005 ? "\(Int((saving * 100).rounded()))% smaller" : saving <= -0.005 ? "\(Int((-saving * 100).rounded()))% larger" : "About the same")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TransformPalette.secondary)
        }
        .font(.system(size: 13.5, weight: .bold).monospacedDigit())
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.system(size: 11, weight: .semibold)).foregroundStyle(TransformPalette.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(model.presets) { preset in
                        cell(label: preset.name, selected: model.settings == preset.settings) {
                            Button { model.apply(preset) } label: {
                                TransformTile { Image(systemName: preset.symbol).font(.system(size: 16, weight: .regular)) }
                            }
                            .buttonStyle(.plain)
                        }
                        .contextMenu {
                            if !preset.builtIn { Button("Delete Preset", role: .destructive) { model.deletePreset(preset) } }
                        }
                    }
                    cell(label: "Save preset") {
                        Button { naming = true } label: {
                            TransformTile { Image(systemName: "plus").font(.system(size: 16, weight: .regular)) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var button: some View {
        Button(action: run) {
            ZStack {
                Capsule().fill(TransformPalette.accent)
                if model.running {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(model.settings.action.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(TransformPressStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(model.running || !model.isAvailable(model.settings.action))
    }
}

// MARK: - Pieces

/// Droppy's palette for Transform, sampled raw from its window, with dark counterparts.
enum TransformPalette {
    static let panel = Color(light: 0xF2F1F1, dark: 0x232325)
    static let tile = Color(light: 0xE5E5E5, dark: 0x343437)
    static let tilePressed = Color(light: 0xCCCCCB, dark: 0x45454A)
    static let card = Color(light: 0xDDDDDD, dark: 0x2C2C2F)
    static let close = Color(light: 0xD2D2D0, dark: 0x3A3A3D)
    static let accent = Color(light: 0x454CF2, dark: 0x5560F5)
    static let red = Color(light: 0xBD2420, dark: 0xFF6B5C)
    static let blue = Color(light: 0x434AF0, dark: 0x8F97FF)
    static let text = Color(light: 0x242424, dark: 0xF2F2F2)
    static let secondary = Color(light: 0x5F5F5E, dark: 0x9C9CA1)
    /// The glyphs on the tiles: a mid grey, not black.
    static let glyph = Color(light: 0x555555, dark: 0xD0D0D4)
}

extension Color {
    /// One colour in light mode, another in dark.
    init(light: UInt32, dark: UInt32) {
        func rgb(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }
}

/// A 76 × 40 tile: soft grey, blue with a white glyph when chosen, darker while pressed.
struct TransformTile<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        content
            .foregroundStyle(selected ? Color.white : TransformPalette.glyph)
            .frame(width: 76, height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? TransformPalette.accent : (hovered ? TransformPalette.tilePressed : TransformPalette.tile)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A file's picture in its tile: a glyph for its kind.
private struct FileGlyph: View {
    let url: URL

    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .regular))
    }

    private var symbol: String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc"
    }
}

/// Transform's icon: a page with turning arrows on a blue tile.
private struct TransformAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(light: 0xBBBDFE, dark: 0xBBBDFE), Color(light: 0x131AEC, dark: 0x131AEC)],
                                     startPoint: .top, endPoint: .bottom))
            Image(systemName: "doc.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .offset(x: -2, y: -1)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Color(light: 0x131AEC, dark: 0x131AEC))
                .frame(width: 12, height: 12)
                .background(Circle().fill(.white))
                .offset(x: 5, y: 5)
        }
        .frame(width: 30, height: 30)
    }
}

/// The pane: Liquid Glass under Droppy's light grey, with a bright rim.
private struct TransformGlass: View {
    let shape: RoundedRectangle

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
            // Nearly opaque: the grey stays Droppy's whatever is behind, so the tiles and
            // card keep their contrast; the glass shows at the rim.
            shape.fill(TransformPalette.panel.opacity(0.985))
            shape.strokeBorder(.white.opacity(0.55), lineWidth: 1)
        }
    }
}

/// The wide button sinks a little while pressed.
private struct TransformPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
