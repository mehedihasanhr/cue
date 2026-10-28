import AppKit
import Observation

/// One Transform window's state: the files, the action chosen and its options, what
/// it would weigh afterwards, the presets, and where the results go.
@MainActor @Observable
final class TransformModel {
    enum Action: String, CaseIterable, Codable, Sendable {
        case compress, convert, resize, removeBackground, rotate, removeMetadata, combine, zip, rename

        var title: String {
            switch self {
            case .compress: "Compress"
            case .convert: "Convert"
            case .resize: "Resize"
            case .removeBackground: "Remove background"
            case .rotate: "Rotate"
            case .removeMetadata: "Remove metadata"
            case .combine: "Combine into PDF"
            case .zip: "Zip"
            case .rename: "Rename"
            }
        }

        var symbol: String {
            switch self {
            case .compress: "arrow.down.right.and.arrow.up.left"
            case .convert: "arrow.triangle.2.circlepath"
            case .resize: "plus.magnifyingglass"
            case .removeBackground: "person.and.background.dotted"
            case .rotate: "rotate.right.fill"
            case .removeMetadata: "eye.slash.fill"
            case .combine: "doc.on.doc.fill"
            case .zip: "doc.zipper"
            case .rename: "character.cursor.ibeam"
            }
        }

        /// It works on pictures only.
        var imagesOnly: Bool { ![.combine, .zip, .rename].contains(self) }

        /// What's made says so: "Compressed", "Zipped"…
        var done: String {
            switch self {
            case .compress: "Compressed"
            case .convert: "Converted"
            case .resize: "Resized"
            case .removeBackground: "Background removed"
            case .rotate: "Rotated"
            case .removeMetadata: "Metadata removed"
            case .combine: "Combined into a PDF"
            case .zip: "Zipped"
            case .rename: "Renamed"
            }
        }
    }

    enum SaveTo: String, CaseIterable, Codable {
        case original, shelf, pictures, downloads, folder

        var title: String {
            switch self {
            case .original: "Next to the original"
            case .shelf: "On the shelf"
            case .pictures: "Pictures"
            case .downloads: "Downloads"
            case .folder: "Choose folder"
            }
        }
    }

    /// Everything an action is set to, as a preset keeps it.
    struct Settings: Equatable, Codable {
        var action: Action = .compress
        var compress = TransformEngine.CompressOptions()
        var convertFormat: TransformEngine.Format = .webp
        var convertQuality = 0.85
        var resize = TransformEngine.ResizeOptions()
        var rotation = TransformEngine.Rotation()
        var rename = TransformEngine.RenameOptions()
    }

    struct Preset: Identifiable, Equatable, Codable {
        var id = UUID()
        var name: String
        var symbol: String
        var settings: Settings
        var builtIn = false
    }

    var files: [URL] { didSet { estimateSoon() } }
    var settings = Settings() { didSet { if settings != oldValue { estimateSoon() } } }
    var outputName = ""
    var saveTo: SaveTo {
        didSet { if remembersSaveTo { UserDefaults.standard.set(saveTo.rawValue, forKey: Self.saveToKey) } }
    }
    /// The folder chosen for `.folder`.
    private(set) var folder: URL?
    /// What the files weigh now and afterwards; nil while it's worked out or when it can't be.
    private(set) var estimate: (before: Int, after: Int)?
    private(set) var running = false
    private(set) var saved: [Preset]

    static let builtIns: [Preset] = [
        Preset(name: "Web ready", symbol: "globe",
               settings: Settings(action: .compress, compress: .init(by: .quality, quality: 0.75, format: .webp, maxSide: 2048, removeMetadata: true)), builtIn: true),
        Preset(name: "Under 10 MB", symbol: "arrow.down.to.line",
               settings: Settings(action: .compress, compress: .init(by: .fileSize, targetBytes: 10_000_000, format: .automatic, maxSide: nil, removeMetadata: false)),
               builtIn: true),
    ]

    var presets: [Preset] { Self.builtIns + saved }

    private static let saveToKey = "transform.saveTo"
    private static let folderKey = "transform.folder"
    private static let presetsKey = "transform.presets"
    private var estimateTask: Task<Void, Never>?
    private let estimating: Bool
    /// Save to is remembered for next time; not for the convert wheel's one-off.
    private var remembersSaveTo = true

