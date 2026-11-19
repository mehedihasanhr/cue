import AppKit
import AuthenticationServices
import Foundation
import os
import Security

/// Signing in to Sensory OS: OAuth 2.1 with PKCE against the Supabase OAuth server
/// Sensory OS runs (the one its MCP connector uses), as a public client.
///
/// Nothing about the server is built in but its address. Cue reads where to sign in
/// from the site's protected-resource metadata, registers itself with the
/// authorization server (dynamic client registration) the first time, and keeps the
/// client id. The redirect is an https page on the site that passes the answer on to
/// `cue://oauth/sensory-os` (docs/integrations/cue-desktop.md in Sensory OS), which the
/// system sign-in sheet catches — or, signed in from a browser, Cue's URL handler.
nonisolated struct SOSServer: Sendable, Equatable {
    /// The site: `https://os.sensory-creative.com`.
    let origin: URL

    static let production = URL(string: "https://os.sensory-creative.com")!

    var redirectURI: String { origin.appendingPathComponent("api/desktop/oauth/callback").absoluteString }
    static let callbackScheme = "cue"
    static let callbackHost = "oauth"
    static let callbackPath = "/sensory-os"

    /// `https://example.com/` → `https://example.com`; nil for anything but http(s).
    static func origin(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        // Plain http only for this Mac: a token never crosses a network unencrypted.
        if scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(host), !host.hasSuffix(".localhost") { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }
}

/// The authorization server, as its metadata describes it.
nonisolated struct SOSAuthServer: Codable, Sendable, Equatable {
    var issuer: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }
}

/// What is kept in the Keychain while connected.
nonisolated struct SOSTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var clientID: String
    var tokenEndpoint: URL
    var origin: URL

    /// Refreshed a little before it runs out, so a request never carries a dead one.
    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 120 }
}

nonisolated enum SOSAuthError: LocalizedError, Equatable {
    case notConnected
    case signedOut
    case server(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to Sensory OS."
        case .signedOut: "Sensory OS signed Cue out. Connect again."
        case .server(let message): message
        case .cancelled: "Sign-in was cancelled."
        }
    }
}

/// The OAuth calls themselves, apart from any state.
nonisolated enum SOSAuth {
    static let scopes = "openid email profile"

    static func discover(_ server: SOSServer) async throws -> SOSAuthServer {
        struct Resource: Decodable { let authorization_servers: [String]? }
        let resourceURL = server.origin.appendingPathComponent(".well-known/oauth-protected-resource")
        let (data, response) = try await URLSession.shared.data(from: resourceURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let issuer = (try? JSONDecoder().decode(Resource.self, from: data))?.authorization_servers?.first,
              let issuerURL = URL(string: issuer) else {
            throw SOSAuthError.server("\(server.origin.host ?? "That address") is not a Sensory OS site Cue can sign in to.")
        }
        // Supabase answers at <issuer>/.well-known/…; RFC 8414 puts the issuer's path after it.
        var candidates = [issuerURL.appendingPathComponent(".well-known/oauth-authorization-server")]
        if var components = URLComponents(url: issuerURL, resolvingAgainstBaseURL: false) {
            components.path = "/.well-known/oauth-authorization-server" + components.path
            if let url = components.url { candidates.append(url) }
        }
        for url in candidates {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let metadata = try? JSONDecoder().decode(SOSAuthServer.self, from: data) else { continue }
            return metadata
        }
        throw SOSAuthError.server("Sensory OS has sign-in for apps switched off on this server.")
    }

    /// The client id this Mac registered with this authorization server, registering
    /// once when there is none.
    static func clientID(for auth: SOSAuthServer, server: SOSServer, given: String = "") async throws -> String {
        // One an admin registered for Cue on the server, when it does not let apps register themselves.
        let given = given.trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        let key = "sensoryos.client.\(auth.issuer)|\(server.redirectURI)"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        guard let endpoint = auth.registrationEndpoint else {
            throw SOSAuthError.server("This server doesn't let apps register themselves. Add Cue as an OAuth app on it (redirect URL \(server.redirectURI), public client) and enter its client ID here.")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Cue",
            "redirect_uris": [server.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": scopes,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Registered: Decodable { let client_id: String }
        guard (200..<300).contains(status), let registered = try? JSONDecoder().decode(Registered.self, from: data) else {
            throw SOSAuthError.server(message(in: data) ?? "Sensory OS would not register Cue (\(status)).")
        }
        UserDefaults.standard.set(registered.client_id, forKey: key)
        return registered.client_id
    }

    static func authorizeURL(_ auth: SOSAuthServer, clientID: String, server: SOSServer, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: auth.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: server.redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    static func exchange(code: String, pkce: PKCE, clientID: String, auth: SOSAuthServer, server: SOSServer) async throws -> SOSTokens {
        try await tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": server.redirectURI,
                                "client_id": clientID, "code_verifier": pkce.verifier],
                               clientID: clientID, endpoint: auth.tokenEndpoint, origin: server.origin, keeping: nil)
    }

    static func refresh(_ tokens: SOSTokens) async throws -> SOSTokens {
        guard let refreshToken = tokens.refreshToken else { throw SOSAuthError.signedOut }
        return try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": tokens.clientID],
                                      clientID: tokens.clientID, endpoint: tokens.tokenEndpoint, origin: tokens.origin, keeping: refreshToken)
    }

    private static func tokenRequest(_ fields: [String: String], clientID: String, endpoint: URL, origin: URL, keeping oldRefresh: String?) async throws -> SOSTokens {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = GoogleOAuth.form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A refused refresh token (revoked from the website, or expired): nothing to retry.
            if (400..<500).contains(status), fields["grant_type"] == "refresh_token" { throw SOSAuthError.signedOut }
            throw SOSAuthError.server(message(in: data) ?? "Sensory OS refused the sign-in (\(status)).")
        }
        struct Answer: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw SOSAuthError.server("Sensory OS answered the sign-in with something Cue can't read.")
        }
        return SOSTokens(accessToken: answer.access_token, refreshToken: answer.refresh_token ?? oldRefresh,
                         expiresAt: .now.addingTimeInterval(answer.expires_in ?? 3600), clientID: clientID,
                         tokenEndpoint: endpoint, origin: origin)
    }

    static func message(in data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return body["error_description"] as? String ?? body["msg"] as? String ?? body["message"] as? String
            ?? (body["error"] as? String).map { "Sensory OS said: \($0)" }
    }
}

