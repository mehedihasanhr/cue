import SwiftUI

/// Window-control actions supplied by the window controller.
struct WindowButtons {
    var close: () -> Void
    var minimize: () -> Void
    var zoom: () -> Void
}

struct EditorView: View {
    let model: EditorViewModel
    let title: String
    let fileName: String
    let onCopy: () -> Void
    let onSave: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onDone: () -> Void
    let windowButtons: WindowButtons

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .preview {
                PreviewToolbar(model: model, title: title, fileName: fileName, onCopy: onCopy, onDelete: onDelete, windowButtons: windowButtons)
                Divider()
            } else {
                EditorToolbar(model: model, fileName: fileName, onCopy: onCopy, onSave: onSave, onExport: onExport, onDone: onDone, windowButtons: windowButtons)
                Divider()
                // The options row only appears when there is something to set.
                if model.tool != .background, !(model.tool == .select && model.selectedID == nil) {
                    OptionsBar(model: model)
                    Divider()
                }
            }
            HStack(spacing: 0) {
                if model.mode == .edit, model.tool == .background {
                    BackgroundSidebar(model: model)
                    Divider()
                }
                CanvasRepresentable(model: model)
            }
            Divider()
            EditorStatusBar(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.tool == .background) { _, _ in
            // The sidebar changes the canvas width; re-fit once the new layout has settled.
            Task { @MainActor in
                await Task.yield()
                model.zoomCommand = .fit
            }
        }
    }
}

// MARK: - Preview toolbar

/// Read-only chrome: title in the middle, zoom / copy / delete / Edit on the right.
struct PreviewToolbar: View {
    let model: EditorViewModel
    let title: String
    let fileName: String
    let onCopy: () -> Void
    let onDelete: () -> Void
    let windowButtons: WindowButtons
    @State private var copied = false

    var body: some View {
        ZStack {
            WindowDragArea()
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)

            HStack(spacing: 8) {
                TrafficLights(onClose: windowButtons.close, onMinimize: windowButtons.minimize, onZoom: windowButtons.zoom)
                Spacer()
                ToolGroup {
                    IconButton(symbol: "minus.magnifyingglass", help: "Zoom out (⌘−)") { model.zoomCommand = .zoomOut }
                    Text("\(Int((model.zoom * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 40)
                    IconButton(symbol: "plus.magnifyingglass", help: "Zoom in (⌘+)") { model.zoomCommand = .zoomIn }
                    IconButton(symbol: "arrow.down.left.and.arrow.up.right", help: "Fit to window (⌘0)") { model.zoomCommand = .fit }
                }
                ToolGroup {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy to clipboard (⌘C)", tint: copied ? .green : nil) {
                        // Feedback first; the copy is a pasteboard promise and doesn't block.
                        withAnimation(.easeOut(duration: 0.15)) { copied = true }
                        onCopy()
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation { copied = false }
                        }
                    }
                    DragOutView(
                        fileName: fileName,
                        render: { model.renderedImage().flatMap(DocumentExporter.pngData) },
                        thumbnail: { model.renderedImage().map { NSImage(cgImage: $0, size: model.document.outputSize) } }
                    )
                    .frame(width: 32, height: 28)
                    .help("Drag into another app")
                    IconButton(symbol: "trash", help: "Delete capture", tint: .red.opacity(0.9), action: onDelete)
                }
                ToolbarPillButton(title: "Edit", symbol: "pencil", prominent: true) { model.mode = .edit }
                    .help("Open the annotation tools")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: EditorToolbar.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbarDivider: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 5)
    }
}

// MARK: - Toolbar

struct EditorToolbar: View {
    static let height: CGFloat = 52

    let model: EditorViewModel
    let fileName: String
    let onCopy: () -> Void
    let onSave: () -> Void
    let onExport: () -> Void
    let onDone: () -> Void
    let windowButtons: WindowButtons
    @State private var copied = false

    private let annotationTools: [EditorTool] = [.pencil, .highlighter, .highlight, .shape, .arrow, .text, .blur, .counter]