    /// `estimating`: works out the sizes as settings change (the window shows them).
    init(files: [URL], estimating: Bool = true) {
        self.estimating = estimating
        self.files = files
        saveTo = SaveTo(rawValue: UserDefaults.standard.string(forKey: Self.saveToKey) ?? "") ?? .original
        saved = (UserDefaults.standard.data(forKey: Self.presetsKey)).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        if let data = UserDefaults.standard.data(forKey: Self.folderKey) {
            var stale = false
            folder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if saveTo == .folder, folder == nil { saveTo = .shelf }
        if !hasImages { settings.action = .zip }
        estimateSoon()
    }

    var images: [URL] { files.filter(TransformEngine.isImage) }
    var hasImages: Bool { !images.isEmpty }

    func isAvailable(_ action: Action) -> Bool {
        switch action {
        case .combine: files.contains { TransformEngine.isImage($0) || TransformEngine.isPDF($0) }
        case .zip, .rename: !files.isEmpty
        default: hasImages
        }
    }

    /// "askit.png, 261 KB", or "3 files, 2.4 MB".
    var summary: String {
        let size = Self.bytes(files.reduce(0) { $0 + TransformEngine.fileSize($1) })
        return files.count == 1 ? "\(files[0].lastPathComponent), \(size)" : "\(files.count) files, \(size)"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    func apply(_ preset: Preset) {
        settings = preset.settings
    }

    func savePreset(named name: String) {
        guard !name.isEmpty else { return }
        saved.append(Preset(name: name, symbol: "star", settings: settings))
        persistPresets()
    }

    func deletePreset(_ preset: Preset) {
        saved.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func persistPresets() {
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.presetsKey)
    }

    func add(_ urls: [URL]) {
        files.append(contentsOf: urls.filter { !files.contains($0) })
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
    }

    /// Asks for a folder and keeps it for next time.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else {
            if folder == nil { saveTo = .shelf }
            return
        }
        folder = url
        UserDefaults.standard.set(try? url.bookmarkData(options: .withSecurityScope), forKey: Self.folderKey)
        saveTo = .folder
    }

    var folderTitle: String { folder?.lastPathComponent ?? "Choose folder" }

    // MARK: - Estimate

