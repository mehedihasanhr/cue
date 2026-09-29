import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// The looks: the built-in ones, the saved ones, and a way to save this one.
///
/// At the top of the Frame panel, because a look sets most of what is under it. Each
/// tile is a small picture of the frame the look makes — its background, its shape, its
/// corners — and the one the project is wearing is ringed. Saving asks for a name in a
/// row that appears here, not in a dialog: the tiles it will join are already in view.
struct LooksSection: View {
    let model: EditorModel

    @Environment(StudioSettings.self) private var settings
    @State private var draftName = ""
    @State private var problem: String?
    @FocusState private var isTypingName: Bool

    private var library: LookLibrary { .shared }

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 120), spacing: 8, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
            if let request = library.request {
                naming(request)
            }
            grid
        }
        .inspectorSection("Looks", systemImage: "paintpalette") {
            HStack(spacing: 12) {
                SectionButton(title: "Import…") { importLooks() }
                    .help("Bring in a .klikstyle file somebody sent you")
                SectionButton(title: "Save Look…") { library.request = .save }
                    .help("Keep how this recording is dressed, to use again")
            }
        }
        .onChange(of: library.request, initial: true) { _, request in
            switch request {
            case .save: draftName = ""
            case .rename(let saved): draftName = saved.name
            case nil: break
            }
            problem = nil
            if request != nil { isTypingName = true }
        }
        // A look on a desktop picture draws the catalogue's thumbnail of it, and the
        // catalogue decodes those once, when asked — so it is asked only when some look
        // actually needs one.
        .task(id: needsDesktopPictures) {
            if needsDesktopPictures { await WallpaperCatalog.shared.prepareThumbnails() }
        }
    }

    private var needsDesktopPictures: Bool {
        (library.builtIn + library.saved.map(\.look)).contains { look in
            guard case .wallpaper(let raw) = look.frame.background else { return false }
            return WallpaperID(rawValue: raw)?.namespace == .system
        }
    }

    // MARK: - The tiles

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(library.builtIn, id: \.name) { look in
                LookTile(look: look, isCurrent: model.isWearing(look)) {
                    model.applyLook(look)
                }
                .contextMenu { builtInMenu(look) }
            }
            ForEach(library.saved) { saved in
                LookTile(look: saved.look, isCurrent: model.isWearing(saved.look)) {
                    model.applyLook(saved.look)
                }
                .contextMenu { savedMenu(saved) }
            }
        }
    }

    @ViewBuilder
    private func builtInMenu(_ look: Look) -> some View {
        newRecordingsItem(look)
        Divider()
        // Said rather than left out: a menu missing Rename and Delete looks like a bug,
        // and a disabled line that says why does not.
        Text("Built in — can't be renamed or deleted")
    }

    @ViewBuilder
    private func savedMenu(_ saved: SavedLook) -> some View {
        Button("Rename…") { library.request = .rename(saved) }
        Button("Delete", role: .destructive) { delete(saved) }
        Divider()
        newRecordingsItem(saved.look)
        Button("Show in Finder") { library.reveal(saved) }
    }

    /// One item that flips: choosing it on the look that is already the default takes
    /// the default away, which is the only way to say "none".
    private func newRecordingsItem(_ look: Look) -> some View {
        let isDefault = settings.isNewRecordingLook(look)
        return Button {
            if isDefault {
                settings.clearNewRecordingLook()
            } else {
                settings.useForNewRecordings(look)
            }
        } label: {
            if isDefault {
                Label("Use for New Recordings", systemImage: "checkmark")
            } else {
                Text("Use for New Recordings")
            }
        }
    }

    // MARK: - Naming

    private var trimmedName: String { draftName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func naming(_ request: LookLibrary.Request) -> some View {
        let isRename = if case .rename = request { true } else { false }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(isRename ? "New name" : "Name this look", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTypingName)
                    .onSubmit { commit(request) }
                    .onExitCommand { library.request = nil }
                    .accessibilityLabel("Look name")
                Button(isRename ? "Rename" : "Save") { commit(request) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .help(trimmedName.isEmpty ? "Type a name first" : "")
                Button("Cancel") { library.request = nil }
            }
            .controlSize(.small)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isRename, model.backgroundIsAPicture {
                Text("The picture behind this recording stays with it. The look keeps everything else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func commit(_ request: LookLibrary.Request) {
        guard !trimmedName.isEmpty else { return }
        do {
            switch request {
            case .save:
                try library.save(model.look(named: trimmedName))
            case .rename(let saved):
                let renamed = try library.rename(saved, to: trimmedName)
                settings.newRecordingLookWasRenamed(from: saved.name, to: renamed.name)
            }
            library.request = nil
        } catch {
            problem = error.localizedDescription
            isTypingName = true
        }
    }

    // MARK: - The folder

    private func delete(_ saved: SavedLook) {
        do {
            try library.delete(saved)
            if case .rename(let naming) = library.request, naming == saved { library.request = nil }
        } catch {
            model.report(error)
        }
    }

    private func importLooks() {
        do {
            try library.importLooks()
        } catch {
            model.report(error)
        }
    }
}

// MARK: - One tile

/// A look as a small picture of the frame it makes, with its name under it.
struct LookTile: View {
    let look: Look
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                LookPreview(look: look)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2 : 0)
                            .padding(-3)
                    }
                Text(look.name)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
            .animation(StudioMotion.selection, value: isCurrent)
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "\(look.name) — what this recording is wearing" : "Dress this recording in \(look.name)")
        .accessibilityLabel(look.name)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

