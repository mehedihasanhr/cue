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
        // A window shadow is recomputed from the pixels on every change, which
        // would make the slide between items stutter; the island has none either.
        hasShadow = false
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
    let notes: NoteStore
    let tasks: TaskStore
    let actions: HistoryActions
    let onEdit: (IslandDetail) -> Void
    let onClose: () -> Void
    /// The pointer left the pane.
    let onLeave: () -> Void

    var body: some View {
        ZStack {
            if let detail = model.detail {
                PreviewPaneView(detail: detail, library: library, clipboard: clipboard, assets: assets, colors: colors, notes: notes, tasks: tasks, actions: actions,
                                onEdit: onEdit, onClose: onClose)
                    .id(detail.id) // the identity, not the state: a pin or a rename does not slide
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .onHover { inside in if !inside { onLeave() } }
        .environment(\.colorScheme, .dark)
    }

    /// Enter from the side the pointer moved towards, leave the other way — the same
    /// path in both directions, so the pane reads as a strip of cards.
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
    let notes: NoteStore
    let tasks: TaskStore
    let actions: HistoryActions
    /// Opens a note or a task to edit.
    let onEdit: (IslandDetail) -> Void
    let onClose: () -> Void
    @Environment(AppPreferences.self) private var preferences

    /// The pane's height for an item: taller for pictures.
    static func height(for detail: IslandDetail, clipboard: ClipboardHistory) -> CGFloat {
        switch detail {
        case .capture, .asset: 460
        case .color: 400
        case .note, .task: 360
        case .clipboard(let item):
            switch item.kind {
            case .image, .link: 460
            case .color: 400
            case .files: 320
            case .text: ClipboardTextPreview.presentation(of: item, clipboard: clipboard).label == nil ? 320 : 440
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

    /// The item's pills, plus what a text entry is (rich text, a language, Markdown).
    private var pills: [IslandDetailHeader.Pill] {
        var pills = IslandDetailHeader.pills(for: detail, library: library)
        if case .clipboard(let item) = detail, item.kind == .text {
            let presentation = ClipboardTextPreview.presentation(of: item, clipboard: clipboard)
            if let label = presentation.label { pills.insert(IslandDetailHeader.Pill(symbol: presentation.symbol, text: label), at: 1) }
        }
        return pills
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
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
            case .note(let note):
                round("pencil", help: "Edit") { onEdit(.note(note)) }
                round("folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([notes.fileURL(for: note)]) }
            case .task(let task):
                round("pencil", help: "Edit") { onEdit(.task(task)) }
                round(task.status == .complete ? "circle" : "checkmark.circle.fill", help: task.status == .complete ? "Reopen" : "Mark complete") {
                    tasks.setStatus(task.status == .complete ? .pending : .complete, for: task)
                }
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
        case .note(let note): copyText(note.text, title: note.title)
        case .task(let task): copyText(task.text, title: task.title)
        }
    }

    private func copyText(_ text: String, title: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: title)
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
        case .note(let stale):
            let note = notes.notes.first { $0.id == stale.id } ?? stale
            markdown(note.text, imageURL: { notes.url(for: $0) }, attachmentURL: { notes.url(for: $0) })
        case .task(let stale):
            let task = tasks.tasks.first { $0.id == stale.id } ?? stale
            markdown(task.text, imageURL: { tasks.imageURL(for: $0) }, attachmentURL: { tasks.attachmentURL(for: $0) })
                .opacity(task.status == .complete ? 0.6 : 1)
        }
    }

    /// A note's or a task's text, rendered.
    private func markdown(_ text: String, imageURL: @escaping (String) -> URL?, attachmentURL: @escaping (String) -> URL?) -> some View {
        ScrollView {
            MarkdownView(markdown: text, imageURL: imageURL, attachmentURL: attachmentURL)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

        /// Sharp versions already decoded, so coming back to an item costs nothing.
        private static let decoded: NSCache<NSUUID, NSImage> = {
            let cache = NSCache<NSUUID, NSImage>()
            cache.countLimit = 40
            return cache
        }()

        var body: some View {
            Group {
                if let image = image ?? Self.decoded.object(forKey: key as NSUUID) ?? placeholder {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .task(id: key) {
                if Self.decoded.object(forKey: key as NSUUID) != nil { return }
                let load = load
                let sharp: NSImage? = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let image = load()
                        Task { @MainActor in continuation.resume(returning: image) }
                    }
                }
                guard !Task.isCancelled, let sharp else { return }
                Self.decoded.setObject(sharp, forKey: key as NSUUID)
                image = sharp
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
            ClipboardTextPreview(item: item, clipboard: clipboard)
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

    /// What is already known about the link is shown at once, so the pane slides
    /// in whole; only a first look at a link waits for the network.
    init(url: URL) {
        self.url = url
        _metadata = State(initialValue: LinkMetadata.cached(url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let data = metadata?.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if metadata?.isVideo == true {
                            Icon("play.fill", size: 22, weight: .bold)
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if metadata == nil, !failed {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(height: 120)
                    .overlay { ProgressView().controlSize(.small) }
                    .transition(.opacity)
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
            guard metadata == nil else { return }
            let fetched = await LinkMetadata.fetch(url)
            guard !Task.isCancelled else { return }
            // Arriving later than the slide: the picture fades and settles in rather than popping.
            withAnimation(.smooth(duration: 0.28)) {
                metadata = fetched
                failed = fetched == nil
            }
        }
    }
}

/// What a page says about itself: Open Graph tags, else the `<title>` and the
/// description meta; the picture is fetched too. Cached per URL for the session.
struct LinkMetadata: Sendable {
    var title: String?
    var description: String?
    var imageData: Data?
    /// A video (YouTube, Vimeo): the picture gets a play badge.
    var isVideo = false

    /// Links looked up this session. Only a complete answer is kept: a page whose
    /// picture could not be fetched is asked again next time.
    @MainActor private static var cache: [URL: LinkMetadata] = [:]
    @MainActor private static var inFlight: Set<URL> = []

    /// What is known already, without waiting.
    @MainActor static func cached(_ url: URL) -> LinkMetadata? { cache[url] }

    /// Starts the lookup so it is done by the time the link is previewed (a card is hovered).
    @MainActor static func prefetch(_ url: URL) {
        guard cache[url] == nil, !inFlight.contains(url) else { return }
        Task { _ = await fetch(url) }
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Klik"
    /// YouTube's page is over a megabyte before its meta tags; enough is read to reach them.
    private static let htmlLimit = 4_000_000

    static func fetch(_ url: URL) async -> LinkMetadata? {
        if let cached = await cached(url) { return cached }
        await MainActor.run { _ = inFlight.insert(url) }
        defer { Task { @MainActor in inFlight.remove(url) } }
        var found = await fromOEmbed(url)
        if found == nil { found = await fromHTML(url) }
        guard var metadata = found else { return nil }
        if let pictureURL = metadata.pictureURL { metadata.imageData = await picture(pictureURL) }
        if metadata.pictureURL == nil || metadata.imageData != nil {
            await MainActor.run { cache[url] = metadata }
        }
        return metadata
    }

    private var pictureURL: URL?

    /// Video sites answer oEmbed with the title, the channel and a thumbnail —
    /// small and quick, where the page itself is huge.
    private static func fromOEmbed(_ url: URL) async -> LinkMetadata? {
        guard let host = url.host()?.lowercased() else { return nil }
        let endpoint: String
        if host == "youtu.be" || host.hasSuffix("youtube.com") { endpoint = "https://www.youtube.com/oembed" }
        else if host.hasSuffix("vimeo.com") { endpoint = "https://vimeo.com/api/oembed.json" }
        else { return nil }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
        guard let oembedURL = components?.url, let data = await get(oembedURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var metadata = LinkMetadata()
        metadata.title = json["title"] as? String
        metadata.description = [json["author_name"] as? String, json["provider_name"] as? String].compactMap { $0 }.joined(separator: " · ")
        metadata.pictureURL = (json["thumbnail_url"] as? String).flatMap(URL.init)
        metadata.isVideo = (json["type"] as? String) == "video"
        return metadata.title == nil ? nil : metadata
    }

    /// Open Graph / Twitter tags, else the `<title>` and the description meta.
    private static func fromHTML(_ url: URL) async -> LinkMetadata? {
        guard let data = await get(url),
              let html = String(data: data.prefix(htmlLimit), encoding: .utf8) ?? String(data: data.prefix(htmlLimit), encoding: .isoLatin1)
        else { return nil }
        var metadata = LinkMetadata()
        metadata.title = meta("og:title", in: html) ?? meta("twitter:title", in: html) ?? titleTag(html)
        metadata.description = meta("og:description", in: html) ?? meta("twitter:description", in: html) ?? meta("description", in: html)
        if let picture = meta("og:image", in: html) ?? meta("twitter:image", in: html) { metadata.pictureURL = URL(string: picture, relativeTo: url)?.absoluteURL }
        metadata.isVideo = (meta("og:type", in: html) ?? "").hasPrefix("video")
        return metadata
    }

    private static func picture(_ url: URL) async -> Data? {
        guard let data = await get(url), data.count < 8_000_000, NSImage(data: data) != nil else { return nil }
        return data
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
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