/// The tokens, in the login keychain rather than in defaults, where anything that can
/// read a plist could take them and act as the person.
nonisolated enum SOSKeychain {
    private static let service = "com.stackrover.cue.sensory-os"
    private static let account = "tokens"

    static func load() -> SOSTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SOSTokens.self, from: data)
    }

    @discardableResult
    static func save(_ tokens: SOSTokens?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return true }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// One sign-in in progress: what its answer must match, and who is waiting for it.
@MainActor
final class SOSSignIn {
    let server: SOSServer
    let auth: SOSAuthServer
    let clientID: String
    let pkce = PKCE.random()
    let state = PKCE.random().verifier
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: ASWebAuthenticationSession?

    init(server: SOSServer, auth: SOSAuthServer, clientID: String) {
        self.server = server
        self.auth = auth
        self.clientID = clientID
    }

    var url: URL { SOSAuth.authorizeURL(auth, clientID: clientID, server: server, pkce: pkce, state: state) }

    /// Whether an incoming `cue://` URL is this sign-in's answer.
    func matches(_ url: URL) -> Bool {
        guard url.scheme == SOSServer.callbackScheme, url.host == SOSServer.callbackHost, url.path == SOSServer.callbackPath else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value == state
    }

    /// Waits for the answer: from the system sign-in sheet (`sheet`), or from a browser
    /// the person (or a test) opened the URL in, by way of Cue's URL handler.
    func answer(sheet: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard sheet else { return }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SOSServer.callbackScheme) { [weak self] url, error in
                MainActor.assumeIsolated {
                    if let url { self?.finish(.success(url)) }
                    else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { self?.finish(.failure(SOSAuthError.cancelled)) }
                    else { self?.finish(.failure(error ?? SOSAuthError.server("Sign-in did not finish."))) }
                }
            }
            session.presentationContextProvider = SOSSignInAnchor.shared
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { finish(.failure(SOSAuthError.server("The sign-in window could not be shown."))) }
        }
    }

    /// The answer arrived through Cue's URL handler.
    func receive(_ url: URL) { finish(.success(url)) }

    func cancel() {
        session?.cancel()
        finish(.failure(SOSAuthError.cancelled))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }

    /// The code from the answer, checked against this sign-in, exchanged for tokens.
    func tokens(from callback: URL) async throws -> SOSTokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw SOSAuthError.cancelled }
            throw SOSAuthError.server(value("error_description") ?? "Sensory OS said: \(error)")
        }
        guard value("state") == state else { throw SOSAuthError.server("The sign-in answer did not match the request.") }
        guard let code = value("code") else { throw SOSAuthError.server("Sensory OS sent no sign-in code.") }
        return try await SOSAuth.exchange(code: code, pkce: pkce, clientID: clientID, auth: auth, server: server)
    }
}

@MainActor
private final class SOSSignInAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SOSSignInAnchor()

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}
