import Foundation

/// Passing a request between the two apps as a file.
///
/// The transport before the Mach service exists: the host writes a request, launches the
/// add-on with a `klik-studio://record?request=…` URL, and the add-on reads it back.
/// Both halves live here so neither app can drift from the other's spelling.
public enum RequestFile {
    /// Writes `request` into `folder` and returns the file.
    @discardableResult
    public static func write(_ request: RecordingRequest, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(request.correlationID.uuidString).json")
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
        return url
    }

    public static func read(at url: URL) throws -> RecordingRequest {
        try JSONDecoder().decode(RecordingRequest.self, from: Data(contentsOf: url))
    }

    /// The launch URL for a written request.
    public static func launchURL(for file: URL) -> URL? {
        var components = URLComponents()
        components.scheme = AddOnBridge.urlScheme
        components.host = "record"
        components.queryItems = [URLQueryItem(name: AddOnBridge.requestQueryItem,
                                              value: file.path(percentEncoded: false))]
        return components.url
    }

    /// The request file a launch URL points at, or `nil` when the URL is not one of ours.
    ///
    /// Anything can open a URL scheme, so this only ever yields a path — the add-on
    /// still decides whether to trust what it reads there.
    public static func file(from url: URL) -> URL? {
        guard url.scheme == AddOnBridge.urlScheme, url.host == "record",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == AddOnBridge.requestQueryItem })?.value,
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
