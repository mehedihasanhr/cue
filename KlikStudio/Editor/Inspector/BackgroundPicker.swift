import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// Which of the six kinds of background this is.
enum BackgroundTab: String, CaseIterable, Identifiable, Hashable {
    case wallpaper, gradient, color, image
    /// A background that moves: drawn, or a movie. See `MotionBackgroundPicker`.
    case motion
    /// Nothing behind the picture: see-through. Titled "None", which is what it is to
    /// look at; not *named* `none`, which an optional tab would read as nil.
    case transparent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallpaper: "Wallpaper"
        case .gradient: "Gradient"
        case .color: "Color"
        case .image: "Image"
        case .motion: "Motion"
        case .transparent: "None"
        }
    }

    init(_ background: FrameStyle.Background) {
        switch background {
        case .wallpaper: self = .wallpaper
        case .gradient, .customGradient: self = .gradient
        case .color: self = .color
        case .image: self = .image
        case .animated, .video: self = .motion
        case .transparent: self = .transparent
        }
    }
}

/// What the recording sits on.
struct BackgroundPicker: View {
    let model: EditorModel
    let state: InspectorState

    @State private var coalescer = InteractionCoalescer()

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
            InspectorTabs(selection: tab, items: BackgroundTab.allCases) { $0.title }

            switch tab.wrappedValue {
            case .wallpaper: WallpaperGrid(model: model, state: state)
            case .gradient: gradients
            case .color: colors
            case .image: image
            case .motion: MotionBackgroundPicker(model: model)
            case .transparent: transparent
            }

            // Here rather than in a section of its own: the blur is a property of the
            // background, not a second subject, and a heading over one slider was a
            // heading doing no work.
            // Not for nothing: there is no background to soften.
            if tab.wrappedValue != .transparent {
                InspectorSlider(model: model, "Background blur",
                                value: style.binding(\.style.backgroundBlur, "Background Blur"),
                                range: 0...0.04)
            }
        }
        .inspectorSection("Background", systemImage: "photo")
    }

    /// Derived from the document so that undoing a background change moves the tab back
    /// with it, rather than leaving the panel describing something that is no longer so.
    private var tab: Binding<BackgroundTab> {
        Binding {
            state.backgroundTabOverride ?? BackgroundTab(model.timeline.style.background)
        } set: { chosen in
            state.backgroundTabOverride = nil
            switch chosen {
            case .wallpaper:
                style.set(\.style.background, to: .wallpaper(id: WallpaperID.preset(.ocean).rawValue), "Background")
            case .gradient:
                style.set(\.style.background, to: BackgroundPreset.indigo.background, "Background")
            case .color:
                style.set(\.style.background, to: .color(ColorValue(r: 0.08, g: 0.09, b: 0.12)), "Background")
            case .image:
                // Nothing to switch to until a picture is chosen, so the tab is held
                // open by hand until one is.
                if case .image = model.timeline.style.background {} else {
                    state.backgroundTabOverride = .image
                }
            case .motion:
                // Keeps a moving background that is already there, movie included.
                switch model.timeline.style.background {
                case .animated, .video: break
                default: model.setAnimatedBackground(AnimatedBackground())
                }
            case .transparent:
                model.makeBackgroundTransparent()
            }
        }
    }

    // MARK: - Gradient

    /// Sized rather than stretched: five tiles sharing the column's width made each one
    /// a 44-point slab, which is a lot of panel to say "indigo". They are swatches — big
    /// enough to read the colour off, and no bigger — and they wrap if more are added.
    private var gradients: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 8)],
                      alignment: .leading,
                      spacing: 8) {
                ForEach(BackgroundPreset.allCases) { preset in
                    SwatchTile(isSelected: model.timeline.style.background == preset.background,
                               title: preset.title) {
                        style.set(\.style.background, to: preset.background, "Background")
                    } content: {
                        preview(of: preset.background)
                    }
                }
            }
            // Under the stock ones rather than instead of them: most people want one of
            // those, and the editor starts from whichever is chosen.
            GradientEditor(model: model)
        }
    }

    // MARK: - None

    /// What a see-through background means, since the answer depends on the export.
    private var transparent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Checkerboard(square: 5)
                    .frame(width: 44, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08))
                    }
                Text("Transparent")
                    .font(.system(size: 12))
            }
            Text("Nothing is drawn around the picture. ProRes 4444, and HEVC with transparency in a MOV, keep it see-through; other formats fill it with black.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func preview(of background: FrameStyle.Background) -> some View {
        switch background {
        case .gradient(let from, let to, _):
            LinearGradient(colors: [from.color, to.color], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .color(let colour):
            colour.color
        case .customGradient(let gradient):
            GradientSwatch(gradient: gradient)
        case .transparent:
            Checkerboard(square: 4)
        default:
            Color.secondary
        }
    }

    // MARK: - Colour

    private var colors: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 22), spacing: 6), count: 9), spacing: 6) {
                ForEach(Array(BackgroundPalette.colors.enumerated()), id: \.offset) { _, colour in
                    SwatchTile(isSelected: model.timeline.style.background == .color(colour.colorValue),
                               title: "Colour") {
                        style.set(\.style.background, to: .color(colour.colorValue), "Background")
                    } content: {
                        Color(nsColor: colour.nsColor)
                    }
                }
            }

            InspectorField(title: "Custom") {
                ColorPicker("Custom", selection: custom, supportsOpacity: false)
                    .fixedSize()
            }
        }
    }

    /// The one control with no "editing ended" of its own, so the coalescer stands in
    /// for it. The swatches above exist so the common case never opens the panel.
    private var custom: Binding<Color> {
        Binding {
            if case .color(let colour) = model.timeline.style.background { return colour.color }
            return .black
        } set: { colour in
            let value = RGBA(NSColor(colour)).colorValue
            coalescer.touch("Background", model: model)
            model.apply(Commands.Restyle("Background") { $0.style.background = .color(value) })
        }
    }

    // MARK: - Image

    @ViewBuilder
    private var image: some View {
        if case .image(let path) = model.timeline.style.background {
            VStack(alignment: .leading, spacing: 8) {
                ImageThumbnail(url: model.packageURL.appendingPathComponent(path))
                HStack {
                    Button("Replace…") { choose() }
                    Button("Remove") {
                        style.set(\.style.background, to: BackgroundPreset.indigo.background, "Background")
                    }
                }
                .controlSize(.small)
                Text("Images fill the frame, so a tall picture behind a wide recording is cropped rather than letterboxed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button("Choose Image…") { choose() }
                    .controlSize(.small)
                Text("The picture is copied into the recording, so the project still looks right on another Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choose() {
        guard let url = BackgroundImport.choose() else { return }
        do {
            let path = try BackgroundImport.copy(url, into: model.packageURL)
            WallpaperBookmarks.shared.remember(url)
            state.backgroundTabOverride = nil
            style.set(\.style.background, to: .image(path: path), "Background")
        } catch {
            model.report(error)
        }
    }
}

/// A picture already inside the project, shown at the shape it will be seen at.
struct ImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .task(id: url) {
                image = await Task.detached(priority: .userInitiated) {
                    NSImage(contentsOf: url)
                }.value
            }
    }
}

extension ColorValue {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
