import AppKit
import SwiftUI

/// A card opened in a pane of its own under the island (Settings › Island › Preview
/// opens › Below the island): the cards stay where they are and the item is shown
/// large — an image at full width, a color as a band with every format, a link with
/// the page's picture, title and summary, text in full. The pane counts as part of
/// the island for the pointer, so moving down into it does not close anything.
final class PreviewPaneWindow: NSPanel {
    /// Between the island's bottom edge and the pane.
    static let gap: CGFloat = 8

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Just under the island (which sits above the menu bar), above everything else.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        sharingType = .readOnly
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
}

/// What the pane shows, and which way the next item comes in from.
@Observable
@MainActor
final class PreviewPaneModel {
    var detail: IslandDetail?
    /// +1: the next item slides in from the right (the pointer moved right), -1 from
    /// the left, 0: it fades.
    var direction = 0
}

/// The pane's frame and its content, which slides sideways from one item to the next.
struct PreviewPaneRoot: View {
    let model: PreviewPaneModel
    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let actions: HistoryActions
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if let detail = model.detail {
                PreviewPaneView(detail: detail, library: library, clipboard: clipboard, assets: assets, colors: colors, actions: actions, onClose: onClose)
                    .id(detail)
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private var transition: AnyTransition {
        switch model.direction {
        case 1: .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity))
        case -1: .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .move(edge: .trailing).combined(with: .opacity))
        default: .opacity
        }
    }
}

/// The pane's content: pills about the item and its actions in a row, the item below.
struct PreviewPaneView: View {
    let detail: IslandDetail
    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let actions: HistoryActions
    let onClose: () -> Void
    @Environment(AppPreferences.self) private var preferences

