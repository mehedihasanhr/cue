import os
import CryptoKit
import Foundation
import Observation

/// Where Tesseract's language models live on disk, and whether one is there.
///
/// Split out from the downloader because the recogniser runs off the main actor and
/// needs to answer "can I read this?" without hopping — and the filesystem is the
/// durable truth anyway. In-flight download state matters only to Settings, which is
/// on the main actor already.
nonisolated enum TessdataFiles {
    /// Inside the sandbox container, beside the library's thumbnails and the other
    /// stores. **Never** inside the app bundle: that is code-signed and sealed, and
    /// writing to it invalidates the signature, which silently drops the Screen
    /// Recording grant.
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Cue/Tessdata", isDirectory: true)
    }()

    static func fileURL(for code: String) -> URL {
        TesseractLanguagePacks.fileURL(for: code, in: folder)
    }

    /// A pack counts as installed when it is on disk at exactly the length the
    /// catalogue records. A truncated download therefore reads as absent rather than
    /// as a model Tesseract will choke on.
    static func isInstalled(_ code: String) -> Bool {
        guard let pack = TesseractLanguagePacks.pack(forCode: code),
              let size = try? FileManager.default.attributesOfItem(atPath: fileURL(for: code).path(percentEncoded: false))[.size] as? Int
        else { return false }
        return size == pack.bytes
    }

    /// Removes anything a crashed download left behind.
    static func sweepPartials() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Fetches and keeps the Tesseract language models, one per language.
///
/// They are downloaded rather than bundled so the app stays small and a language can
/// be added without a release. Each is checked against the length and digest recorded
/// in `TesseractLanguagePacks` before it is installed — a model file is input to a
/// native library, so an unverified one is not something to hand it.
@Observable
@MainActor
final class LanguagePackStore {
    enum State: Equatable {
        case missing
        case downloading
        case ready
        case failed(String, offline: Bool)
    }

    private(set) var states: [String: State] = [:]
    /// Downloads in flight, so two captures of the same language share one fetch.
    private var inFlight: [String: Task<URL, any Error>] = [:]

    init() {
        try? FileManager.default.createDirectory(at: TessdataFiles.folder, withIntermediateDirectories: true)
        TessdataFiles.sweepPartials()
        refresh()
    }

    /// Reads the folder once and records every pack's state.
    ///
    /// Every known code gets an entry, so `state(of:)` never has to fall back to the
    /// disk. Settings asks it for every language on every redraw — including each
    /// keystroke in the search field — and a stat per row per frame is a cost with
    /// nothing to show for it, since only this class ever changes what is there.
    func refresh() {
        for pack in TesseractLanguagePacks.all {
            states[pack.code] = TessdataFiles.isInstalled(pack.code) ? .ready : .missing
        }
    }

    func state(of code: String) -> State { states[code] ?? .missing }

    var installedCodes: [String] {
        TesseractLanguagePacks.all.map(\.code).filter { state(of: $0) == .ready }
    }

    /// The model file, fetching it first if it is not here yet. Callers awaiting the
    /// same language wait on one download.
    @discardableResult
    func ensure(_ code: String) async throws -> URL {
        if TessdataFiles.isInstalled(code) {
            states[code] = .ready
            return TessdataFiles.fileURL(for: code)
        }
        if let existing = inFlight[code] { return try await existing.value }

        let task = Task { try await Self.fetch(code) }
        inFlight[code] = task
        states[code] = .downloading
        defer { inFlight[code] = nil }
        do {
            let url = try await task.value
            states[code] = .ready
            Log.ocr.info("Installed the \(code, privacy: .public) language pack")
            return url
        } catch {
            let offline = Self.isOffline(error)
            states[code] = .failed(error.localizedDescription, offline: offline)
            Log.ocr.error("Language pack \(code, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Starts a download for Settings, where the result is the changing state rather
    /// than a return value.
    func download(_ code: String) {
        Task { try? await ensure(code) }
    }

    func remove(_ code: String) {
        try? FileManager.default.removeItem(at: TessdataFiles.fileURL(for: code))
        states[code] = .missing
    }

    /// What this means for routing. `nil` for a language Cue has no pack for.
    func availability(for language: OCRLanguage) -> OCREngineAvailability {
        guard let code = language.tesseractCode,
              let pack = TesseractLanguagePacks.pack(forCode: code) else { return .unsupported }
        switch state(of: code) {
        case .ready: return .ready
        case .downloading: return .downloading
        case .missing: return .needsDownload(bytes: pack.bytes)
        case .failed(let message, let offline): return .failed(message, offline: offline)
        }
    }

    // MARK: - Fetching

    private static func fetch(_ code: String) async throws -> URL {
        guard let pack = TesseractLanguagePacks.pack(forCode: code),
              let source = TesseractLanguagePacks.downloadURL(for: code)
        else { throw PackError.unknownLanguage(code) }

        // One request for the whole file. These are a few megabytes and arrive in
        // seconds, so Settings shows an indeterminate indicator rather than paying
        // for byte-level progress.
        let (data, response) = try await URLSession.shared.data(from: source)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PackError.http(http.statusCode)
        }

        guard data.count == pack.bytes else { throw PackError.wrongSize(expected: pack.bytes, got: data.count) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == pack.sha256 else { throw PackError.wrongDigest }

        // Write beside the destination, then rename: an interrupted write can never
        // leave a half-finished model where Tesseract would try to load one.
        let destination = TessdataFiles.fileURL(for: code)
        let partial = TessdataFiles.folder.appendingPathComponent(".\(code).\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: TessdataFiles.folder, withIntermediateDirectories: true)
        try data.write(to: partial, options: .atomic)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    private static func isOffline(_ error: any Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                .cannotConnectToHost, .timedOut, .dataNotAllowed].contains(url.code)
    }

    enum PackError: Error, LocalizedError {
        case unknownLanguage(String)
        case http(Int)
        case wrongSize(expected: Int, got: Int)
        case wrongDigest

        var errorDescription: String? {
            switch self {
            case .unknownLanguage(let code): "Cue has no language pack called \(code)."
            case .http(let status): "The download server answered \(status)."
            case .wrongSize(let expected, let got): "The download was \(got) bytes, not \(expected)."
            case .wrongDigest: "The download didn't match its checksum."
            }
        }
    }
}
