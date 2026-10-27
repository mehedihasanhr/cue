import AppKit
import os
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Files parked for a moment: dropped on the island's shelf (not kept as assets),
/// or in the floating basket, they wait until dragged out somewhere else, and leave
/// as they go.
///
/// For this session only: a parked file is the user's own, where it was, and Cue
/// may read it only while it runs. Images dropped without a file (from a browser)
/// are written to a folder in Caches, emptied on launch.
@MainActor @Observable
final class ShelfStore {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        /// The file's icon at once, its thumbnail once Quick Look has made one.
        var thumbnail: NSImage
        var name: String { url.lastPathComponent }
    }

    private(set) var items: [Item] = []
    /// The items picked to drag out or remove together.
    var selection: Set<UUID> = []
    /// The last item left the shelf.
    @ObservationIgnored var onEmptied: () -> Void = {}

    @ObservationIgnored private let folder: URL

    /// `folderName`: where images that came without a file are written, in Caches.
    init(folderName: String = "Shelf") {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("Cue/\(folderName)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Parks files; one already on the shelf stays where it is. Returns how many were added.
    @discardableResult
    func add(fileURLs: [URL]) -> Int {
        let parked = Set(items.map { $0.url.standardizedFileURL })
        let new = fileURLs.filter { !parked.contains($0.standardizedFileURL) }.map {
            Item(url: $0, thumbnail: NSWorkspace.shared.icon(forFile: $0.path))
        }
        items.append(contentsOf: new)
        for item in new { loadThumbnail(for: item) }
        return new.count
    }

    /// Parks an image that came without a file, written out so it can be dragged on.
    @discardableResult
    func add(imageData data: Data) -> Int {
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(isPNG ? "Image.png" : "Image.tiff")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return 0
        }
        return add(fileURLs: [url])
    }

    func remove(_ ids: Set<UUID>) {
        let leaving = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        // Only what the shelf wrote itself; the user's own files stay where they are.
        for item in leaving where item.url.path.hasPrefix(folder.path) {
            try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        }
        if items.isEmpty, !leaving.isEmpty { onEmptied() }
    }

    func clear() {
        remove(Set(items.map(\.id)))
    }

    /// Empties it without deleting anything, handing back what was in it (to put back later).
    func takeAll() -> [URL] {
        let urls = items.map(\.url)
        items = []
        selection = []
        return urls
    }

    /// The files an action works on: the picked ones, or all when none are picked.
    var targets: [Item] { selection.isEmpty ? items : items.filter { selection.contains($0.id) } }

    /// Runs `work` on each file off the main thread, puts what it makes on the shelf
    /// (picked, so it is the next thing dragged out) and says how it went.
    func produce(_ done: String, from urls: [URL], each: Bool = true, _ work: @escaping @Sendable (_ urls: [URL], _ folder: URL) -> [URL]) {
        let folder = self.folder
        Task.detached {
            let made = each ? urls.flatMap { work([$0], folder) } : work(urls, folder)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !made.isEmpty else {
                    FeedbackHUD.show("Couldn't do that", symbol: "exclamationmark.triangle.fill")
                    return
                }
                let before = Set(items.map(\.id))
                add(fileURLs: made)
                selection = Set(items.map(\.id)).subtracting(before)
                FeedbackHUD.show(done, symbol: "checkmark.circle.fill", subtitle: made.count == 1 ? made[0].lastPathComponent : "\(made.count) files on the shelf")
            }
        }
    }

    /// What a drag starting on `item` carries: the whole selection when the item is
    /// in it, otherwise the item alone.
    func dragItems(from item: Item) -> [Item] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    private func loadThumbnail(for item: Item) {
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in
                guard let self, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[index].thumbnail = image
            }
        }
    }
}

/// The shelf at the top of the open island: the parked files in a row, each one
/// picked with a click and dragged out on its own or with the others picked.
struct ShelfRow: View {
    @Environment(ShelfStore.self) private var shelf

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Icon("tray.and.arrow.down.fill", size: 12)
                Text("Shelf")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(shelf.items.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(shelf.items) { item in
                        ShelfChip(item: item, selected: shelf.selection.contains(item.id))
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollClipDisabled(false)
            .mask {
                // Fades at the ends say there is more to scroll to.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                }
            }
            Menu {
                ShelfActions(targets: shelf.targets)
            } label: {
                HStack(spacing: 4) {
                    Icon("wand.and.stars", size: 11, weight: .semibold)
                    Text("Actions").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: IslandChrome.chipRadius, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(shelf.selection.isEmpty ? "Convert, compress, look at or send everything on the shelf" : "Convert, compress, look at or send the picked files")
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if shelf.selection.isEmpty { shelf.clear() } else { shelf.remove(shelf.selection) }
                }
            } label: {
                Text(shelf.selection.isEmpty ? "Clear" : "Remove \(shelf.selection.count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: IslandChrome.chipRadius, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shelf.selection.isEmpty ? "Take everything off the shelf" : "Take the picked files off the shelf")
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: IslandChrome.controlRadius + 4, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: shelf.items.map(\.id))
        .animation(.easeOut(duration: 0.12), value: shelf.selection)
    }
}

/// One parked file: its thumbnail and name. A click picks it (or lets it go); a
/// drag takes it out, with the rest of the picked files when it is one of them.
private struct ShelfChip: View {
    @Environment(ShelfStore.self) private var shelf
    let item: ShelfStore.Item
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandChrome.chipRadius + 2, style: .continuous)
        HStack(spacing: 7) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(item.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .frame(height: 32)
        .frame(maxWidth: 180)
        .fixedSize()
        .background(selected ? IslandStyle.accent.opacity(0.28) : .white.opacity(hovering ? 0.12 : 0.07), in: shape)
        .overlay(shape.strokeBorder(selected ? IslandStyle.accent.opacity(0.7) : .clear, lineWidth: 1))
        .overlay {
            ShelfDragSource(items: { shelf.dragItems(from: item) }, onClick: {
                if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
            }, onDelivered: { ids in
                withAnimation(.easeOut(duration: 0.18)) { shelf.remove(ids) }
            })
        }
        .onHover { hovering = $0 }
        .contextMenu { ShelfActions(targets: shelf.dragItems(from: item)) }
        .help(item.url.path)
    }
}

/// Takes a chip's clicks and drags in AppKit: a SwiftUI drag carries a single item,
/// and the shelf drags several files at once (each as a file URL, with the sandbox
/// access the app receiving them needs).
struct ShelfDragSource: NSViewRepresentable {
    var items: () -> [ShelfStore.Item]
    var onClick: () -> Void
    /// The files were dropped somewhere that took them.
    var onDelivered: (Set<UUID>) -> Void

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) {
        update(view)
    }

