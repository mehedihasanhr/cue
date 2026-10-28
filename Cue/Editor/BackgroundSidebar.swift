import BackgroundKit
import SwiftUI

/// What the screenshot sits on, in the Background tool's left sidebar.
///
/// Two levels, the way Cue Studio does it. The kind is a pop-up on the section heading —
/// Wallpaper, Color, Image or None — and under it are only that kind's choices: a preview
/// of the chosen wallpaper over a short grid of the rest, Solid or Gradient swatches, or
/// the picture you added. The card's layout (padding, shadow, corners, ratio) follows in a
/// section of its own, in the same filled rows.
struct BackgroundSidebar: View {
    @Bindable var model: EditorViewModel

    /// Holds Image open before a picture has been chosen; otherwise the kind is read from
    /// the document, so undo moves the pop-up back with the background.
    @State private var kindOverride: Kind?
    @State private var showsAllWallpapers = false
    @State private var showsAllGradients = false
    @State private var colorEditEnd: Task<Void, Never>?

    static let width: CGFloat = 250

    private static let collapsedRows = 2
    private let swatchColumns = Array(repeating: GridItem(.flexible(minimum: 22), spacing: 4), count: 6)
    private let colorColumns = Array(repeating: GridItem(.flexible(minimum: 18), spacing: 2), count: 9)

