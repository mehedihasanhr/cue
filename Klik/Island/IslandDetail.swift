import AppKit
import SwiftUI

/// A card opened inside the island: it takes the place of the card row.
enum IslandDetail: Hashable {
    case capture(CaptureItem)
    case clipboard(ClipboardItem)
    case asset(AssetItem)
    case color(ColorEntry)
}

/// The header pills and actions for an open card (shown in the tab row's place).
struct IslandDetailHeader: View {
    let detail: IslandDetail
    let library: CaptureLibrary
    let assets: AssetStore
    let actions: HistoryActions
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Back").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.white, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                HStack(spacing: 5) {
                    Image(systemName: pill.symbol).font(.system(size: 11, weight: .medium))
                    Text(pill.text).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 0)
            if case .capture(let item) = detail {
                small("Edit", symbol: "pencil") { actions.edit(item) }
            }
            if case .asset(let item) = detail {
                small("Open", symbol: "arrow.up.forward.app") { assets.open(item) }
            }
        }
    }

    private struct Pill { let symbol: String; let text: String }

    private var pills: [Pill] {
        switch detail {
        case .capture(let item):
            return [Pill(symbol: "photo", text: "Screenshot"), Pill(symbol: "aspectratio", text: item.dimensions), Pill(symbol: "info.circle", text: Self.fileSize(library.fileURL(for: item)))]
        case .asset(let item):
            var pills = [Pill(symbol: item.kind == .image ? "photo" : "doc", text: item.kind == .image ? "Image" : (item.fileName as NSString).pathExtension.uppercased())]
            if item.kind == .image { pills.append(Pill(symbol: "aspectratio", text: item.dimensions)) }
            pills.append(Pill(symbol: "info.circle", text: item.sizeText))
            return pills
        case .color(let entry):
            return [Pill(symbol: "paintpalette", text: "Color"), Pill(symbol: "number", text: ColorFormat.hex.string(for: entry.color))]
        case .clipboard(let item):
            var pills: [Pill]
            switch item.kind {
            case .text: pills = [Pill(symbol: "text.alignleft", text: "Text"), Pill(symbol: "character", text: "\(item.text.count) characters")]
            case .link: pills = [Pill(symbol: "link", text: "Link")]
            case .color: pills = [Pill(symbol: "paintpalette", text: "Color"), Pill(symbol: "number", text: item.text)]
            case .image: pills = [Pill(symbol: "photo", text: "Image"), Pill(symbol: "aspectratio", text: item.dimensions)]
            case .files: pills = [Pill(symbol: "doc.on.doc", text: item.filePaths.count == 1 ? "File" : "\(item.filePaths.count) files")]
            }
            if let name = item.sourceName { pills.append(Pill(symbol: "app", text: name)) }
            return pills
        }
    }

    private func small(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    static func fileSize(_ url: URL?) -> String {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// The body of an open card, in the card row's space: colors as a swatch with every
/// format beside it (click a row to copy it), images large, text in full.
struct IslandDetailBody: View {
    let detail: IslandDetail
    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let actions: HistoryActions
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        Group {
            switch detail {
            case .color(let entry):
                colorView(entry.color)
            case .capture(let item):
                let url = library.fileURL(for: item)
                imageRow(placeholder: library.thumbnail(for: item), key: item.id, title: item.title, subtitle: "\(item.dimensions) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    guard let url else { return nil }
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    return ImageEncoding.thumbnail(at: url, maxPixels: 1200)
                } buttons: {
                    detailButton("Copy", symbol: "doc.on.doc") { actions.copy(item) }
                    detailButton("Edit", symbol: "pencil") { actions.edit(item) }
                    detailButton("Preview", symbol: "eye") { actions.preview(item) }
                }
            case .asset(let item):
                let url = assets.fileURL(for: item)
                imageRow(placeholder: assets.thumbnail(for: item), key: item.id, title: item.fileName, subtitle: "\(item.sizeText) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    item.kind == .image ? ImageEncoding.thumbnail(at: url, maxPixels: 1200) : nil
                } buttons: {
                    detailButton("Copy", symbol: "doc.on.doc") {
                        assets.copy(item)
                        FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.fileName, image: assets.thumbnail(for: item))
                    }
                    detailButton("Open", symbol: "arrow.up.forward.app") { assets.open(item) }
                    detailButton("Reveal", symbol: "folder") { assets.reveal(item) }
                }
            case .clipboard(let item):
                clipboardView(clipboard.items.first { $0.id == item.id } ?? item) // live copy, so Pin reflects its state
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Color

    /// Swatch on the left; every format on the right in two columns, each a
    /// click-to-copy row. The row copied last is the default for the copy buttons.
    private func colorView(_ color: PickedColor) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(color.swiftUIColor)
                .frame(width: 150)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
                .overlay(alignment: .bottomLeading) {
                    if !color.isInSRGBGamut {
                        Text("P3").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(color.isDark ? .white : .black)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((color.isDark ? Color.white : Color.black).opacity(0.2), in: Capsule())
                            .padding(8)
                    }
                }
            let formats = ColorFormat.allCases
            let half = (formats.count + 1) / 2
            HStack(alignment: .top, spacing: 12) {
                ForEach([Array(formats[..<half]), Array(formats[half...])], id: \.first) { column in
                    VStack(spacing: 0) {
                        ForEach(column, id: \.self) { format in
                            FormatRow(format: format, value: format.string(for: color), isCurrent: format == preferences.colorFormat) {
                                copy(format.string(for: color), as: format)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private struct FormatRow: View {
        let format: ColorFormat
        let value: String
        let isCurrent: Bool
        let copy: () -> Void
        @State private var hovering = false
        @State private var copied = false

        var body: some View {
            // The values name their own format (rgb(…), oklch(…), Color(…)); only
            // the hex needs no label at all.
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(value)
                Spacer(minLength: 0)
                if copied {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                } else if isCurrent {
                    Circle().fill(.white.opacity(0.5)).frame(width: 5, height: 5)
                } else if hovering {
                    Image(systemName: "doc.on.doc").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(hovering ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                copy()
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation { copied = false }
                }
            }
        }
    }

    private func copy(_ string: String, as format: ColorFormat) {
        preferences.colorFormat = format
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setData(Data(), forType: Clipboard.ownMarker)
        FeedbackHUD.show("\(string) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
    }

    // MARK: - Images

    private func imageRow(placeholder: NSImage?, key: UUID, title: String, subtitle: String,
                          load: @escaping @Sendable () -> NSImage?, @ViewBuilder buttons: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) {
            DetailImage(key: key, placeholder: placeholder, load: load)
                .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                HStack(spacing: 8) { buttons() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func detailButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The card's thumbnail at once, a sharp version decoded off the main thread after.
    private struct DetailImage: View {
        let key: UUID
        let placeholder: NSImage?
        let load: @Sendable () -> NSImage?
        @State private var image: NSImage?

        var body: some View {
            Group {
                if let image = image ?? placeholder {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .task(id: key) {
                let load = load
                image = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let image = load()
                        Task { @MainActor in continuation.resume(returning: image) }
                    }
                }
            }
        }
    }

    // MARK: - Clipboard

    @ViewBuilder
    private func clipboardView(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .color:
            if let color = PickedColor(hex: item.text) { colorView(color) }
        case .image:
            let data = clipboard.imageData(for: item)
            imageRow(placeholder: clipboard.thumbnail(for: item), key: item.id, title: "Image", subtitle: "\(item.dimensions) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return ImageEncoding.thumbnail(from: source, maxPixels: 1200)
            } buttons: {
                detailButton("Copy", symbol: "doc.on.doc") {
                    clipboard.copy(item)
                    FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.contentTitle, image: clipboard.thumbnail(for: item))
                }
                detailButton(item.pinned ? "Unpin" : "Pin", symbol: item.pinned ? "pin.slash.fill" : "pin") { clipboard.togglePin(item) }
            }
        case .files:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(item.filePaths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                        Text(path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .text, .link:
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    Text(item.text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    detailButton("Copy", symbol: "doc.on.doc") {
                        clipboard.copy(item)
                        FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.contentTitle)
                    }
                    if item.kind == .link, let url = URL(string: item.text) {
                        detailButton("Open", symbol: "safari") { NSWorkspace.shared.open(url) }
                    }
                    detailButton(item.pinned ? "Unpin" : "Pin", symbol: item.pinned ? "pin.slash.fill" : "pin") { clipboard.togglePin(item) }
                }
                .frame(width: 120, alignment: .topLeading)
            }
        }
    }
}
