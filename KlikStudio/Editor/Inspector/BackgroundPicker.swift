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
            // Six kinds, every title whole and in one size of type: on as many rows as the
            // column needs — two, at the panel's usual width. See `InspectorTabs`.
            InspectorTabs(selection: tab, items: BackgroundTab.allCases) { $0.title }
                .accessibilityLabel("Kind of background")

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

    /// The stock gradients and the project's own, as one row of swatches, then what makes
    /// the project's own.
    ///
    /// The own one is the last swatch rather than a second swatch beside a sentence: there
    /// was a row of stock gradients and then, under it, another swatch with "Change
    /// anything below to make your own" — two pictures of the same choice. Pressing it
    /// makes the gradient the controls under it describe the background, which changes
    /// nothing you can see until one of them is moved.
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
                SwatchTile(isSelected: model.hasCustomGradient,
                           title: "Your own gradient",
                           tooltip: model.hasCustomGradient
                               ? "Your own gradient"
                               : "Your own gradient. Change anything below to make your own.") {
                    model.setBackgroundGradient(model.editableGradient)
                } content: {
                    GradientSwatch(gradient: model.editableGradient)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 1)
                                .padding(3)
                        }
                }
            }
            // Under the stock ones rather than instead of them: most people want one of
            // those, and the editor starts from whichever is chosen.
            GradientEditor(model: model)
        }
    }

    // MARK: - None

    /// What a see-through background means, since the answer depends on the export. The
    /// one line says which formats keep it; the tooltip says what the rest do.
    private var transparent: some View {
        HStack(spacing: 10) {
            Checkerboard(square: 5)
                .frame(width: 44, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
            InspectorNote("Stays see-through in ProRes 4444 and HEVC with transparency.")
        }
        .help("Nothing is drawn around the picture. ProRes 4444, and HEVC with transparency in a MOV, keep it see-through; other formats fill it with black.")
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

            InspectorRow("Custom") {
                InspectorColorWell(title: "Custom colour", selection: custom)
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
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                ImageThumbnail(url: model.packageURL.appendingPathComponent(path))
                    .help("Images fill the frame, so a tall picture behind a wide recording is cropped rather than letterboxed.")
                HStack(spacing: 8) {
                    Button("Replace…") { choose() }
                    Button("Remove") {
                        style.set(\.style.background, to: BackgroundPreset.indigo.background, "Background")
                    }
                }
                .buttonStyle(.studio(.secondary, size: .small))
            }
        } else {
            Button("Choose Image…") { choose() }
                .buttonStyle(.studio(.secondary, size: .small))
                .help("The picture is copied into the recording, so the project still looks right on another Mac.")
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
