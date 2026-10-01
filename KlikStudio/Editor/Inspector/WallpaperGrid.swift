import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// The grid of backgrounds to choose from.
///
/// Three groups from three places, one picker: the gradients this app generates, the
/// desktop pictures macOS ships, and whatever the user has picked before. They share one
/// namespace, so what the document stores is the same kind of thing whichever row it
/// came from.
struct WallpaperGrid: View {
    let model: EditorModel
    let state: InspectorState

    @State private var catalog = WallpaperCatalog.shared
    @State private var recents: [(bookmark: Data, url: URL)] = []

    private let columns = Array(repeating: GridItem(.flexible(minimum: 24), spacing: 6), count: 7)
    /// Two rows, then a "Show all". Twenty swatches is a wall; fourteen is a choice.
    private let collapsedCount = 14

    private var style: StyleBinding { StyleBinding(model: model) }

    private var selectedID: WallpaperID? {
        guard case .wallpaper(let raw) = model.timeline.style.background else { return nil }
        return WallpaperID(rawValue: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenGroups) {
            gradients
            systemPictures
            yours
        }
        .task {
            recents = WallpaperBookmarks.shared.resolvedRecents()
            await catalog.prepareThumbnails()
        }
    }

    // MARK: - Groups

    private var gradients: some View {
        let all = GradientPreset.allCases
        let shown = state.showsAllGradients ? all : Array(all.prefix(collapsedCount))

        return VStack(alignment: .leading, spacing: 8) {
            header("Wallpaper") {
                if all.count > collapsedCount {
                    SectionButton(title: state.showsAllGradients ? "Show less" : "Show all") {
                        withAnimation(StudioMotion.state) { state.showsAllGradients.toggle() }
                    }
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(shown) { preset in
                    let id = WallpaperID.preset(preset)
                    SwatchTile(isSelected: selectedID == id, title: preset.title) {
                        choose(id)
                    } content: {
                        // Drawn rather than decoded: a generated gradient needs no
                        // thumbnail, which is why the grid is instant on first open.
                        LinearGradient(colors: preset.colors.map { Color(nsColor: $0.nsColor) },
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var systemPictures: some View {
        let pictures = catalog.systemWallpapers
        if !pictures.isEmpty {
            // A Mac ships dozens of desktop pictures, and all of them at once is a wall
            // of thumbnails you scroll past to reach the controls underneath. Two rows,
            // then ask.
            let shown = state.showsAllSystemWallpapers ? pictures : Array(pictures.prefix(collapsedCount))

            VStack(alignment: .leading, spacing: 8) {
                header("From macOS", help: "Desktop pictures installed on this Mac") {
                    if pictures.count > collapsedCount {
                        SectionButton(title: state.showsAllSystemWallpapers
                                      ? "Show less"
                                      : "Show all (\(pictures.count))") {
                            withAnimation(StudioMotion.state) {
                                state.showsAllSystemWallpapers.toggle()
                            }
                        }
                    }
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(shown, id: \.self) { wallpaper in
                        let id = WallpaperID.system(wallpaper)
                        SwatchTile(isSelected: selectedID == id, title: wallpaper.title) {
                            choose(id)
                        } content: {
                            thumbnail(for: wallpaper)
                        }
                    }
                }
            }
        }
    }

    private var yours: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Yours") { EmptyView() }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(recents, id: \.bookmark) { recent in
                    SwatchTile(isSelected: false, title: recent.url.lastPathComponent) {
                        importing(recent.url)
                    } content: {
                        ImageThumbnail(url: recent.url)
                    }
                }

                Button {
                    guard let url = BackgroundImport.choose() else { return }
                    importing(url)
                } label: {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
                .help("Choose a picture of your own")
            }
        }
    }

    private func header(_ title: String, help: String = "",
                        @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            InspectorSubheading(title)
                .help(help)
            Spacer()
            trailing()
        }
    }

    // MARK: - Choosing

    private func thumbnail(for wallpaper: Wallpaper) -> some View {
        Group {
            if let image = catalog.thumbnail(for: wallpaper) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.15)
            }
        }
    }

    private func choose(_ id: WallpaperID) {
        style.set(\.style.background, to: .wallpaper(id: id.rawValue), "Background")
    }

    /// A picture of the user's own is copied into the project rather than pointed at, so
    /// the recording still opens the same way on a machine that has never seen the file.
    private func importing(_ url: URL) {
        do {
            let path = try BackgroundImport.copy(url, into: model.packageURL)
            WallpaperBookmarks.shared.remember(url)
            recents = WallpaperBookmarks.shared.resolvedRecents()
            style.set(\.style.background, to: .image(path: path), "Background")
        } catch {
            model.report(error)
        }
    }
}
