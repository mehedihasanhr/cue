import Foundation
import UniformTypeIdentifiers

/// What can go wrong talking to Google, worded for the person reading Settings.
nonisolated enum DriveError: LocalizedError, Equatable {
    case notConfigured
    case signedOut
    case missingDriveScope
    case quotaExceeded
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "This build has no Google client ID."
        case .signedOut: "Google Drive was disconnected. Connect it again in Settings \u{203A} Storage."
        case .missingDriveScope: "Klik Studio needs permission to add files to your Drive. Connect again and leave the Drive box ticked."
        case .quotaExceeded: "Your Google Drive is full."
        case let .http(status, message): status > 0 ? "\(message) (\(status))" : message
        }
    }

    /// Worth trying again by itself: the network, or Google having a bad minute.
    var isTransient: Bool {
        if case let .http(status, _) = self { return status == 0 || status == 429 || status >= 500 }
        return false
    }
}

/// The Drive v3 calls a backup needs: folders, and resumable uploads.
///
/// An actor so the file reading and the waiting both happen off the main thread. Tokens
/// come from `token`, which the main actor owns; a 401 asks it for a fresh one, once.
actor GoogleDrive {
    typealias TokenSource = @Sendable @MainActor (_ forceRefresh: Bool) async throws -> String

    static let folderMIME = "application/vnd.google-apps.folder"
    /// 8 MiB: a multiple of the 256 KiB Google requires, large enough that a long take is
    /// not thousands of requests, small enough that a dropped one costs seconds.
    static let chunkSize = 8 * 1024 * 1024

    private let token: TokenSource
    private let session: URLSession

    init(token: @escaping TokenSource, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    struct Item: Decodable, Sendable {
        let id: String
        var webViewLink: String?
        var trashed: Bool?
    }

    // MARK: - Folders

    /// The folder `id`, if it is still there and not in the Trash.
    func folder(_ id: String) async throws -> Item? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        components.queryItems = [URLQueryItem(name: "fields", value: "id,webViewLink,trashed")]
        do {
            let item: Item = try await json(URLRequest(url: components.url!))
            return item.trashed == true ? nil : item
        } catch DriveError.http(404, _) {
            return nil
        }
    }

    /// A folder this app made with `name` in `parent`, if there is one.
    ///
    /// `drive.file` only shows the app's own files, so this cannot find — or adopt — a
    /// folder of the same name the user made by hand.
    func findFolder(named name: String, in parent: String) async throws -> Item? {
        struct List: Decodable { let files: [Item] }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "name = '\(escaped)' and mimeType = '\(Self.folderMIME)' and '\(parent)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,webViewLink)"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        let list: List = try await json(URLRequest(url: components.url!))
        return list.files.first
    }

    func createFolder(named name: String, in parent: String) async throws -> Item {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id,webViewLink")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderMIME, "parents": [parent]])
        return try await json(request)
    }

    func rename(_ id: String, to name: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=id")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let _: Item = try await json(request)
    }

    // MARK: - Uploading

    /// Uploads `file` into `parent`, or over `existing` when given — a new revision of the
    /// same Drive file, so a link to it keeps working. Returns the Drive file's ID.
    ///
    /// Resumable and in chunks, so a long recording is never in memory whole, progress can
    /// be shown, and a dropped connection costs one chunk rather than the file.
    func upload(_ file: URL, named name: String, in parent: String, replacing existing: String?,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let size = try Int64(file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let location: URL
        do {
            location = try await startUpload(name: name, parent: parent, replacing: existing, size: size, of: file)
        } catch DriveError.http(404, _) where existing != nil {
            // The old copy was deleted in Drive. A new one, then.
            location = try await startUpload(name: name, parent: parent, replacing: nil, size: size, of: file)
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var failures = 0
        while true {
            try Task.checkCancellation()
            let length = Int(min(Int64(Self.chunkSize), size - offset))
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: length) ?? Data()

            var request = URLRequest(url: location)
            request.httpMethod = "PUT"
            request.setValue(ResumableRange.contentRange(offset: offset, length: Int64(chunk.count), total: size),
                             forHTTPHeaderField: "Content-Range")
            do {
                let (data, response) = try await session.upload(for: request, from: chunk)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200, 201:
                    progress(size)
                    struct Done: Decodable { let id: String }
                    return try JSONDecoder().decode(Done.self, from: data).id
                case 308:
                    offset = ResumableRange.nextOffset(from: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"))
                    failures = 0
                    progress(offset)
                default:
                    throw Self.error(status: status, data: data)
                }
            } catch let error as DriveError where !error.isTransient {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The network, or a 5xx: ask Google how much it has, and carry on from there.
                failures += 1
                guard failures <= 3 else { throw error as? DriveError ?? DriveError.http(0, error.localizedDescription) }
                try await Task.sleep(for: .seconds(Double(1 << failures)))
                offset = try await received(at: location, total: size)
                progress(offset)
            }
        }
    }

    private func startUpload(name: String, parent: String, replacing existing: String?, size: Int64, of file: URL) async throws -> URL {
        let url: URL
        var metadata: [String: Any] = [:]
        if let existing {
            url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(existing)?uploadType=resumable&fields=id")!
        } else {
            url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!
            metadata = ["name": name, "parents": [parent]]
        }
        var request = URLRequest(url: url)
        request.httpMethod = existing == nil ? "POST" : "PATCH"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.mimeType(of: file), forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (_, response) = try await send(request)
        guard let location = response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw DriveError.http(response.statusCode, "Google Drive did not start the upload.")
        }
        return location
    }

    /// How much of an interrupted upload Google has.
    private func received(at location: URL, total: Int64) async throws -> Int64 {
        var request = URLRequest(url: location)
        request.httpMethod = "PUT"
        request.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (data, response) = try await session.upload(for: request, from: Data())
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 308: return ResumableRange.nextOffset(from: http?.value(forHTTPHeaderField: "Range"))
        case 200, 201: return total
        case let status: throw Self.error(status: status, data: data)
        }
    }

    // MARK: - Requests

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Sends `request` with a bearer token; on a 401, once more with a fresh one.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var forceRefresh = false
        while true {
            var authorized = request
            authorized.setValue("Bearer \(try await token(forceRefresh))", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: authorized)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DriveError.http(0, error.localizedDescription)
            }
            let http = response as! HTTPURLResponse
            if http.statusCode == 401, !forceRefresh {
                forceRefresh = true
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }
            return (data, http)
        }
    }

    static func error(status: Int, data: Data) -> DriveError {
        if status == 401 { return .signedOut }
        if status == 403, let text = String(data: data, encoding: .utf8), text.contains("storageQuotaExceeded") {
            return .quotaExceeded
        }
        return .http(status, GoogleOAuth.message(in: data) ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized)
    }

    static func mimeType(of file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// The arithmetic of a resumable upload's headers.
nonisolated enum ResumableRange {
    /// `Content-Range` for the chunk at `offset`: inclusive at both ends, as HTTP has it.
    static func contentRange(offset: Int64, length: Int64, total: Int64) -> String {
        guard length > 0 else { return "bytes */\(total)" }
        return "bytes \(offset)-\(offset + length - 1)/\(total)"
    }

    /// Where to carry on from, given the `Range: bytes=0-N` of a 308. No header means
    /// Google has nothing yet.
    static func nextOffset(from range: String?) -> Int64 {
        guard let range, let last = range.split(separator: "-").last, let end = Int64(last) else { return 0 }
        return end + 1
    }
}
