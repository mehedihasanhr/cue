import CryptoKit
import Foundation
import WhisperKit

/// Where the downloaded Whisper models live, and how they arrive, change and go.
///
/// Each model has a folder of its own under `root`, and everything the model needs is
/// inside it: the Core ML files, the tokenizer fetched with them, the downloader's cache
/// and Cue's note of what was installed. So removing a model is deleting one folder, and
/// nothing of it is left anywhere else.
///
/// An update never touches the installed model until its replacement is known to work:
/// the new files go into a staging folder beside it, are loaded once to prove them, and
/// only then take the old folder's place, after which the old one is deleted. A download
/// that fails or is cancelled leaves the model as it was, and its staging folder is gone.
public final class WhisperModelStore: Sendable {
    /// What is installed, as Cue noted it when the install finished.
    public struct Installation: Codable, Equatable, Sendable {
        /// What the repository held for the model when it was downloaded; a different one
        /// there now means an update.
        public let fingerprint: String
        public let installedAt: Date
        /// Its size on disk, everything in its folder.
        public let bytes: Int64
        /// The model's own files, relative to its folder.
        public let modelPath: String
    }

    /// What the repository holds for a model right now.
    public struct RemoteInfo: Equatable, Sendable {
        /// Changes when any of its files does.
        public let fingerprint: String
        /// What downloading it takes: every file's size, together.
        public let bytes: Int64

        public init(fingerprint: String, bytes: Int64) {
            self.fingerprint = fingerprint
            self.bytes = bytes
        }
    }

    /// How a model arrives and is proved; the repository on Hugging Face, or a stand-in in tests.
    public struct Source: Sendable {
        /// Downloads `model` into the folder given, reporting the fraction done, and
        /// returns the folder holding the model's files.
        public var download: @Sendable (WhisperModel, URL, @escaping @Sendable (Double) -> Void) async throws -> URL
        /// What the repository holds for `model` now.
        public var remote: @Sendable (WhisperModel) async throws -> RemoteInfo
        /// Loads the model's files once, fetching anything else they need (the tokenizer)
        /// into the folder given, and lets go of them again.
        public var verify: @Sendable (_ modelFolder: URL, _ base: URL) async throws -> Void

        public init(download: @escaping @Sendable (WhisperModel, URL, @escaping @Sendable (Double) -> Void) async throws -> URL,
                    remote: @escaping @Sendable (WhisperModel) async throws -> RemoteInfo,
                    verify: @escaping @Sendable (URL, URL) async throws -> Void) {
            self.download = download
            self.remote = remote
            self.verify = verify
        }
    }

    public let root: URL
    private let source: Source

    private static let manifestName = "install.json"
    private static let stagingPrefix = ".staging-"
    private static let oldPrefix = ".old-"

    public init(root: URL, source: Source = .hub) {
        self.root = root
        self.source = source
    }

    /// The source this store was made with, for tests that make a second store on the same folder.
    var sourceForTests: Source { source }

    // MARK: Where things are

    /// Everything of `model`'s, in one folder.
    public func folder(for model: WhisperModel) -> URL {
        root.appending(path: model.id, directoryHint: .isDirectory)
    }

    /// The model's own files, for loading; nil when it is not installed.
    public func modelFolder(for model: WhisperModel) -> URL? {
        guard let installation = installation(of: model) else { return nil }
        return folder(for: model).appending(path: installation.modelPath, directoryHint: .isDirectory)
    }

    public func installation(of model: WhisperModel) -> Installation? {
        let folder = folder(for: model)
        guard let data = try? Data(contentsOf: folder.appending(path: Self.manifestName)),
              let installation = try? JSONDecoder().decode(Installation.self, from: data),
              FileManager.default.fileExists(atPath: folder.appending(path: installation.modelPath).path(percentEncoded: false))
        else { return nil }
        return installation
    }

    /// Every installed model's size together.
    public var totalBytes: Int64 {
        WhisperModel.all.compactMap { installation(of: $0)?.bytes }.reduce(0, +)
    }

    // MARK: Install, update, remove

