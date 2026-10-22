import BackgroundKit
import SwiftUI
import UniformTypeIdentifiers

/// The editor chrome's shared measures, so every bar, button and label agrees.
enum EditorChrome {
    /// Icons in the toolbars and bars.
    static let iconSize: CGFloat = 14
    /// Labels, values and buttons in the options bar.
    static let labelSize: CGFloat = 12
    /// The status bar and other quiet text.
    static let captionSize: CGFloat = 11
    static let buttonSize = CGSize(width: 32, height: 28)
    static let buttonRadius: CGFloat = 7
    static let groupRadius: CGFloat = 10
    static let groupFill = Color.primary.opacity(0.04)
    static let hoverFill = Color.primary.opacity(0.08)
    static let edge = Color.primary.opacity(0.06)
    /// The one accent: the active tool, prominent buttons and selections.
    static let accent = Color.brand
}

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
    /// Pick images to lay beside this one (the toolbar's Compare button).
    var onAddImages: () -> Void = {}
    var onCreateTask: () -> Void = {}
    let windowButtons: WindowButtons
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .preview {
                PreviewToolbar(model: model, title: title, fileName: fileName, onCopy: onCopy, onDelete: onDelete, windowButtons: windowButtons)
                Divider()
            } else {
                EditorToolbar(model: model, fileName: fileName, onCopy: onCopy, onSave: onSave, onExport: onExport, onDelete: onDelete, onDone: onDone, onAddImages: onAddImages, onCreateTask: onCreateTask, windowButtons: windowButtons)
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
            .overlay { CompareDropTarget(active: dropTargeted) }
            // Images dropped on the canvas are laid beside this one, so a capture can be
            // compared with a design, a previous run, or anything else on disk.
            .onDrop(of: ImageDrop.contentTypes, isTargeted: $dropTargeted) { providers in
                compare(with: providers)
                return true
            }
            Divider()
            EditorStatusBar(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.tool == .background) { _, _ in
            // The sidebar changes the canvas width; re-fit once the new layout has settled.
            Task { @MainActor in
                await Task.yield()
                model.applyZoom(.fit)
            }
        }
    }

    /// Reads the dropped images off the main thread's back and composes them in.
    private func compare(with providers: [NSItemProvider]) {
        Task { @MainActor in
            let images = await ImageDrop.captures(from: providers)
            guard !images.isEmpty else {
                FeedbackHUD.show("No image in what was dropped", symbol: "photo")
                return
            }
            guard model.compare(with: images) else {
                FeedbackHUD.show("The images could not be combined", symbol: "exclamationmark.triangle")
                return
            }
            if model.mode == .preview { model.mode = .edit }
            FeedbackHUD.show(images.count == 1 ? "Image added" : "\(images.count) images added",
                             symbol: "rectangle.split.2x1", duration: .seconds(1.2))
        }
    }
}

/// The frame and hint shown while images hover over the canvas.
private struct CompareDropTarget: View {
    let active: Bool

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, style: SwiftUI.StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(6)
            Label("Drop to compare", systemImage: "rectangle.split.2x1")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
        }
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: active)
        .allowsHitTesting(false)
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
                    .frame(width: EditorChrome.buttonSize.width, height: EditorChrome.buttonSize.height)
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
}

// MARK: - Toolbar

struct EditorToolbar: View {
    static let height: CGFloat = 52

    let model: EditorViewModel
    let fileName: String
    let onCopy: () -> Void
    let onSave: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onDone: () -> Void
    var onAddImages: () -> Void = {}
    var onCreateTask: () -> Void = {}
    let windowButtons: WindowButtons
    @State private var copied = false

    /// Tools grouped by what they are for: framing, drawing, pointing out, hiding.
    private let toolGroups: [[EditorTool]] = [
        [.select],
        [.background, .crop],
        [.pencil, .highlighter, .highlight],
        [.shape, .arrow, .text, .counter],
        [.blur],
    ]

