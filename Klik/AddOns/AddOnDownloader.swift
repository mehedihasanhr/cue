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
        let suffix = release.installer == .package ? "pkg" : "dmg"
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
            return try await fetch(release, progress: progress)
        } catch let error as AddOnError {
            throw error
        } catch {
            throw .launchFailed(error.localizedDescription)
        }
    }

    private func fetch(_ release: AddOnRelease,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: AddOnDownloads.folder, withIntermediateDirectories: true)
        AddOnDownloads.sweepPartials()

        let (bytes, response) = try await URLSession.shared.bytes(from: release.download)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddOnError.http(http.statusCode)
        }

        let partial = AddOnDownloads.folder.appendingPathComponent("\(release.id).\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            throw AddOnError.launchFailed("couldn't write to \(partial.lastPathComponent)")
        }
        defer { try? handle.close() }

        // Hash as the bytes arrive: the file is never read back to verify it, so a
        // multi-hundred-megabyte download is never resident in memory.
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if release.bytes > 0 { progress(Double(written) / Double(release.bytes)) }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            written += buffer.count
        }
        try handle.close()
        progress(1)

        guard written == release.bytes else {
            try? FileManager.default.removeItem(at: partial)
            throw AddOnError.wrongSize(expected: release.bytes, got: written)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: partial)
            throw AddOnError.wrongDigest
        }

        let destination = AddOnDownloads.fileURL(for: release)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }
}
