import SwiftUI

/// Left sidebar for the Background tool: gradients, wallpapers, blurred wallpapers and
/// plain colours as a scrollable gallery (CleanShot-style), with the geometry controls
/// pinned at the bottom.
struct BackgroundSidebar: View {
    @Bindable var model: EditorViewModel
    @State private var showAllGradients = false

    static let width: CGFloat = 250
    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 8), count: 5)
    private let colorColumns = Array(repeating: GridItem(.fixed(22), spacing: 10), count: 7)

    private var fill: BackgroundFill { model.background.fill }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        model.removeBackground()
                    } label: {
                        Text("None")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    gradients
                    wallpapers
                    blurred
                    colors
                    Divider()
                    controls
                }
                .padding(14)
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await WallpaperStore.shared.prepareThumbnails() }
    }

    // MARK: Sections

    private var gradients: some View {
        section("Gradients", trailing: {
            Button(showAllGradients ? "Show less" : "Show all") { withAnimation(.easeOut(duration: 0.15)) { showAllGradients.toggle() } }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
        }) {
            let presets = showAllGradients ? GradientPreset.allCases : Array(GradientPreset.allCases.prefix(10))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    tile(selected: fill == .gradient(preset), help: preset.rawValue.capitalized) {
                        LinearGradient(colors: preset.colors.map { Color(nsColor: $0.nsColor) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    } action: {
                        model.background.fill = .gradient(preset)
                    }
                }
            }
        }
    }

    private var wallpapers: some View {
        section("Wallpapers") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(WallpaperStore.shared.customWallpapers + WallpaperStore.shared.systemWallpapers, id: \.self) { wallpaper in
                    tile(selected: fill == .image(wallpaper) && model.background.imageBlur < 1, help: wallpaper.title) {
                        wallpaperImage(wallpaper)
                    } action: {
                        select(wallpaper, blur: 0)
                    }
                }
                Button {
                    if let wallpaper = WallpaperStore.shared.chooseCustomWallpaper() {
                        select(wallpaper, blur: 0)
                        Task { await WallpaperStore.shared.prepareThumbnails() }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help("Add an image from your Mac")
            }
        }
    }

    /// The first few wallpapers pre-softened, for a subtle backdrop in one click.
    private var blurred: some View {
        section("Blurred") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(WallpaperStore.shared.systemWallpapers.prefix(5), id: \.self) { wallpaper in
                    tile(selected: fill == .image(wallpaper) && model.background.imageBlur >= 1, help: "\(wallpaper.title), blurred") {
                        wallpaperImage(wallpaper).blur(radius: 4)
                    } action: {
                        select(wallpaper, blur: 20)
                    }
                }
            }
        }
    }

    private var colors: some View {
        section("Plain color") {
            LazyVGrid(columns: colorColumns, alignment: .leading, spacing: 10) {
                ForEach(BackgroundPalette.colors, id: \.self) { color in
                    let selected = fill == .solid(color)
                    Button { model.background.fill = .solid(color) } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(
                    get: {
                        if case .solid(let color) = fill { return Color(nsColor: color.nsColor) }
                        return .white
                    },
                    set: { model.background.fill = .solid(RGBA(NSColor($0))) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 22, height: 22)
                .help("Custom colour")
            }
        }
    }

    private func select(_ wallpaper: Wallpaper, blur: CGFloat) {
        Task {
            await WallpaperStore.shared.prepare(wallpaper)
            var style = model.background
            style.imageBlur = blur
            style.fill = .image(wallpaper)
            model.background = style
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            row("Padding", value: Binding(get: { model.background.padding }, set: { model.background.padding = $0.rounded() }), range: 0...200)
                .disabled(model.background.autoBalance)
                .opacity(model.background.autoBalance ? 0.5 : 1)
            HStack {
                Text("Auto-balance").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { model.background.autoBalance }, set: { model.background.autoBalance = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Padding proportional to the image size")
            }
            row("Inset", value: Binding(get: { model.background.inset }, set: { model.background.inset = $0.rounded() }), range: 0...80)
            row("Shadow", value: Binding(get: { model.background.shadowStrength * 100 }, set: { model.background.shadowStrength = ($0 / 100 * 100).rounded() / 100 }), range: 0...100)
            row("Corners", value: Binding(get: { model.background.cornerRadius }, set: { model.background.cornerRadius = $0.rounded() }), range: 0...48)
            switch fill {
            case .gradient:
                row("Angle", value: Binding(get: { model.background.gradientAngle }, set: { model.background.gradientAngle = $0.rounded() }), range: 0...360)
            case .image:
                row("Blur", value: Binding(get: { model.background.imageBlur }, set: { model.background.imageBlur = $0.rounded() }), range: 0...30)
            case .solid:
                EmptyView()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alignment").font(.system(size: 11)).foregroundStyle(.secondary)
                    alignmentGrid
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ratio").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { model.background.ratio }, set: { model.background.ratio = $0 })) {
                        ForEach(OutputRatio.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 90)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }

    /// 3 × 3 grid of card positions; only matters once a ratio makes the canvas larger.
    private var alignmentGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { rowIndex in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { column in
                        let alignment = CardAlignment.all[rowIndex][column]
                        let selected = model.background.alignment == alignment
                        Button { model.background.alignment = alignment } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.primary.opacity(selected ? 0.9 : 0.25))
                                .frame(width: 8, height: 6)
                                .frame(width: 22, height: 18, alignment: Alignment(horizontal: [.leading, .center, .trailing][column], vertical: [.top, .center, .bottom][rowIndex]))
                                .padding(2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(selected ? 0.12 : 0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : .primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func row(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small).frame(maxWidth: .infinity)
            Text("\(Int(value.wrappedValue))").font(.system(size: 11)).monospacedDigit().frame(width: 26, alignment: .trailing)
        }
    }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func tile(selected: Bool, help: String, @ViewBuilder content: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func wallpaperImage(_ wallpaper: Wallpaper) -> some View {
        Group {
            if let thumbnail = WallpaperStore.shared.thumbnail(for: wallpaper) {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Color.gray
            }
        }
    }
}