    var body: some View {
        ZStack {
            WindowDragArea()
            // Tools centred in the bar while there is room, sliding aside rather than
            // under the buttons at either end when the window is narrow. The buttons on
            // the right fold into a menu before anything overlaps.
            ToolbarRowLayout(gap: 12) {
                TrafficLights(onClose: windowButtons.close, onMinimize: windowButtons.minimize, onZoom: windowButtons.zoom)
                ViewThatFits(in: .horizontal) {
                    tools(compact: false)
                    tools(compact: true)
                }
                ViewThatFits(in: .horizontal) {
                    actions
                    compactActions
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: EditorToolbar.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// One pill per kind of tool. Compact, for a narrow window, folds the shapes into one
    /// button showing the last one used.
    private func tools(compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(toolGroups, id: \.self) { tools in
                ToolGroup {
                    ForEach(tools) { tool in
                        // Each shape is its own button, so a circle or a line is one click.
                        if tool == .shape {
                            if compact {
                                ShapeGroupButton(model: model)
                            } else {
                                ForEach(ShapeKind.allCases) { kind in ToolButton(tool: tool, shape: kind, model: model) }
                            }
                        } else {
                            ToolButton(tool: tool, model: model)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ToolGroup {
                IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) { model.undo() }
                IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
            }
            ToolGroup {
                copyButton
                IconButton(symbol: "rectangle.split.2x1", help: "Compare with other images — or drop them on the canvas", action: onAddImages)
                dragOut
                IconButton(symbol: "trash", help: "Delete capture", tint: .red.opacity(0.9), action: onDelete)
            }
            ToolbarPillButton(title: "Create Task", prominent: false, action: onCreateTask)
                .help("A new task with this capture — write what to do above it")
            ToolbarPillButton(title: "Export…", prominent: false, action: onExport)
                .help("Export a copy (⇧⌘S)")
            ToolbarPillButton(title: "Done", prominent: true, action: onDone)
                .help("Save and close")
        }
        .fixedSize()
    }

    /// The narrow window's version: Copy and drag-out stay to hand, the rest (all with
    /// shortcuts or used rarely) go in a menu, and Export shrinks to its icon.
    private var compactActions: some View {
        HStack(spacing: 8) {
            ToolGroup {
                copyButton
                dragOut
                Menu {
                    Button("Undo") { model.undo() }.disabled(!model.canUndo)
                    Button("Redo") { model.redo() }.disabled(!model.canRedo)
                    Divider()
                    Button("Compare with Other Images…", action: onAddImages)
                    Button("Create Task…", action: onCreateTask)
                    Button("Export…", action: onExport)
                    Divider()
                    Button("Delete Capture", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: EditorChrome.iconSize, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .frame(width: EditorChrome.buttonSize.width, height: EditorChrome.buttonSize.height)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            ToolbarPillButton(title: "Done", prominent: true, action: onDone)
                .help("Save and close")
        }
        .fixedSize()
    }

    private var copyButton: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy to clipboard (⌘C)", tint: copied ? .green : nil) {
            // Feedback first; the copy is a pasteboard promise and doesn't block.
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            onCopy()
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { copied = false }
            }
        }
    }

    private var dragOut: some View {
        DragOutView(
            fileName: fileName,
            render: { model.renderedImage().flatMap(DocumentExporter.pngData) },
            thumbnail: { model.renderedImage().map { NSImage(cgImage: $0, size: model.document.outputSize) } }
        )
        .frame(width: EditorChrome.buttonSize.width, height: EditorChrome.buttonSize.height)
        .help("Drag into another app")
    }
}

/// The toolbar's row: leading item at the left edge, trailing at the right, and the middle
/// centred in the window — or, when that would run into either end, as close to centre as
/// it can get. The trailing item is offered only the width the others leave, so a
/// `ViewThatFits` there picks the version that fits.
struct ToolbarRowLayout: Layout {
    var gap: CGFloat

    /// The measurements for one width. Measuring a `ViewThatFits` measures every version
    /// inside it, so it is done once per width rather than on every pass.
    struct Cache {
        var width: CGFloat = -1
        var leading: CGSize = .zero
        var middle: CGSize = .zero
        var trailing: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + 2 * gap
        return CGSize(width: width, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }
        if cache.width != bounds.width { measure(bounds, subviews: subviews, cache: &cache) }
        let (leading, middle, trailing) = (cache.leading, cache.middle, cache.trailing)

        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(leading))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailing))

        let lowest = bounds.minX + leading.width + gap
        let highest = bounds.maxX - trailing.width - gap - middle.width
        let centred = bounds.midX - middle.width / 2
        let x = highest >= lowest ? min(max(centred, lowest), highest) : lowest
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(middle))
    }

    private func measure(_ bounds: CGRect, subviews: Subviews, cache: inout Cache) {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let room = max(0, bounds.width - leading.width - 2 * gap)

        // The middle and the trailing item each come full or compact (a `ViewThatFits`
        // offered no width answers with its smallest version). Fold the trailing buttons
        // first, then the tools.
        func width(_ index: Int, compact: Bool) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: compact ? 0 : nil, height: bounds.height)).width
        }
        let middleFull = width(1, compact: false)
        let middleOffer = middleFull + width(2, compact: true) <= room ? middleFull : width(1, compact: true)
        let middle = subviews[1].sizeThatFits(ProposedViewSize(width: middleOffer, height: bounds.height))
        let trailing = subviews[2].sizeThatFits(ProposedViewSize(width: max(0, room - middle.width), height: bounds.height))
        cache = Cache(width: bounds.width, leading: leading, middle: middle, trailing: trailing)
    }
}