/// The frame a look makes, in miniature: its shape fitted into the tile, its background,
/// and a stand-in for the recording inset by its padding, with its corners, its shadow
/// and its border.
///
/// Drawn rather than rendered: the real renderer would give a truer picture and cost a
/// Core Image pass per tile per redraw, for a thumbnail whose job is to tell six looks
/// apart at a glance.
struct LookPreview: View {
    let look: Look

    /// What the stand-in for the recording looks like: 16:10, as most screens are.
    private static let pictureRatio = 1.6

    var body: some View {
        GeometryReader { proxy in
            let frame = frameRect(in: proxy.size)
            let picture = pictureRect(in: frame)
            let radius = (look.frame.cornerRadius ?? FrameStyle().cornerRadius) * min(picture.width, picture.height)
            ZStack(alignment: .topLeading) {
                // Outside the frame's shape, the tile is the panel: what the look does
                // not cover is not part of the look.
                Color.primary.opacity(0.06)
                LookBackgroundView(background: look.frame.background)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.86)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        if let width = look.frame.borderWidth, width > 0 {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder((look.frame.borderColor ?? .white).color,
                                              lineWidth: max(1, width * min(picture.width, picture.height)))
                        }
                    }
                    .shadow(color: .black.opacity((look.frame.shadowOpacity ?? FrameStyle().shadowOpacity) * 0.8),
                            radius: (look.frame.shadowRadius ?? FrameStyle().shadowRadius) * 40,
                            y: 1)
                    .frame(width: picture.width, height: picture.height)
                    .offset(x: picture.minX, y: picture.minY)
            }
        }
    }

    /// The finished frame's shape, fitted into the tile.
    private func frameRect(in size: CGSize) -> CGRect {
        let ratio: Double = switch look.frame.aspect {
        case .custom: look.frame.customAspect?.ratio ?? CustomAspect().ratio
        case .some(let preset): preset.ratio ?? Self.pictureRatio
        case nil: Self.pictureRatio
        }
        var width = size.width
        var height = width / ratio
        if height > size.height {
            height = size.height
            width = height * ratio
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// The recording inside the frame, inset by the padding and fitted, as the builder
    /// fits it.
    private func pictureRect(in frame: CGRect) -> CGRect {
        let inset = min(frame.width, frame.height) * (look.frame.padding ?? FrameStyle().padding)
        let available = frame.insetBy(dx: inset, dy: inset)
        var width = available.width
        var height = width / Self.pictureRatio
        if height > available.height {
            height = available.height
            width = height * Self.pictureRatio
        }
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }
}

/// A stored background, drawn without the renderer.
///
/// A wallpaper is looked up the way the resolver looks it up; a picture of the user's
/// own never reaches here, because a look does not carry one. `nil` — a look that says
/// nothing about the background — is drawn as nothing in particular.
struct LookBackgroundView: View {
    let background: FrameStyle.Background?

    var body: some View {
        switch background {
        case .color(let colour):
            colour.color
        case .gradient(let from, let to, let angle):
            LinearGradient(colors: [from.color, to.color],
                           startPoint: Self.start(of: angle), endPoint: Self.end(of: angle))
        case .wallpaper(let raw):
            wallpaper(raw)
        case .customGradient(let gradient):
            GradientSwatch(gradient: gradient)
        case .animated(let animation):
            LinearGradient(colors: animation.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
        case .transparent:
            Checkerboard(square: 4)
        case .image, .video, nil:
            Color.secondary.opacity(0.25)
        }
    }

    @ViewBuilder
    private func wallpaper(_ raw: String) -> some View {
        if let id = WallpaperID(rawValue: raw), let source = WallpaperResolver.shared.source(for: id) {
            switch source {
            case .procedural(let preset):
                LinearGradient(colors: preset.colors.map { Color(nsColor: $0.nsColor) },
                               startPoint: Self.start(of: 0.25), endPoint: Self.end(of: 0.25))
            case .file(let url):
                if let wallpaper = WallpaperCatalog.shared.systemWallpapers.first(where: { $0.name == id.name }),
                   let thumbnail = WallpaperCatalog.shared.thumbnail(for: wallpaper) {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ImageThumbnail(url: url)
                }
            }
        } else {
            Color.secondary.opacity(0.25)
        }
    }

    /// The renderer sweeps its gradient from `centre - (cos, sin)` to `centre + (cos,
    /// sin)` in a space where y runs up; SwiftUI's runs down, so the sine is flipped.
    private static func start(of angle: Double) -> UnitPoint {
        let radians = angle * 2 * .pi
        return UnitPoint(x: 0.5 - cos(radians) / 2, y: 0.5 + sin(radians) / 2)
    }

    private static func end(of angle: Double) -> UnitPoint {
        let radians = angle * 2 * .pi
        return UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 - sin(radians) / 2)
    }
}