    var body: some View {
        ZStack {
            WindowDragArea()
            // Tools centred in the bar, grouped into pills: frame tools, then annotation tools.
            HStack(spacing: 8) {
                ToolGroup { ToolButton(tool: .select, model: model) }
                ToolGroup {
                    ToolButton(tool: .background, model: model)
                    ToolButton(tool: .crop, model: model)
                }
                ToolGroup {
                    ForEach(annotationTools) { tool in
                        ToolButton(tool: tool, model: model)
                    }
                }
            }

            HStack(spacing: 8) {
                TrafficLights(onClose: windowButtons.close, onMinimize: windowButtons.minimize, onZoom: windowButtons.zoom)
                Spacer()
                ToolGroup {
                    IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) { model.undo() }
                    IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
                }
                ToolGroup {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy to clipboard (⌘C)", tint: copied ? .green : nil) {
                        // Feedback first; the copy is a pasteboard promise and doesn't block.
                        withAnimation(.easeOut(duration: 0.15)) { copied = true }
                        onCopy()
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation { copied = false }
                        }
                    }
                    IconButton(symbol: "square.and.arrow.up", help: "Export… (⇧⌘S)", action: onExport)
                    DragOutView(
                        fileName: fileName,
                        render: { model.renderedImage().flatMap(DocumentExporter.pngData) },
                        thumbnail: { model.renderedImage().map { NSImage(cgImage: $0, size: model.document.outputSize) } }
                    )
                    .frame(width: 32, height: 28)
                    .help("Drag into another app")
                }
                ToolbarPillButton(title: "Save as…", prominent: false, action: onExport)
                    .help("Export a copy (⇧⌘S)")
                ToolbarPillButton(title: "Done", prominent: true, action: onDone)
                    .help("Save and close (⌘S)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: EditorToolbar.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbarDivider: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 5)
    }
}

