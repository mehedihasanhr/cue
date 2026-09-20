import AppKit
import CryptoKit
import Foundation
import os

/// Where "Copy Share Link" sends a capture: an S3-compatible bucket (AWS S3,
/// Cloudflare R2, MinIO, Backblaze B2…) signed on-device, or any HTTP endpoint that
/// takes the PNG and answers with (or is) its URL. Keys and secrets live in the
/// Keychain; the rest in UserDefaults.
@Observable
@MainActor
final class ShareSettings {
    enum Provider: String, CaseIterable {
        case off, s3, custom

        var title: String {
            switch self {
            case .off: "Off"
            case .s3: "S3-compatible bucket"
            case .custom: "Custom endpoint"
            }
        }
    }

    enum Method: String, CaseIterable { case put = "PUT", post = "POST" }

    var provider: Provider { didSet { defaults.set(provider.rawValue, forKey: "share.provider") } }
    // S3
    var endpoint: String { didSet { defaults.set(endpoint, forKey: "share.s3.endpoint") } }
    var region: String { didSet { defaults.set(region, forKey: "share.s3.region") } }
    var bucket: String { didSet { defaults.set(bucket, forKey: "share.s3.bucket") } }
    var prefix: String { didSet { defaults.set(prefix, forKey: "share.s3.prefix") } }
    var accessKey: String { didSet { defaults.set(accessKey, forKey: "share.s3.accessKey") } }
    var secretKey: String { didSet { Keychain.set(secretKey, for: "share.s3.secretKey") } }
    /// What to put before the key in the link ("https://cdn.example.com"); empty
    /// means the bucket's own URL on the endpoint.
    var publicBase: String { didSet { defaults.set(publicBase, forKey: "share.s3.publicBase") } }
    // Custom
    var customURL: String { didSet { defaults.set(customURL, forKey: "share.custom.url") } }
    var customMethod: Method { didSet { defaults.set(customMethod.rawValue, forKey: "share.custom.method") } }
    var customHeaderName: String { didSet { defaults.set(customHeaderName, forKey: "share.custom.headerName") } }
    var customHeaderValue: String { didSet { Keychain.set(customHeaderValue, for: "share.custom.headerValue") } }
    /// For a JSON answer, the key holding the link ("url", "data.link"); empty: the
    /// body is the link, or the request URL when the body is empty.
    var customResponseKey: String { didSet { defaults.set(customResponseKey, forKey: "share.custom.responseKey") } }
    /// Names uploads by their capture time; off: a short random name.
    var datedNames: Bool { didSet { defaults.set(datedNames, forKey: "share.datedNames") } }

    private let defaults = UserDefaults.standard

    init() {
        provider = Provider(rawValue: defaults.string(forKey: "share.provider") ?? "") ?? .off
        endpoint = defaults.string(forKey: "share.s3.endpoint") ?? ""
        region = defaults.string(forKey: "share.s3.region") ?? "auto"
        bucket = defaults.string(forKey: "share.s3.bucket") ?? ""
        prefix = defaults.string(forKey: "share.s3.prefix") ?? "klik/"
        accessKey = defaults.string(forKey: "share.s3.accessKey") ?? ""
        secretKey = Keychain.get("share.s3.secretKey") ?? ""
        publicBase = defaults.string(forKey: "share.s3.publicBase") ?? ""
        customURL = defaults.string(forKey: "share.custom.url") ?? ""
        customMethod = Method(rawValue: defaults.string(forKey: "share.custom.method") ?? "") ?? .put
        customHeaderName = defaults.string(forKey: "share.custom.headerName") ?? "Authorization"
        customHeaderValue = Keychain.get("share.custom.headerValue") ?? ""
        customResponseKey = defaults.string(forKey: "share.custom.responseKey") ?? ""
        datedNames = defaults.object(forKey: "share.datedNames") as? Bool ?? true
    }

    var isConfigured: Bool {
        switch provider {
        case .off: false
        case .s3: !endpoint.isEmpty && !bucket.isEmpty && !accessKey.isEmpty && !secretKey.isEmpty
        case .custom: URL(string: customURL) != nil && !customURL.isEmpty
        }
    }

    /// The object name for an upload.
    func objectName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = datedNames ? formatter.string(from: date) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
                              : String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        return stem + ".png"
    }
}

