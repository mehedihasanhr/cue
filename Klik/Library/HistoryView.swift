import SwiftUI
import UniformTypeIdentifiers

/// Actions the history panel can trigger; wired by the AppDelegate.
struct HistoryActions {
    var captureFullScreen: () -> Void
    var captureArea: () -> Void
    var captureScrolling: () -> Void
    var captureText: () -> Void
    var pickColor: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    var preview: (CaptureItem) -> Void
    var edit: (CaptureItem) -> Void
    var copy: (CaptureItem) -> Void
    var delete: (CaptureItem) -> Void
}

enum GalleryLayout: String, CaseIterable {
    case grid, smallGrid, list, smallList

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .smallGrid: "square.grid.3x3"
        case .list: "list.bullet"
        case .smallList: "list.dash"
        }
    }

    var title: String {
        switch self {
        case .grid: "Grid"
        case .smallGrid: "Small grid"
        case .list: "List"
        case .smallList: "Compact list"
        }
    }

    var isGrid: Bool { self == .grid || self == .smallGrid }
    var isCompact: Bool { self == .smallGrid || self == .smallList }
    var columns: Int { self == .smallGrid ? 4 : 2 }
}

/// The menu-bar dropdown: capture buttons on top, every capture below (grid or list)
/// with preview / edit / copy / delete on hover. Items can be dragged straight into
/// other apps.
struct HistoryView: View {
    static let size = CGSize(width: 480, height: 560)

    let library: CaptureLibrary
    let actions: HistoryActions
    /// Inside the Dynamic Island the black shape is the background and sets the size;
    /// the popover / floating panel draw their own.
    var chromeless = false
    @State private var search = ""
    @AppStorage("gallery.layout") private var layout: GalleryLayout = .grid

    private var filtered: [CaptureItem] {
        guard !search.isEmpty else { return library.items }
        return library.items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    if layout.isGrid {
                        let spacing: CGFloat = layout.isCompact ? 6 : 10
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: layout.columns), spacing: spacing) {
                            ForEach(filtered) { item in
                                GridCell(item: item, library: library, actions: actions, compact: layout.isCompact)
                            }
                        }
                        .padding(layout.isCompact ? 8 : 10)
                    } else {
                        LazyVStack(spacing: layout.isCompact ? 0 : 2) {
                            ForEach(filtered) { item in
                                ListRow(item: item, library: library, actions: actions, compact: layout.isCompact)
                            }
                        }
                        .padding(layout.isCompact ? 6 : 8)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(chromeless ? Color.clear : Color(nsColor: .windowBackgroundColor))
    }

    private static let controlHeight: CGFloat = 28

    private var header: some View {
        HStack(spacing: 6) {
            captureButton("Screen", symbol: "display", action: actions.captureFullScreen)
            captureButton("Area", symbol: "viewfinder", action: actions.captureArea)
            captureButton("Scroll", symbol: "rectangle.expand.vertical", action: actions.captureScrolling)
            captureButton("Text", symbol: "text.viewfinder", action: actions.captureText)
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 56)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.controlHeight)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Menu {
                ForEach(GalleryLayout.allCases, id: \.self) { value in
                    Button {
                        layout = value
                    } label: {
                        if layout == value {
                            Label(value.title, systemImage: "checkmark")
                        } else {
                            Text(value.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: layout.symbol).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 40, height: Self.controlHeight)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View: \(layout.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func captureButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: Self.controlHeight)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.9))
        .help(title == "Text" ? "Capture text (OCR) to the clipboard" : "Capture \(title.lowercased())")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.viewfinder").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(search.isEmpty ? "No captures yet" : "No matches")
                .font(.headline)
            if search.isEmpty {
                Text(chromeless ? "Use the buttons above, or press ⌥⇧3, ⌥⇧4 or ⌥⇧5." : "Press ⌥⇧3, ⌥⇧4 or ⌥⇧5, or use the buttons above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            Text("\(library.items.count) capture\(library.items.count == 1 ? "" : "s") · drag any capture into another app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings (⌘,)")
            Button(action: actions.quit) {
                Image(systemName: "power").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit Klik (⌘Q)")
            .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Cells

/// Fills its frame (cover-style) without ever pushing the layout wider: the image is
/// an overlay on a clear box, so its intrinsic size never leaks into the grid.
private struct Thumbnail: View {
    let item: CaptureItem
    let library: CaptureLibrary

    var body: some View {
        Color.clear
            .overlay {
                if let thumbnail = library.thumbnail(for: item) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .clipped()
    }
}

private struct ActionButtons: View {
    let item: CaptureItem
    let actions: HistoryActions
    var compact = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: compact ? 1 : 2) {
            button("eye", help: "Preview") { actions.preview(item) }
            button("pencil", help: "Edit") { actions.edit(item) }
            button(copied ? "checkmark" : "doc.on.doc", help: "Copy to clipboard", tint: copied ? .green : .white) {
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                actions.copy(item)
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation { copied = false }
                }
            }
            button("trash", help: "Delete", tint: .red) { actions.delete(item) }
        }
    }

    private func button(_ symbol: String, help: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 9 : 11, weight: .medium))
                .frame(width: compact ? 18 : 24, height: compact ? 18 : 22)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: compact ? 4 : 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
    }
}