    private func update(_ view: SourceView) {
        view.items = items
        view.onClick = onClick
        view.onDelivered = onDelivered
    }

    final class SourceView: NSView, NSDraggingSource {
        var items: (() -> [ShelfStore.Item])?
        var onClick: (() -> Void)?
        var onDelivered: ((Set<UUID>) -> Void)?
        private var pressStart: CGPoint?
        private var dragged: Set<UUID> = []

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            pressStart = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressStart, let items = items?(), !items.isEmpty else { return }
            guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 else { return }
            pressStart = nil
            dragged = Set(items.map(\.id))
            let origin = convert(start, from: nil)
            let side: CGFloat = 48
            let draggingItems = items.enumerated().map { index, item in
                let draggingItem = NSDraggingItem(pasteboardWriter: ShelfFilePromise.writer(for: item.url))
                // Fanned a little, so several read as a stack.
                let offset = CGFloat(min(index, 4)) * 5
                draggingItem.setDraggingFrame(CGRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                                              contents: item.thumbnail)
                return draggingItem
            }
            IslandDrag.fromShelf = true
            let session = beginDraggingSession(with: draggingItems, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            if pressStart != nil { onClick?() }
            pressStart = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            DispatchQueue.main.async { IslandDrag.fromShelf = false }
            if operation != [] { onDelivered?(dragged) }
            dragged = []
        }
    }
}

/// The shelf's actions on `targets`, for its Actions menu and a file's own menu.
struct ShelfActions: View {
    @Environment(ShelfStore.self) private var shelf
    let targets: [ShelfStore.Item]

    private var urls: [URL] { targets.map(\.url) }
    private var images: [URL] { urls.filter(FileActions.isImage) }

    var body: some View {
        if !images.isEmpty {
            Menu("Convert to") {
                ForEach(FileActions.ImageFormat.writable, id: \.self) { format in
                    Button(format.title) {
                        shelf.produce("Converted to \(format.title)", from: images) { urls, folder in
                            urls.compactMap { FileActions.convert($0, to: format, into: folder) }
                        }
                    }
                }
            }
            Button("Make Smaller") {
                shelf.produce("Made smaller", from: images) { urls, folder in
                    urls.compactMap { FileActions.compress($0, into: folder) }
                }
            }
        }
        Button(urls.count == 1 ? "Make a ZIP" : "Make a ZIP of \(urls.count)") {
            shelf.produce("Zipped", from: urls, each: false) { urls, folder in
                FileActions.zip(urls, into: folder).map { [$0] } ?? []
            }
        }
        Divider()
        Button("Quick Look") { FileActions.quickLook(urls) }
        Menu("Share") {
            Button("AirDrop") { FileActions.share(urls, via: .sendViaAirDrop) }
            Button("Mail") { FileActions.share(urls, via: .composeEmail) }
            Button("Messages") { FileActions.share(urls, via: .composeMessage) }
        }
        Button("Show in Finder") { FileActions.reveal(urls) }
    }
}

/// A shelf file as a drag hands it on. Files Cue made itself (Transform's results,
/// pictures that came without a file) live in its sandbox container, which macOS
/// won't open to the app they are dropped on: Finder fails with -8058. Those go as
/// file promises, Cue copying each where it is dropped; the rest as plain files.
nonisolated final class ShelfFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable { // only an immutable URL
    private let source: URL
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// The provider holds its delegate weakly, and the file is asked for after the
    /// drop: each is kept here until it has been written.
    private static let pending = OSAllocatedUnfairLock<[ObjectIdentifier: ShelfFilePromise]>(initialState: [:])

    private init(source: URL) {
        self.source = source
    }

    static func writer(for url: URL) -> any NSPasteboardWriting {
        let container = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(container + "/") else { return url as NSURL }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
        let promise = ShelfFilePromise(source: url)
        pending.withLock { $0[ObjectIdentifier(promise)] = promise }
        return NSFilePromiseProvider(fileType: type.identifier, delegate: promise)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        source.lastPathComponent
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        defer { _ = Self.pending.withLock { $0.removeValue(forKey: ObjectIdentifier(self)) } }
        do {
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