/// The upload itself.
enum ShareUploader {
    enum Failure: LocalizedError {
        case notConfigured, badEndpoint, http(Int, String), noLink

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Set up sharing in Settings › Sharing first."
            case .badEndpoint: "The endpoint URL is not valid."
            case .http(let code, let body): "The server answered \(code)\(body.isEmpty ? "" : ": \(body.prefix(120))")."
            case .noLink: "The server did not return a link."
            }
        }
    }

    /// Uploads the PNG and returns the public link.
    static func upload(_ png: Data, name: String, settings: ShareSettings) async throws -> URL {
        guard settings.isConfigured else { throw Failure.notConfigured }
        switch settings.provider {
        case .off: throw Failure.notConfigured
        case .s3: return try await uploadS3(png, name: name, settings: settings)
        case .custom: return try await uploadCustom(png, name: name, settings: settings)
        }
    }

    // MARK: - S3 (SigV4, path-style)

    private static func uploadS3(_ png: Data, name: String, settings: ShareSettings) async throws -> URL {
        var host = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = (settings.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "/" + settings.bucket + "/" + key
        guard !host.isEmpty, let url = URL(string: "https://" + host + path) else { throw Failure.badEndpoint }

        let now = Date()
        let stamp = DateFormatter(); stamp.timeZone = TimeZone(identifier: "UTC"); stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = stamp.string(from: now)
        let dateOnly = String(amzDate.prefix(8))
        let region = settings.region.isEmpty ? "auto" : settings.region
        let payloadHash = hex(SHA256.hash(data: png))
        let canonicalHeaders = "content-type:image/png\nhost:\(host)\nx-amz-acl:public-read\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "content-type;host;x-amz-acl;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = ["PUT", uriEncode(path, keepSlashes: true), "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(dateOnly)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        var signingKey = hmac(Data(("AWS4" + settings.secretKey).utf8), dateOnly)
        signingKey = hmac(signingKey, region)
        signingKey = hmac(signingKey, "s3")
        signingKey = hmac(signingKey, "aws4_request")
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: signingKey)))

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(settings.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.upload(for: request, from: png)
        try check(response, body)

        let base = settings.publicBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !base.isEmpty, let link = URL(string: base + "/" + key) { return link }
        return url
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func uriEncode(_ string: String, keepSlashes: Bool) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        if keepSlashes { allowed.insert("/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: - Custom endpoint

    private static func uploadCustom(_ png: Data, name: String, settings: ShareSettings) async throws -> URL {
        guard var url = URL(string: settings.customURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Failure.badEndpoint }
        // "{name}" in the URL takes the file name; a PUT without it gets the name appended.
        if url.absoluteString.contains("{name}") {
            url = URL(string: url.absoluteString.replacingOccurrences(of: "{name}", with: name)) ?? url
        } else if settings.customMethod == .put, url.pathExtension.isEmpty {
            url = url.appendingPathComponent(name)
        }
        var request = URLRequest(url: url)
        request.httpMethod = settings.customMethod.rawValue
        if !settings.customHeaderName.isEmpty, !settings.customHeaderValue.isEmpty {
            request.setValue(settings.customHeaderValue, forHTTPHeaderField: settings.customHeaderName)
        }
        let body: Data
        if settings.customMethod == .post {
            let boundary = "klik-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var form = Data()
            form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: image/png\r\n\r\n".utf8))
            form.append(png)
            form.append(Data("\r\n--\(boundary)--\r\n".utf8))
            body = form
        } else {
            request.setValue("image/png", forHTTPHeaderField: "Content-Type")
            body = png
        }
        let (answer, response) = try await URLSession.shared.upload(for: request, from: body)
        try check(response, answer)
        return try link(from: answer, request: url, key: settings.customResponseKey)
    }

    private static func link(from body: Data, request: URL, key: String) throws -> URL {
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty, let json = try? JSONSerialization.jsonObject(with: body) {
            var node: Any? = json
            for part in key.split(separator: ".") { node = (node as? [String: Any])?[String(part)] }
            if let string = node as? String, let url = URL(string: string) { return url }
            throw Failure.noLink
        }
        if text.isEmpty { return request }
        if let url = URL(string: text), url.scheme != nil { return url }
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for candidate in ["url", "link", "href"] { if let string = json[candidate] as? String, let url = URL(string: string) { return url } }
        }
        throw Failure.noLink
    }

    private static func check(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: body, encoding: .utf8) ?? "")
        }
    }
}

/// The few secrets sharing needs, in the login keychain under Klik's name.
enum Keychain {
    private static let service = "com.stackrover.klik"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Log.app.error("Keychain write failed: \(status)") }
    }
}
