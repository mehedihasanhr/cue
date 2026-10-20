import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// The look the recording is wearing, as one row: "Look  [Studio ▾]".
///
/// It was a grid of six large thumbnails at the top of the Frame panel — the most valuable
/// space in the column, spent on something chosen once per video. Now it is a heading with
/// a pop-up button, and the pictures are in the popover that button opens: the built-in
/// looks, then the saved ones, then Save Look… and Import…. A project dressed in no look
/// in particular — restyled by hand, or wearing one that has since been retired — says
/// Custom.
///
/// Saving asks for a name in a row that appears here, not in a dialog, so the Frame
/// panel's own controls stay in view while it is typed.
struct LooksSection: View {
    let model: EditorModel

    @Environment(StudioSettings.self) private var settings
    @State private var draftName = ""
    @State private var problem: String?
    @State private var isChoosing = false
    @FocusState private var isTypingName: Bool

    private var library: LookLibrary { .shared }

    /// The look the project is wearing, if it is wearing one exactly.
    private var current: Look? {
        library.builtIn.first { model.isWearing($0) }
            ?? library.saved.first { model.isWearing($0.look) }?.look
    }

    var body: some View {
        Group {
            if let request = library.request {
                naming(request)
            }
        }
        .inspectorSection("Look", systemImage: "paintpalette") {
            chooser
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
    }

    // MARK: - The pop-up

    /// The button on the heading, and the list it opens.
    ///
    /// A popover rather than a menu: a look is a picture, and a menu cannot draw one; and a
    /// saved look has its own Rename and Delete, which want a context menu on a row.
    private var chooser: some View {
        Button {
            isChoosing.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(current?.name ?? "Custom")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTheme.Palette.textSecondary)
            }
        }
        // Drawn as the kit's pop-up on a heading — its words and a chevron — so it reads as
        // the same control as every `StudioMenuPicker` beside a heading.
        .buttonStyle(.studio(.ghost, size: .small))
        .padding(.trailing, -8)
        .fixedSize()
        .help("Dress this recording in a built-in or saved look, or save this one")
        .accessibilityLabel("Look")
        .accessibilityValue(current?.name ?? "Custom")
        .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
            LookList(model: model, current: current) { action in
                isChoosing = false
                switch action {
                case .apply(let look): model.applyLook(look)
                case .save: library.request = .save
                case .rename(let saved): library.request = .rename(saved)
                case .delete(let saved): delete(saved)
                case .importLooks: importLooks()
                }
            }
            .environment(settings)
        }
    }

    // MARK: - Naming

    private var trimmedName: String { draftName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func naming(_ request: LookLibrary.Request) -> some View {
        let isRename = if case .rename = request { true } else { false }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(isRename ? "New name" : "Name this look", text: $draftName)
                    .font(.system(size: StudioTheme.FontSize.label))
                    .focused($isTypingName)
                    .studioField(isFocused: isTypingName, isInvalid: problem != nil)
                    .onSubmit { commit(request) }
                    .onExitCommand { library.request = nil }
                    .accessibilityLabel("Look name")
                    .help(!isRename && model.backgroundIsAPicture
                          ? "The picture behind this recording stays with it. The look keeps everything else."
                          : "")
                Button(isRename ? "Rename" : "Save") { commit(request) }
                    .buttonStyle(.studio(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .help(trimmedName.isEmpty ? "Type a name first" : "")
                Button("Cancel") { library.request = nil }
                    .buttonStyle(.studio(.ghost, size: .small))
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

// MARK: - The list

/// What the look pop-up holds: the built-in looks, the saved ones, and the two ways to add
/// to them.
private struct LookList: View {
    enum Action {
        case apply(Look)
        case save
        case rename(SavedLook)
        case delete(SavedLook)
        case importLooks
    }

    let model: EditorModel
    let current: Look?
    let act: (Action) -> Void

    @Environment(StudioSettings.self) private var settings

    private var library: LookLibrary { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            listHeading("Built In")
            ForEach(library.builtIn, id: \.name) { look in
                LookRow(look: look, isCurrent: current == look) { act(.apply(look)) }
                    .contextMenu { builtInMenu(look) }
            }

            Divider().padding(.vertical, 6)

            listHeading("Saved")
            if library.saved.isEmpty {
                Text("None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                ForEach(library.saved) { saved in
                    LookRow(look: saved.look, isCurrent: current == saved.look) { act(.apply(saved.look)) }
                        .contextMenu { savedMenu(saved) }
                }
            }

            Divider().padding(.vertical, 6)

            actionRow("Save Look…", help: "Keep how this recording is dressed, to use again") { act(.save) }
            actionRow("Import…", help: "Bring in a .klikstyle file somebody sent you") { act(.importLooks) }
        }
        .padding(8)
        .frame(width: 260)
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

    private func listHeading(_ title: String) -> some View {
        InspectorSubheading(title)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
    }

    private func actionRow(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(LookRowButtonStyle())
        .help(help)
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
        Button("Rename…") { act(.rename(saved)) }
        Button("Delete", role: .destructive) { act(.delete(saved)) }
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
}

/// One look in the list: a small picture of the frame it makes, its name, and — where the
/// look changes the frame's shape — the shape, so choosing "Social Post" turning a wide
/// video portrait is not a surprise.
private struct LookRow: View {
    let look: Look
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LookPreview(look: look)
                    .frame(width: 46, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.primary.opacity(0.1))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(look.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let shape = look.shapeTitle {
                        Text(shape)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isCurrent ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(LookRowButtonStyle())
        .help(isCurrent ? "\(look.name) — what this recording is wearing" : "Dress this recording in \(look.name)")
        .accessibilityLabel(look.shapeTitle.map { "\(look.name), \($0)" } ?? look.name)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

/// A row in the look list that lights under the pointer, as a menu item does.
private struct LookRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LookRowBody(configuration: configuration)
    }

    private struct LookRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : isHovering ? 0.07 : 0))
                }
                .onHover { isHovering = $0 }
                .animation(StudioMotion.hover, value: isHovering)
        }
    }
}

private extension Look {
    /// The shape a look sets the frame to, when it sets one.
    var shapeTitle: String? {
        switch frame.aspect {
        case nil: nil
        case .custom: frame.customAspect.map { "Custom \($0.width):\($0.height)" } ?? "Custom shape"
        case .some(let preset): preset.displayName
        }
    }
}

/// The frame a look makes, in miniature: its shape fitted into the tile, its background,
/// and a stand-in for the recording inset by its padding, with its corners, its shadow
/// and its border.
///
/// Drawn rather than rendered: the real renderer would give a truer picture and cost a
/// Core Image pass per row per redraw, for a thumbnail whose job is to tell a handful of
/// looks apart at a glance.
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