    /// Downloads `model` and puts it in place, replacing what was there only once the new
    /// files are proved. Installing a model that is already installed is its update.
    @discardableResult
    public func install(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Installation {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Asked first, so the note records what was asked for; offline, this is what fails.
        let fingerprint = try await source.remote(model).fingerprint
        let staging = root.appending(path: Self.stagingPrefix + model.id + "-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let downloaded = try await source.download(model, staging, progress)
            try Task.checkCancellation()
            try await source.verify(downloaded, staging)
            try Task.checkCancellation()
            guard let modelPath = Self.relativePath(of: downloaded, in: staging) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let installation = Installation(fingerprint: fingerprint, installedAt: .now,
                                            bytes: Self.size(of: staging), modelPath: modelPath)
            try JSONEncoder().encode(installation).write(to: staging.appending(path: Self.manifestName), options: .atomic)
            try replace(folder(for: model), with: staging, id: model.id)
            return installation
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Whether the repository has changed `model` since it was installed. False when it
    /// is not installed.
    public func updateAvailable(for model: WhisperModel) async throws -> Bool {
        guard let installation = installation(of: model) else { return false }
        return try await source.remote(model).fingerprint != installation.fingerprint
    }

    /// What the repository holds for `model` now: its fingerprint and its real download size.
    public func remoteInfo(of model: WhisperModel) async throws -> RemoteInfo {
        try await source.remote(model)
    }

    /// Deletes `model` completely: its folder, and any half-finished download of it.
    public func remove(_ model: WhisperModel) throws {
        let folder = folder(for: model)
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: folder)
        }
        removeLeftovers { $0.hasPrefix(Self.stagingPrefix + model.id + "-") || $0.hasPrefix(Self.oldPrefix + model.id + "-") }
    }

    /// Deletes every model, and the folder that held them.
    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Clears out downloads that never finished and old copies that were never deleted
    /// (Cue quit in the middle of one). Run at launch, when no install is going.
    public func cleanUpLeftovers() {
        removeLeftovers { $0.hasPrefix(Self.stagingPrefix) || $0.hasPrefix(Self.oldPrefix) }
    }

    // MARK: Helpers

    /// `staging` takes `destination`'s place. The old folder steps aside first and comes
    /// back if the new one cannot be moved in, so there is always one whole model there.
    private func replace(_ destination: URL, with staging: URL, id: String) throws {
        let files = FileManager.default
        var old: URL?
        if files.fileExists(atPath: destination.path(percentEncoded: false)) {
            let aside = root.appending(path: Self.oldPrefix + id + "-" + UUID().uuidString, directoryHint: .isDirectory)
            try files.moveItem(at: destination, to: aside)
            old = aside
        }
        do {
            try files.moveItem(at: staging, to: destination)
        } catch {
            if let old { try? files.moveItem(at: old, to: destination) }
            throw error
        }
        if let old { try? files.removeItem(at: old) }
    }

    private func removeLeftovers(where matches: (String) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        for name in names where matches(name) {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    static func relativePath(of url: URL, in base: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        var basePath = base.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        if !basePath.hasSuffix("/") { basePath += "/" }
        guard path.hasPrefix(basePath) else { return nil }
        let relative = String(path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? nil : relative
    }

    /// Everything under `url`, as the disk counts it.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Hugging Face

extension WhisperModelStore.Source {
    /// Argmax's repository on Hugging Face, through WhisperKit's own downloader.
    public static let hub = WhisperModelStore.Source(
        download: { model, base, progress in
            try await WhisperKit.download(variant: model.id, downloadBase: base, from: WhisperModel.repository) { fraction in
                progress(fraction.fractionCompleted)
            }
        },
        remote: { model in try await HubFingerprint.fetch(model) },
        verify: { modelFolder, base in
            // Loading is the proof: Core ML reads every file, and WhisperKit fetches the
            // tokenizer into `base` on the way. Let go straight after; nothing stays loaded.
            let config = WhisperKitConfig(modelFolder: modelFolder.path(percentEncoded: false), tokenizerFolder: base,
                                          verbose: false, load: true, download: false)
            let kit = try await WhisperKit(config)
            await kit.unloadModels()
        }
    )
}

/// What the repository holds for a model, as one value: a hash of each file's path and
/// content id, so any file that changes, appears or goes changes it.
enum HubFingerprint {
    private struct Entry: Decodable {
        struct LFS: Decodable { let oid: String; let size: Int64 }
        let type: String
        let path: String
        let oid: String
        let size: Int64?
        let lfs: LFS?
    }

    static func fetch(_ model: WhisperModel) async throws -> WhisperModelStore.RemoteInfo {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(WhisperModel.repository)/tree/main/\(model.id)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let files = try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "file" }
        return WhisperModelStore.RemoteInfo(fingerprint: fingerprint(of: files.map { ($0.path, $0.lfs?.oid ?? $0.oid) }),
                                            bytes: files.reduce(0) { $0 + ($1.lfs?.size ?? $1.size ?? 0) })
    }

    static func fingerprint(of files: [(path: String, oid: String)]) -> String {
        let text = files.sorted { $0.path < $1.path }.map { "\($0.path) \($0.oid)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