    private var catalog: WallpaperCatalog { WallpaperCatalog.shared }
    private var fill: BackgroundFill { model.background.fill }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SidebarTheme.betweenSections) {
                backgroundSection
                if model.document.background != nil {
                    layoutSection
                }
            }
            .padding(SidebarTheme.inset)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .background(SidebarTheme.panel)
        .task { await catalog.prepareThumbnails() }
    }

    // MARK: - Kind

    enum Kind: String, CaseIterable, Hashable {
        case wallpaper, color, image, none

        var title: String {
            switch self {
            case .wallpaper: "Wallpaper"
            case .color: "Color"
            case .image: "Image"
            case .none: "None"
            }
        }

        var systemImage: String {
            switch self {
            case .wallpaper: "photo.on.rectangle"
            case .color: "paintpalette"
            case .image: "photo"
            case .none: "square.dashed"
            }
        }
    }

    private var documentKind: Kind {
        guard model.document.background != nil else { return .none }
        switch fill {
        case .solid, .gradient: return .color
        case .image(let wallpaper): return wallpaper.isCustom ? .image : .wallpaper
        }
    }

    private var kind: Binding<Kind> {
        Binding {
            kindOverride ?? documentKind
        } set: { chosen in
            kindOverride = nil
            guard chosen != documentKind else { return }
            switch chosen {
            case .wallpaper:
                if let first = catalog.systemWallpapers.first { select(first) }
            case .color:
                setFill(.gradient(.ocean))
            case .image:
                // Nothing to switch to until a picture is chosen; the last one added, if
                // any, otherwise hold the kind open on its Choose button.
                if let recent = catalog.customWallpapers.last {
                    select(recent)
                } else {
                    kindOverride = .image
                }
            case .none:
                model.commit { $0.background = nil }
            }
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: SidebarTheme.betweenGroups) {
            SidebarHeader("Background") {
                SidebarMenu(selection: kind, options: Kind.allCases, title: \.title,
                            systemImage: \.systemImage, style: .ghost)
                    .help("What the screenshot sits on")
                    .accessibilityLabel("Kind of background")
            }
            switch kind.wrappedValue {
            case .wallpaper: wallpapers
            case .color: colors
            case .image: image
            case .none: transparent
            }
        }
    }

    // MARK: - Wallpaper

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: SidebarTheme.betweenGroups) {
            if case .image(let wallpaper) = fill {
                WallpaperPeek(wallpaper: wallpaper)
            }

            let all = catalog.systemWallpapers
            let collapsed = swatchColumns.count * Self.collapsedRows
            VStack(alignment: .leading, spacing: 6) {
                SidebarSubheading("From macOS") {
                    if all.count > collapsed {
                        ShowAllButton(isExpanded: $showsAllWallpapers, count: all.count)
                    }
                }
                LazyVGrid(columns: swatchColumns, spacing: 4) {
                    ForEach(showsAllWallpapers ? all : visible(all, limit: collapsed), id: \.self) { wallpaper in
                        SidebarSwatch(isSelected: fill == .image(wallpaper), title: wallpaper.title) {
                            select(wallpaper)
                        } content: {
                            thumbnail(wallpaper)
                        }
                    }
                }
            }

            blurSlider
        }
    }

    /// The first rows, keeping the chosen one in view: if it is further down, it takes the
    /// last place so the grid always shows what is selected.
    private func visible(_ all: [Wallpaper], limit: Int) -> [Wallpaper] {
        var shown = Array(all.prefix(limit))
        if case .image(let chosen) = fill, !shown.contains(chosen), all.contains(chosen), !shown.isEmpty {
            shown[shown.count - 1] = chosen
        }
        return shown
    }

    private var blurSlider: some View {
        ScrubSlider(title: "Blur",
                    value: Binding(get: { model.background.imageBlur },
                                   set: { model.background.imageBlur = $0.rounded() }),
                    range: 0...30,
                    defaultValue: 0,
                    onEditingChanged: editing)
    }

    // MARK: - Color

    private enum ColorFill: Hashable, CaseIterable {
        case solid, gradient
        var title: String { self == .solid ? "Solid" : "Gradient" }
    }

    private var colorFill: Binding<ColorFill> {
        Binding {
            if case .solid = fill { return .solid }
            return .gradient
        } set: { chosen in
            switch chosen {
            case .solid: setFill(.solid(BackgroundPalette.colors.first ?? RGBA(r: 1, g: 1, b: 1)))
            case .gradient: setFill(.gradient(.ocean))
            }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: SidebarTheme.betweenGroups) {
            SidebarSegmented(selection: colorFill, options: ColorFill.allCases, title: \.title)
                .accessibilityLabel("Solid colour or gradient")

            if colorFill.wrappedValue == .solid {
                LazyVGrid(columns: colorColumns, spacing: 2) {
                    ForEach(BackgroundPalette.colors, id: \.self) { color in
                        SidebarSwatch(isSelected: fill == .solid(color), title: "Colour") {
                            setFill(.solid(color))
                        } content: {
                            Color(nsColor: color.nsColor)
                        }
                    }
                }
                customColorRow
            } else {
                let all = GradientPreset.allCases
                let collapsed = swatchColumns.count * Self.collapsedRows
                VStack(alignment: .leading, spacing: 6) {
                    SidebarSubheading("Presets") {
                        if all.count > collapsed {
                            ShowAllButton(isExpanded: $showsAllGradients, count: all.count)
                        }
                    }
                    LazyVGrid(columns: swatchColumns, spacing: 4) {
                        ForEach(showsAllGradients ? Array(all) : visibleGradients(limit: collapsed), id: \.self) { preset in
                            SidebarSwatch(isSelected: fill == .gradient(preset), title: preset.rawValue.capitalized) {
                                setFill(.gradient(preset))
                            } content: {
                                LinearGradient(colors: preset.colors.map { Color(nsColor: $0.nsColor) },
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                    }
                }
                ScrubSlider(title: "Angle",
                            value: Binding(get: { model.background.gradientAngle },
                                           set: { model.background.gradientAngle = $0.rounded() }),
                            range: 0...360,
                            defaultValue: 45,
                            format: { "\(Int($0.rounded()))°" },
                            onEditingChanged: editing)
            }
        }
    }

    private func visibleGradients(limit: Int) -> [GradientPreset] {
        var shown = Array(GradientPreset.allCases.prefix(limit))
        if case .gradient(let chosen) = fill, !shown.contains(chosen), !shown.isEmpty {
            shown[shown.count - 1] = chosen
        }
        return shown
    }

    /// Any colour, through the system colour panel. The panel reports every movement, so
    /// changes are gathered into one undo step that ends a moment after the last one.
    private var customColorRow: some View {
        HStack(spacing: 8) {
            Text("CUSTOM")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(SidebarTheme.label)
            Spacer(minLength: 4)
            ColorPicker("Custom colour", selection: Binding(
                get: {
                    if case .solid(let color) = fill { return Color(nsColor: color.nsColor) }
                    return .white
                },
                set: { color in
                    model.beginInteraction()
                    setFill(.solid(RGBA(NSColor(color))))
                    colorEditEnd?.cancel()
                    colorEditEnd = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        model.endInteraction()
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 38, height: 20)
        }
        .padding(.leading, SidebarTheme.fieldInset)
        .padding(.trailing, 5)
        .frame(height: SidebarTheme.fieldHeight)
        .background(SidebarTheme.field, in: SidebarTheme.squircle(SidebarTheme.fieldRadius))
        .help("Pick any colour")
    }

    // MARK: - Image

    @ViewBuilder
    private var image: some View {
        VStack(alignment: .leading, spacing: SidebarTheme.betweenGroups) {
            if case .image(let wallpaper) = fill, wallpaper.isCustom {
                WallpaperPeek(wallpaper: wallpaper)
                HStack(spacing: 6) {
                    Button("Replace") { chooseImage() }
                    Button("Remove") { setFill(.gradient(.ocean)) }
                }
                .buttonStyle(SidebarButtonStyle())
            } else {
                Button {
                    chooseImage()
                } label: {
                    Label("Choose Image", systemImage: "photo.badge.plus")
                }
                .buttonStyle(SidebarButtonStyle())
                .help("Use a picture from your Mac as the background")
            }

            // Pictures added this session, to switch back without the open panel.
            let recents = catalog.customWallpapers
            if recents.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    SidebarSubheading("Recent")
                    LazyVGrid(columns: swatchColumns, spacing: 4) {
                        ForEach(recents.reversed(), id: \.self) { wallpaper in
                            SidebarSwatch(isSelected: fill == .image(wallpaper), title: wallpaper.title) {
                                select(wallpaper)
                            } content: {
                                thumbnail(wallpaper)
                            }
                        }
                        SidebarAddSwatch(title: "Add an image from your Mac") { chooseImage() }
                    }
                }
            }

            if case .image(let wallpaper) = fill, wallpaper.isCustom {
                blurSlider
            }
        }
    }

    private func chooseImage() {
        guard let wallpaper = catalog.chooseCustomWallpaper() else { return }
        kindOverride = nil
        select(wallpaper)
        Task { await catalog.prepareThumbnails() }
    }

    // MARK: - None

    private var transparent: some View {
        HStack(spacing: 10) {
            SidebarCheckerboard()
                .frame(width: 44, height: 28)
                .clipShape(SidebarTheme.squircle(6))
                .overlay { SidebarTheme.squircle(6).strokeBorder(SidebarTheme.strokeStrong, lineWidth: 0.5) }
            Text("The screenshot is exported as is, with no background.")
                .font(.system(size: 11))
                .foregroundStyle(SidebarTheme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: SidebarTheme.betweenControls) {
            SidebarHeader("Layout")
            ScrubSlider(title: "Padding",
                        value: Binding(get: { model.background.padding },
                                       set: { model.background.padding = $0.rounded() }),
                        range: 0...200,
                        defaultValue: 48,
                        onEditingChanged: editing)
                .disabled(model.background.autoBalance)
            SidebarSwitchRow(title: "Auto-balance",
                             isOn: Binding(get: { model.background.autoBalance },
                                           set: { model.background.autoBalance = $0 }),
                             help: "Padding proportional to the image size")
            ScrubSlider(title: "Inset",
                        value: Binding(get: { model.background.inset },
                                       set: { model.background.inset = $0.rounded() }),
                        range: 0...80,
                        defaultValue: 0,
                        onEditingChanged: editing)
            ScrubSlider(title: "Shadow",
                        value: Binding(get: { model.background.shadowStrength * 100 },
                                       set: { model.background.shadowStrength = $0.rounded() / 100 }),
                        range: 0...100,
                        defaultValue: 45,
                        format: { "\(Int($0.rounded()))%" },
                        onEditingChanged: editing)
            ScrubSlider(title: "Corners",
                        value: Binding(get: { model.background.cornerRadius },
                                       set: { model.background.cornerRadius = $0.rounded() }),
                        range: 0...48,
                        defaultValue: 12,
                        onEditingChanged: editing)

            SidebarMenu(selection: Binding(get: { model.background.ratio },
                                           set: { model.background.ratio = $0 }),
                        options: OutputRatio.allCases, title: \.title, label: "Ratio")
                .accessibilityLabel("Output ratio")
                .help("Grow the canvas to this shape")
            HStack(spacing: 8) {
                Text("ALIGN")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(SidebarTheme.label)
                Spacer(minLength: 4)
                alignmentGrid
            }
            .padding(.leading, SidebarTheme.fieldInset)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(SidebarTheme.field, in: SidebarTheme.squircle(SidebarTheme.fieldRadius))
            .opacity(model.background.ratio == .auto ? 0.45 : 1)
            .help(model.background.ratio == .auto
                  ? "Choose a ratio to place the card in the extra space"
                  : "Where the card sits in the extra space")
        }
    }

    /// 3 × 3 card positions; only matters once a ratio makes the canvas larger.
    private var alignmentGrid: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let alignment = CardAlignment.all[row][column]
                        let selected = model.background.alignment == alignment
                        Button { model.background.alignment = alignment } label: {
                            Circle()
                                .fill(selected ? EditorChrome.accent : SidebarTheme.label.opacity(0.45))
                                .frame(width: selected ? 7 : 4, height: selected ? 7 : 4)
                                .frame(width: 20, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Align \(["top", "middle", "bottom"][row]) \(["left", "centre", "right"][column])")
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private func editing(_ isEditing: Bool) {
        if isEditing { model.beginInteraction() } else { model.endInteraction() }
    }

    private func setFill(_ newFill: BackgroundFill) {
        kindOverride = nil
        var style = model.background
        style.fill = newFill
        model.background = style
    }

    /// Decodes the full-size picture off the main thread first, then swaps it in as one
    /// undo step. Blur carries over between wallpapers.
    private func select(_ wallpaper: Wallpaper) {
        Task {
            await catalog.prepare(wallpaper)
            kindOverride = nil
            var style = model.background
            style.fill = .image(wallpaper)
            model.background = style
        }
    }

    @ViewBuilder
    private func thumbnail(_ wallpaper: Wallpaper) -> some View {
        if let thumbnail = catalog.thumbnail(for: wallpaper) {
            Image(nsImage: thumbnail).resizable().scaledToFill()
        } else {
            Color.primary.opacity(0.08)
        }
    }
}

/// The chosen picture at the shape a background is seen at, with its name: a look at what
/// was picked without opening anything.
private struct WallpaperPeek: View {
    let wallpaper: Wallpaper
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SidebarTheme.squircle(SidebarTheme.fieldRadius)
                .fill(SidebarTheme.field)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let shown = image ?? WallpaperCatalog.shared.thumbnail(for: wallpaper) {
                        Image(nsImage: shown).resizable().scaledToFill()
                            .transition(.opacity)
                    }
                }
                .clipShape(SidebarTheme.squircle(SidebarTheme.fieldRadius))
                .overlay { SidebarTheme.squircle(SidebarTheme.fieldRadius).strokeBorder(SidebarTheme.strokeStrong, lineWidth: 0.5) }
            Text(wallpaper.title)
                .font(.system(size: 11))
                .foregroundStyle(SidebarTheme.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: wallpaper) {
            image = nil
            await WallpaperCatalog.shared.prepare(wallpaper)
            guard let full = WallpaperCatalog.shared.image(for: wallpaper) else { return }
            // Shrunk to the preview's size off the main thread, so the panel doesn't hold
            // its own copy of a 2400-pixel picture once the catalog lets go of it.
            let small = await Task.detached(priority: .userInitiated) { Self.downsample(full, width: 560) }.value
            guard !Task.isCancelled, let small else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                image = NSImage(cgImage: small, size: .zero)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Chosen: \(wallpaper.title)")
    }

    nonisolated private static func downsample(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