/// Text button matching the height and radius of a `ToolGroup` (28pt content + 3pt padding).
struct ToolbarPillButton: View {
    let title: String
    var symbol: String?
    var prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Color.brand.opacity(hovering ? 0.88 : 1) : Color.primary.opacity(hovering ? 0.08 : 0.035))
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(prominent ? 0 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A pill grouping related toolbar buttons, like CleanShot's toolbar segments.
struct ToolGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.035))
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.05)))
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let model: EditorViewModel
    @State private var hovering = false

    var body: some View {
        let active = model.tool == tool
        Button { model.tool = tool } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: 32, height: 28)
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.accentColor : (hovering ? Color.primary.opacity(0.1) : Color.clear))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
    }

    private var symbol: String {
        if tool == .shape { return model.shapeKind.symbol }
        if tool == .blur { return model.blurKind == .blur ? "drop.fill" : "checkerboard.rectangle" }
        return tool.symbol
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .frame(width: 32, height: 28)
                .foregroundStyle(tint ?? (enabled ? Color.primary.opacity(0.85) : Color.primary.opacity(0.3)))
                .contentTransition(.symbolEffect(.replace))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && enabled ? Color.primary.opacity(0.1) : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Options bar

struct OptionsBar: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        HStack(spacing: 14) {
            switch model.tool {
            case .select:
                if model.selected != nil {
                    colorPicker
                    Divider().frame(height: 18)
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                    Button("Duplicate") { model.duplicateSelected() }
                }
            case .background:
                EmptyView()
            case .crop:
                hint("Drag the handles, then press ↩ to crop")
                Spacer()
                Button("Reset") { model.resetCrop() }
                Button("Crop") { model.applyCrop() }.buttonStyle(.borderedProminent).tint(.brand)
            case .pencil:
                colorPicker
                strokePicker(width: $model.strokeWidth, range: 1...24)
            case .highlighter:
                colorPicker
                strokePicker(width: $model.highlighterWidth, range: 6...48)
            case .highlight:
                HStack(spacing: 5) {
                    ForEach([RGBA.yellow, .green, .orange, .pink, .blue, .purple], id: \.self) { swatch in
                        Button { model.highlightColor = swatch } label: {
                            Circle()
                                .fill(Color(nsColor: swatch.nsColor))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.primary.opacity(model.highlightColor == swatch ? 0.95 : 0.3), lineWidth: model.highlightColor == swatch ? 2 : 1))
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                hint("Drag a box over text to highlight it")
            case .shape:
                Picker("", selection: $model.shapeKind) {
                    ForEach(ShapeKind.allCases) { kind in Image(systemName: kind.symbol).tag(kind) }
                }
                .pickerStyle(.segmented).frame(width: 120)
                colorPicker
                strokePicker(width: $model.strokeWidth, range: 1...24)
                if model.shapeKind != .line {
                    Picker("Fill", selection: $model.fillMode) {
                        Text("Outline").tag(FillMode.none)
                        Text("Filled").tag(FillMode.solid)
                        Text("Tinted").tag(FillMode.translucent)
                    }
                    .pickerStyle(.segmented).frame(width: 190)
                }
            case .arrow:
                colorPicker
                strokePicker(width: $model.strokeWidth, range: 1...24)
                Picker("", selection: $model.arrowStyle) {
                    Image(systemName: "arrow.right").tag(ArrowStyle.single)
                    Image(systemName: "arrow.left.and.right").tag(ArrowStyle.double)
                }
                .pickerStyle(.segmented).frame(width: 90)
            case .text:
                colorPicker
                labelled("Size") {
                    Slider(value: $model.fontSize, in: 8...96).frame(width: 100)
                    Text("\(Int(model.fontSize))").monospacedDigit().frame(width: 26)
                }
                labelled("Weight") {
                    Slider(value: $model.fontWeight, in: TextStyle.weightRange).frame(width: 90)
                    Text(TextStyle(color: model.color, fontSize: model.fontSize, background: model.textBackground, weight: model.fontWeight).weightName)
                        .frame(width: 58, alignment: .leading)
                }
                Picker("Style", selection: $model.textBackground) {
                    Text("Plain").tag(TextBackground.none)
                    Text("Box").tag(TextBackground.solid)
                    Text("Dark box").tag(TextBackground.translucent)
                }
                .pickerStyle(.segmented).frame(width: 200)
            case .blur:
                Picker("", selection: $model.blurKind) {
                    Text("Blur").tag(BlurKind.blur)
                    Text("Pixelate").tag(BlurKind.pixelate)
                }
                .pickerStyle(.segmented).frame(width: 140)
                labelled("Intensity") {
                    Slider(value: $model.blurIntensity, in: 4...40).frame(width: 140)
                }
            case .counter:
                colorPicker
                labelled("Size") {
                    Slider(value: $model.counterSize, in: 18...64).frame(width: 120)
                }
                hint("Click to place 1, 2, 3…")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func hint(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            content()
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 5) {
            ForEach(RGBA.palette, id: \.self) { swatch in
                Button { model.color = swatch } label: {
                    Circle()
                        .fill(Color(nsColor: swatch.nsColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.primary.opacity(model.color == swatch ? 0.95 : 0.3), lineWidth: model.color == swatch ? 2 : 1))
                        .padding(2)
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: model.color.nsColor) },
                set: { model.color = RGBA(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24)
        }
    }

    private func strokePicker(width: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        labelled("Width") {
            Slider(value: width, in: range).frame(width: 110)
            Text("\(Int(width.wrappedValue))").monospacedDigit().frame(width: 22)
        }
    }

}

// MARK: - Status bar

struct EditorStatusBar: View {
    let model: EditorViewModel

    var body: some View {
        HStack(spacing: 12) {
            let size = model.document.outputSize
            let scale = model.document.scale
            Text("\(Int(size.width * scale)) × \(Int(size.height * scale)) px · \(Int(size.width)) × \(Int(size.height)) pt · @\(Int(scale))x")
                .monospacedDigit()
            if model.document.crop != nil {
                Text("· cropped").foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                IconButton(symbol: "minus.magnifyingglass", help: "Zoom out (⌘−)") { model.zoomCommand = .zoomOut }
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44)
                IconButton(symbol: "plus.magnifyingglass", help: "Zoom in (⌘+)") { model.zoomCommand = .zoomIn }
                Button("Fit") { model.zoomCommand = .fit }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("100%") { model.zoomCommand = .actualSize }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
