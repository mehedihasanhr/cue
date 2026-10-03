import CryptoKit
import Foundation

/// Fetching a published add-on release and proving it is what the catalogue promised.
@MainActor
protocol AddOnDownloading {
    /// Downloads `release` and returns the verified file, in Klik's own container.
    func download(_ release: AddOnRelease,
                  progress: @escaping @MainActor (Double) -> Void) async throws(AddOnError) -> URL
}

/// Where downloaded installers wait to be opened.
///
/// Inside the sandbox container, beside the language models — never in the app bundle,
/// which is code-signed and sealed, and never somewhere the user has to find.
nonisolated enum AddOnDownloads {
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Klik/AddOns", isDirectory: true)
    }()

    static func fileURL(for release: AddOnRelease) -> URL {
        let suffix = switch release.installer {
        case .archive: "aar"
        case .package: "pkg"
        case .diskImage: "dmg"
        }
        return folder.appendingPathComponent("\(release.addOn)-\(release.version).\(suffix)")
    }

    /// Removes what a crashed or cancelled download left behind.
    static func sweepPartials() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The real downloader: `URLSession` to a file, then length, then digest.
///
/// Byte-level progress is reported, unlike the language packs, because an installer is
/// tens of megabytes rather than a few and an indeterminate spinner for that long reads
/// as a hang.
@MainActor
final class URLSessionAddOnDownloader: NSObject, AddOnDownloading {
    func download(_ release: AddOnRelease,
                  progress: @escaping @MainActor (Double) -> Void) async throws(AddOnError) -> URL {
        do {
            do {
                return try await fetch(release, progress: progress)
            } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
                // Once more, from the start: a connection dropped part way through a
                // download from GitHub's CDN is usually fine the second time.
                return try await fetch(release, progress: progress)
            }
        } catch let error as AddOnError {
            throw error
        } catch let error as URLError {
            throw .downloadFailed(error.localizedDescription)
        } catch {
            throw .installFailed(error.localizedDescription)
        }
    }

    private func fetch(_ release: AddOnRelease,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: AddOnDownloads.folder, withIntermediateDirectories: true)
        AddOnDownloads.sweepPartials()

        // A download task to a file, with the session's own progress. It replaced reading
        // the response a byte at a time, which managed a few hundred kilobytes a second
        // even from this machine — half a minute for an add-on of a few megabytes.
        let watcher = DownloadProgress(progress)
        let (temporary, response) = try await URLSession.shared.download(from: release.download, delegate: watcher)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw AddOnError.http(http.statusCode)
        }
        let partial = AddOnDownloads.folder.appendingPathComponent("\(release.id).\(UUID().uuidString).partial")
        try FileManager.default.moveItem(at: temporary, to: partial)
        progress(1)

        let written = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard written == release.bytes else {
            try? FileManager.default.removeItem(at: partial)
            throw AddOnError.wrongSize(expected: release.bytes, got: written)
        }
        let digest = try await Self.sha256(of: partial)
        guard digest == release.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: partial)
            throw AddOnError.wrongDigest
        }

        let destination = AddOnDownloads.fileURL(for: release)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// The file's digest, read a megabyte at a time off the main thread, so a large
    /// download is never resident in memory at once.
    private static func sha256(of file: URL) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// Passes a download task's progress on, as a fraction, on the main actor.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @MainActor (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @MainActor (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in report(fraction) }
        }
    }
}