    /// The pane's height for an item: taller for pictures.
    static func height(for detail: IslandDetail, clipboard: ClipboardHistory) -> CGFloat {
        switch detail {
        case .capture, .asset: 460
        case .color: 400
        case .clipboard(let item):
            switch item.kind {
            case .image, .link: 460
            case .color: 400
            case .text, .files: 320
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(16)
        .foregroundStyle(.white)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(Array(IslandDetailHeader.pills(for: detail, library: library).enumerated()), id: \.offset) { _, pill in
                HStack(spacing: 5) {
                    Icon(pill.symbol, size: 14, weight: .medium)
                    Text(pill.text).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 8)
            copyButton
            switch detail {
            case .capture(let item):
                round("pencil", help: "Edit") { actions.edit(item) }
                round("eye", help: "Open in the viewer") { actions.preview(item) }
            case .asset(let item):
                round("arrow.up.forward.app", help: "Open") { assets.open(item) }
            case .clipboard(let item) where item.kind == .link:
                round("safari", help: "Open in the browser") { if let url = URL(string: item.text) { NSWorkspace.shared.open(url) } }
            case .clipboard(let item) where item.kind == .image:
                round("pencil", help: "Edit") { actions.editClipboardImage(item) }
            default:
                EmptyView()
            }
            round("xmark", help: "Close", action: onClose)
        }
    }

    /// Copy, and for a color a menu of its formats.
    @ViewBuilder
    private var copyButton: some View {
        if let color = previewColor {
            Menu {
                ForEach(ColorFormat.allCases, id: \.self) { format in
                    Button(format.string(for: color)) { copyColor(color, as: format) }
                }
            } label: {
                HStack(spacing: 6) {
                    Icon("doc.on.doc", size: 14, weight: .medium)
                    Text("Copy").font(.system(size: 12, weight: .semibold))
                    Icon("chevron.down", size: 11, weight: .bold).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            } primaryAction: {
                copyColor(color, as: preferences.colorFormat)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Button(action: copy) {
                HStack(spacing: 6) {
                    Icon("doc.on.doc", size: 14, weight: .medium)
                    Text("Copy").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var previewColor: PickedColor? {
        switch detail {
        case .color(let entry): entry.color
        case .clipboard(let item) where item.kind == .color: PickedColor(hex: item.text)
        default: nil
        }
    }

    private func round(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: 14, weight: .semibold)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copy() {
        switch detail {
        case .capture(let item): actions.copy(item)
        case .asset(let item):
            assets.copy(item)
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.fileName, image: assets.thumbnail(for: item))
        case .color(let entry): copyColor(entry.color, as: preferences.colorFormat)
        case .clipboard(let item):
            clipboard.copy(item)
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: item.contentTitle, image: clipboard.thumbnail(for: item))
        }
    }

    private func copyColor(_ color: PickedColor, as format: ColorFormat) {
        preferences.colorFormat = format
        let string = format.string(for: color)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setData(Data(), forType: Clipboard.ownMarker)
        FeedbackHUD.show("\(string) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), swatch: color)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch detail {
        case .color(let entry):
            colorView(entry.color)
        case .capture(let stale):
            let item = library.items.first { $0.id == stale.id } ?? stale
            let url = library.fileURL(for: item)
            picture(placeholder: library.thumbnail(for: item), key: item.id) {
                guard let url else { return nil }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                return ImageEncoding.thumbnail(at: url, maxPixels: 1600)
            }
        case .asset(let stale):
            let item = assets.items.first { $0.id == stale.id } ?? stale
            if item.kind == .image {
                let url = assets.fileURL(for: item)
                picture(placeholder: assets.thumbnail(for: item), key: item.id) { ImageEncoding.thumbnail(at: url, maxPixels: 1600) }
            } else {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: assets.fileURL(for: item).path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.fileName).font(.system(size: 14, weight: .semibold))
                        Text(item.sizeText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .clipboard(let stale):
            let item = clipboard.items.first { $0.id == stale.id } ?? stale
            clipboardView(item)
        }
    }

    /// A wide band of the color, and every format as a labelled row (click copies).
    private func colorView(_ color: PickedColor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.swiftUIColor)
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.15)))
            let formats = ColorFormat.allCases
            let half = (formats.count + 1) / 2
            HStack(alignment: .top, spacing: 24) {
                ForEach([Array(formats[..<half]), Array(formats[half...])], id: \.first) { column in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(column, id: \.self) { format in
                            FormatLine(label: format.title, value: format.string(for: color), current: format == preferences.colorFormat) {
                                copyColor(color, as: format)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct FormatLine: View {
        let label: String
        let value: String
        let current: Bool
        let copy: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 64, alignment: .leading)
                Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if current { Circle().fill(.white.opacity(0.5)).frame(width: 5, height: 5) }
                else if hovering { Icon("doc.on.doc", size: 11, weight: .semibold).foregroundStyle(.white.opacity(0.6)) }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hovering ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: copy)
        }
    }

    /// A picture at the pane's full width (the card's thumbnail first, then a sharp one).
    private func picture(placeholder: NSImage?, key: UUID, load: @escaping @Sendable () -> NSImage?) -> some View {
        SharpImage(key: key, placeholder: placeholder, load: load)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private struct SharpImage: View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    @ViewBuilder
    private func clipboardView(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .color:
            if let color = PickedColor(hex: item.text) { colorView(color) }
        case .image:
            let data = clipboard.imageData(for: item)
            picture(placeholder: clipboard.thumbnail(for: item), key: item.id) {
                guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return ImageEncoding.thumbnail(from: source, maxPixels: 1600)
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
        case .link:
            if let url = URL(string: item.text) {
                LinkPreviewView(url: url)
            } else {
                textView(item.text)
            }
        case .text:
            textView(item.text)
        }
    }

    private func textView(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The page behind a link: its picture, title and summary, fetched once.
private struct LinkPreviewView: View {
    let url: URL
    @State private var metadata: LinkMetadata?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let data = metadata?.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if metadata == nil, !failed {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(height: 120)
                    .overlay { ProgressView().controlSize(.small) }
            }
            Text(metadata?.title ?? url.host() ?? url.absoluteString)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            if let description = metadata?.description, !description.isEmpty {
                Text(description).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
            }
            Text(url.absoluteString).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: url) {
            metadata = await LinkMetadata.fetch(url)
            failed = metadata == nil
        }
    }
}

/// What a page says about itself: Open Graph tags, else the `<title>` and the
/// description meta; the picture is fetched too. Cached per URL for the session.
struct LinkMetadata: Sendable {
    var title: String?
    var description: String?
    var imageData: Data?

    private static let cache = LinkMetadataCache()

    static func fetch(_ url: URL) async -> LinkMetadata? {
        if let cached = await cache.get(url) { return cached }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh) Klik", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data.prefix(600_000), encoding: .utf8) ?? String(data: data.prefix(600_000), encoding: .isoLatin1)
        else { return nil }
        var metadata = LinkMetadata()
        metadata.title = meta("og:title", in: html) ?? meta("twitter:title", in: html) ?? titleTag(html)
        metadata.description = meta("og:description", in: html) ?? meta("twitter:description", in: html) ?? meta("description", in: html)
        if let picture = meta("og:image", in: html) ?? meta("twitter:image", in: html), let pictureURL = URL(string: picture, relativeTo: url)?.absoluteURL {
            var pictureRequest = URLRequest(url: pictureURL, timeoutInterval: 8)
            pictureRequest.setValue("Mozilla/5.0 (Macintosh) Klik", forHTTPHeaderField: "User-Agent")
            if let (imageData, _) = try? await URLSession.shared.data(for: pictureRequest), imageData.count < 8_000_000, NSImage(data: imageData) != nil {
                metadata.imageData = imageData
            }
        }
        await cache.set(url, metadata)
        return metadata
    }

    /// `<meta property="og:title" content="…">` in either attribute order, unescaped.
    private static func meta(_ name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "<meta[^>]*?(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]*?content\\s*=\\s*[\"']([^\"']*)[\"']",
            "<meta[^>]*?content\\s*=\\s*[\"']([^\"']*)[\"'][^>]*?(?:property|name)\\s*=\\s*[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let value = unescape(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func titleTag(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let value = unescape(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

private actor LinkMetadataCache {
    private var entries: [URL: LinkMetadata] = [:]
    func get(_ url: URL) -> LinkMetadata? { entries[url] }
    func set(_ url: URL, _ metadata: LinkMetadata) { entries[url] = metadata }
}