private struct GridCell: View {
    let item: CaptureItem
    let library: CaptureLibrary
    let actions: HistoryActions
    var compact = false
    @State private var hovering = false

    private var radius: CGFloat { compact ? 6 : 10 }

    var body: some View {
        Thumbnail(item: item, library: library)
            .frame(height: compact ? 64 : 120)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if hovering {
                    overlay.transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(hovering ? 0.35 : 0.12)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture { actions.edit(item) }
            .captureContextMenu(item: item, actions: actions)
            .captureDrag(item: item, library: library)
    }

    /// Bottom gradient with the details and the actions; the compact grid has no room
    /// for text, so it shows the actions only.
    private var overlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.replacingOccurrences(of: "Screenshot ", with: ""))
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(item.dimensions) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
            HStack {
                if compact { Spacer(minLength: 0) }
                ActionButtons(item: item, actions: actions, compact: compact)
                Spacer(minLength: 0)
            }
        }
        .padding(compact ? 4 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -24)
        )
    }
}

private struct ListRow: View {
    let item: CaptureItem
    let library: CaptureLibrary
    let actions: HistoryActions
    var compact = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Thumbnail(item: item, library: library)
                .frame(width: compact ? 40 : 84, height: compact ? 26 : 56)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous).strokeBorder(.primary.opacity(0.12)))

            if compact {
                Text(item.title.replacingOccurrences(of: "Screenshot ", with: ""))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !hovering {
                    Text(item.dimensions)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(item.dimensions) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if hovering {
                ActionButtons(item: item, actions: actions, compact: compact).transition(.opacity)
            }
        }
        .padding(.horizontal, compact ? 6 : 6)
        .padding(.vertical, compact ? 3 : 6)
        .background(RoundedRectangle(cornerRadius: compact ? 6 : 9, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.edit(item) }
        .captureContextMenu(item: item, actions: actions)
        .captureDrag(item: item, library: library)
    }
}

private extension View {
    func captureContextMenu(item: CaptureItem, actions: HistoryActions) -> some View {
        contextMenu {
            Button("Preview") { actions.preview(item) }
            Button("Edit") { actions.edit(item) }
            Button("Copy to Clipboard") { actions.copy(item) }
            Divider()
            Button("Delete", role: .destructive) { actions.delete(item) }
        }
    }

    /// Drag the capture's file into Finder, Slack, WhatsApp, a browser upload field…
    func captureDrag(item: CaptureItem, library: CaptureLibrary) -> some View {
        onDrag {
            let provider: NSItemProvider
            if let url = library.fileURL(for: item) {
                provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
            } else if let image = library.image(for: item) {
                provider = NSItemProvider(object: image.nsImage) // file still being written
            } else {
                provider = NSItemProvider()
            }
            provider.suggestedName = item.fileName
            return provider
        } preview: {
            if let thumbnail = library.thumbnail(for: item) {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).frame(width: 160)
            }
        }
    }
}