    /// Works out what the images would weigh, a moment after the last change.
    private func estimateSoon() {
        estimateTask?.cancel()
        estimate = nil
        guard estimating else { return }
        let settings = settings
        let inputs = Array((settings.action.imagesOnly ? images : files).prefix(12))
        guard [.compress, .convert, .resize, .rotate, .removeMetadata].contains(settings.action), !inputs.isEmpty else { return }
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (Int, Int)? in
                var before = 0, after = 0
                for url in inputs {
                    guard !Task.isCancelled else { return nil }
                    before += TransformEngine.fileSize(url)
                    let data: Data? = switch settings.action {
                    case .compress: TransformEngine.compressed(url, settings.compress)?.data
                    case .convert: TransformEngine.converted(url, to: settings.convertFormat, quality: settings.convertQuality)
                    case .resize: TransformEngine.resized(url, settings.resize)?.data
                    case .rotate: TransformEngine.rotated(url, settings.rotation)?.data
                    case .removeMetadata: TransformEngine.withoutMetadata(url)
                    default: nil
                    }
                    after += data?.count ?? TransformEngine.fileSize(url)
                }
                return (before, after)
            }.value
            guard !Task.isCancelled, let self, let result else { return }
            estimate = (result.0, result.1)
        }
    }

    // MARK: - Running

    /// The work for the chosen action: what it's run on, whether file by file, and
    /// what it does into a folder.
    private func work() -> (inputs: [URL], each: Bool, run: @Sendable ([URL], URL) -> [URL]) {
        let settings = settings
        let name = outputName
        switch settings.action {
        case .compress: return (images, true, { urls, folder in urls.compactMap { TransformEngine.compress($0, settings.compress, into: folder) } })
        case .convert:
            return (images, true, { urls, folder in urls.compactMap { TransformEngine.convert($0, to: settings.convertFormat, quality: settings.convertQuality, into: folder) } })
        case .resize: return (images, true, { urls, folder in urls.compactMap { TransformEngine.resize($0, settings.resize, into: folder) } })
        case .removeBackground: return (images, true, { urls, folder in urls.compactMap { TransformEngine.removeBackground($0, into: folder) } })
        case .rotate: return (images, true, { urls, folder in urls.compactMap { TransformEngine.rotate($0, settings.rotation, into: folder) } })
        case .removeMetadata: return (images, true, { urls, folder in urls.compactMap { TransformEngine.removeMetadata($0, into: folder) } })
        case .combine:
            let inputs = files.filter { TransformEngine.isImage($0) || TransformEngine.isPDF($0) }
            return (inputs, false, { urls, folder in TransformEngine.combine(urls, named: name, into: folder).map { [$0] } ?? [] })
        case .zip: return (files, false, { urls, folder in TransformEngine.zip(urls, named: name, into: folder).map { [$0] } ?? [] })
        case .rename: return (files, false, { urls, folder in TransformEngine.rename(urls, settings.rename, into: folder) })
        }
    }

    /// Runs the action. On the shelf, `produce` adds what's made there; anywhere else
    /// the files are written into that folder and shown in the Finder.
    func run(produce: @escaping (_ done: String, _ from: [URL], _ each: Bool, _ work: @escaping @Sendable ([URL], URL) -> [URL]) -> Void,
             finished: @escaping @MainActor () -> Void) {
        let (inputs, each, run) = work()
        guard !inputs.isEmpty, !running else { return }
        let done = settings.action.done
        if saveTo == .shelf {
            produce(done, inputs, each, run)
            finished()
            return
        }
        // One folder for everything, or (next to the original) each file's own.
        let fixed: URL? = switch saveTo {
        case .pictures: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .folder: folder
        case .shelf, .original: nil
        }
        let besideOriginals = saveTo == .original
        guard besideOriginals || fixed != nil else { return }
        running = true
        Task.detached {
            let scoped = fixed?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { fixed?.stopAccessingSecurityScopedResource() } }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            var placed: [URL] = []
            for batch in each ? inputs.map { [$0] } : [inputs] {
                let destination = fixed ?? batch[0].deletingLastPathComponent()
                placed += run(batch, staging).compactMap { Self.place($0, in: destination) }
            }
            await MainActor.run { [weak self] in
                self?.running = false
                if placed.isEmpty {
                    FeedbackHUD.show("Couldn't do that", symbol: "exclamationmark.triangle.fill", subtitle: besideOriginals ? "Cue can't write in that folder" : nil)
                } else {
                    let place = besideOriginals ? "next to the original" : "in \((fixed ?? placed[0].deletingLastPathComponent()).lastPathComponent)"
                    FeedbackHUD.show(done, symbol: "checkmark.circle.fill", subtitle: placed.count == 1 ? placed[0].lastPathComponent : "\(placed.count) files \(place)")
                    // Beside the original it is already in view; elsewhere, show it.
                    if !besideOriginals { NSWorkspace.shared.activateFileViewerSelecting(placed) }
                    finished()
                }
            }
        }
    }

    /// `url` converted to `format` (nil: a one-page PDF) without the window, put where
    /// Save to says, as the window would.
    static func quickConvert(_ url: URL, to format: TransformEngine.Format?,
                             produce: @escaping (_ done: String, _ from: [URL], _ each: Bool, _ work: @escaping @Sendable ([URL], URL) -> [URL]) -> Void) {
        let model = TransformModel(files: [url], estimating: false)
        if let format {
            model.settings.action = .convert
            model.settings.convertFormat = format
            model.settings.convertQuality = 0.9
        } else {
            model.settings.action = .combine
            model.outputName = url.deletingPathExtension().lastPathComponent
        }
        // Next to the original; on the shelf where Cue can't write there.
        model.remembersSaveTo = false
        model.saveTo = FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) ? .original : .shelf
        // Kept until the work is done.
        model.run(produce: produce) { _ = model }
    }

    /// `file` moved into `folder`, numbered if its name is taken.
    nonisolated private static func place(_ file: URL, in folder: URL) -> URL? {
        let base = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        var target = folder.appendingPathComponent(file.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(number)" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        return (try? FileManager.default.moveItem(at: file, to: target)) != nil ? target : nil
    }
}