/// The shapes folded into one button for a narrow toolbar: it shows the last shape used
/// and picks it; a click also opens the three side by side to choose another.
private struct ShapeGroupButton: View {
    let model: EditorViewModel
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        let active = model.tool == .shape
        Button {
            model.tool = .shape
            expanded = true
        } label: {
            Image(systemName: model.shapeKind.symbol)
                .font(.system(size: EditorChrome.iconSize, weight: .semibold))
                .frame(width: EditorChrome.buttonSize.width, height: EditorChrome.buttonSize.height)
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
                .overlay(alignment: .bottomTrailing) {
                    // Says there is more here than one shape.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .heavy))
                        .foregroundStyle(active ? Color.white.opacity(0.8) : Color.primary.opacity(0.45))
                        .padding(3)
                }
                .background(
                    RoundedRectangle(cornerRadius: EditorChrome.buttonRadius, style: .continuous)
                        .fill(active ? EditorChrome.accent : (hovering ? EditorChrome.hoverFill : Color.clear))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(model.shapeKind.title) (R) — click for other shapes")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            HStack(spacing: 2) {
                ForEach(ShapeKind.allCases) { kind in
                    ToolButton(tool: .shape, shape: kind, model: model) { expanded = false }
                }
            }
            .padding(5)
        }
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
                if let symbol { Image(systemName: symbol).font(.system(size: EditorChrome.labelSize, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: EditorChrome.groupRadius, style: .continuous)
                    .fill(prominent ? EditorChrome.accent.opacity(hovering ? 0.88 : 1) : (hovering ? EditorChrome.hoverFill : EditorChrome.groupFill))
            )
            .overlay(RoundedRectangle(cornerRadius: EditorChrome.groupRadius, style: .continuous).strokeBorder(prominent ? .clear : EditorChrome.edge))
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
                RoundedRectangle(cornerRadius: EditorChrome.groupRadius, style: .continuous)
                    .fill(EditorChrome.groupFill)
            )
            .overlay(RoundedRectangle(cornerRadius: EditorChrome.groupRadius, style: .continuous).strokeBorder(EditorChrome.edge))
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    /// For the shape tool: which shape this button draws.
    var shape: ShapeKind?
    let model: EditorViewModel
    /// Called after the tool is picked: the folded shape group closes its popover.
    var onPick: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        let active = model.tool == tool && (shape == nil || model.shapeKind == shape)
        Button {
            if let shape { model.shapeKind = shape }
            model.tool = tool
            onPick()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: EditorChrome.iconSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: EditorChrome.buttonSize.width, height: EditorChrome.buttonSize.height)
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: EditorChrome.buttonRadius, style: .continuous)
                        .fill(active ? EditorChrome.accent : (hovering ? EditorChrome.hoverFill : Color.clear))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shape.map { "\($0.title) (\(String(tool.key).uppercased()))" } ?? "\(tool.title) (\(String(tool.key).uppercased()))")
    }

    private var symbol: String {
        if let shape { return shape.symbol }
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
                .font(.system(size: EditorChrome.iconSize, weight: .semibold))
                .frame(width: EditorChrome.buttonSize.width, height: EditorChrome.buttonSize.height)
                .foregroundStyle(tint ?? (enabled ? Color.primary.opacity(0.85) : Color.primary.opacity(0.3)))
                .contentTransition(.symbolEffect(.replace))
                .background(RoundedRectangle(cornerRadius: EditorChrome.buttonRadius, style: .continuous).fill(hovering && enabled ? EditorChrome.hoverFill : Color.clear))
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
        HStack(spacing: 12) {
            // Which tool this row sets, and its key, so the shortcuts are learnt by using it.
            HStack(spacing: 6) {
                Text(model.tool == .shape ? model.shapeKind.title : model.tool.title)
                    .font(.system(size: EditorChrome.labelSize, weight: .semibold))
                KeyCap(String(model.tool.key).uppercased())
            }
            separator
            switch model.tool {
            case .select:
                if model.selected != nil {
                    colorPicker
                    separator
                    OptionButton(title: "Duplicate", symbol: "plus.square.on.square") { model.duplicateSelected() }
                    OptionButton(title: "Delete", symbol: "trash", role: .destructive) { model.deleteSelected() }
                }
            case .background:
                EmptyView()
            case .crop:
                hint("Drag the handles, then press ↩ to crop")
                Spacer()
                OptionButton(title: "Reset") { model.resetCrop() }
                OptionButton(title: "Crop", symbol: "crop", role: .prominent) { model.applyCrop() }
            case .pencil:
                colorPicker
                separator
                strokePicker(width: $model.strokeWidth, range: EditorDefaults.strokeRange)
                separator
                Toggle(isOn: $model.smartShapes) {
                    Label("Smart shapes", systemImage: "wand.and.stars")
                        .font(.system(size: EditorChrome.labelSize))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Turn a drawn line, circle, box or arrow into a clean one")
            case .highlighter:
                colorPicker
                separator
                strokePicker(width: $model.highlighterWidth, range: EditorDefaults.highlighterRange)
            case .highlight:
                swatches([RGBA.yellow, .green, .orange, .pink, .blue, .purple], selection: $model.highlightColor)
                separator
                hint("Drag a box over text to highlight it")
            case .shape:
                colorPicker
                separator
                strokePicker(width: $model.strokeWidth, range: EditorDefaults.strokeRange)
                if model.shapeKind != .line {
                    separator
                    Picker("", selection: $model.fillMode) {
                        Text("Outline").tag(FillMode.none)
                        Text("Filled").tag(FillMode.solid)
                        Text("Tinted").tag(FillMode.translucent)
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
            case .arrow:
                colorPicker
                separator
                strokePicker(width: $model.strokeWidth, range: EditorDefaults.strokeRange)
                separator
                Picker("", selection: $model.arrowStyle) {
                    Image(systemName: "arrow.right").tag(ArrowStyle.single)
                    Image(systemName: "arrow.left.and.right").tag(ArrowStyle.double)
                }
                .pickerStyle(.segmented).fixedSize()
            case .text:
                colorPicker
                separator
                labelled("Size") {
                    Slider(value: $model.fontSize, in: EditorDefaults.fontSizeRange).frame(width: 96)
                    value("\(Int(model.fontSize))")
                }
                labelled("Weight") {
                    Slider(value: $model.fontWeight, in: TextStyle.weightRange).frame(width: 80)
                    Text(TextStyle(color: model.color, fontSize: model.fontSize, background: model.textBackground, weight: model.fontWeight).weightName)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                }
                separator
                Picker("", selection: $model.textBackground) {
                    Text("Plain").tag(TextBackground.none)
                    Text("Box").tag(TextBackground.solid)
                    Text("Dark box").tag(TextBackground.translucent)
                }
                .pickerStyle(.segmented).fixedSize()
            case .blur:
                Picker("", selection: $model.blurKind) {
                    Text("Blur").tag(BlurKind.blur)
                    Text("Pixelate").tag(BlurKind.pixelate)
                }
                .pickerStyle(.segmented).fixedSize()
                separator
                labelled("Intensity") {
                    Slider(value: $model.blurIntensity, in: EditorDefaults.blurRange).frame(width: 120)
                    value("\(Int(model.blurIntensity))")
                }
            case .counter:
                colorPicker
                separator
                labelled("Size") {
                    Slider(value: $model.counterSize, in: EditorDefaults.counterRange).frame(width: 110)
                    value("\(Int(model.counterSize))")
                }
                separator
                hint("Click to place 1, 2, 3…")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .font(.system(size: EditorChrome.labelSize))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var separator: some View {
        Rectangle().fill(EditorChrome.edge).frame(width: 1, height: 18)
    }

    private func hint(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1)
    }

    private func value(_ text: String) -> some View {
        Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            content()
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 6) {
            swatches(RGBA.palette, selection: $model.color)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: model.color.nsColor) },
                set: { model.color = RGBA(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24)
        }
    }

    /// A row of colour dots; the chosen one wears a ring.
    private func swatches(_ colors: [RGBA], selection: Binding<RGBA>) -> some View {
        HStack(spacing: 4) {
            ForEach(colors, id: \.self) { swatch in
                let chosen = selection.wrappedValue == swatch
                Button { selection.wrappedValue = swatch } label: {
                    Circle()
                        .fill(Color(nsColor: swatch.nsColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                        .padding(2)
                        .overlay(Circle().strokeBorder(chosen ? EditorChrome.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func strokePicker(width: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        labelled("Width") {
            Slider(value: width, in: range).frame(width: 100)
            value("\(Int(width.wrappedValue))")
        }
    }
}

/// A compact text button for the options bar, in the toolbar's style.
struct OptionButton: View {
    enum Role { case normal, prominent, destructive }

    let title: String
    var symbol: String?
    var role: Role = .normal
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: EditorChrome.labelSize, weight: .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: EditorChrome.buttonRadius, style: .continuous).fill(background))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch role {
        case .prominent: .white
        case .destructive: .red.opacity(0.9)
        case .normal: .primary.opacity(0.85)
        }
    }

    private var background: Color {
        switch role {
        case .prominent: EditorChrome.accent.opacity(hovering ? 0.88 : 1)
        case .destructive: Color.red.opacity(hovering ? 0.14 : 0.08)
        case .normal: hovering ? EditorChrome.hoverFill : EditorChrome.groupFill
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
            HStack(spacing: 0) {
                StatusButton(symbol: "minus", help: "Zoom out (⌘−)") { model.applyZoom(.zoomOut) }
                Button { model.applyZoom(.actualSize) } label: {
                    Text("\(Int((model.zoom * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Actual size (⌘1)")
                StatusButton(symbol: "plus", help: "Zoom in (⌘+)") { model.applyZoom(.zoomIn) }
                StatusButton(symbol: "arrow.down.left.and.arrow.up.right", help: "Fit to window (⌘0)") { model.applyZoom(.fit) }
            }
        }
        .font(.system(size: EditorChrome.captionSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A small icon button for the status bar.
private struct StatusButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? EditorChrome.hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
