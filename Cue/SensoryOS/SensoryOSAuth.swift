import AppKit
import AuthenticationServices
import Foundation
import os
import Security

/// Signing in to Sensory OS, the way its own website signs people in: with Supabase
/// Auth, by Google (PKCE) or by email and password. Cue is just another client of the
/// project's sign-in, so nothing needs registering and no consent page is involved.
///
/// Nothing about the server is built in but its address. Cue reads where the sign-in
/// server is from the site (`/api/desktop/v1/config`). Google's answer comes back to an
/// https page on the site that passes it on to `cue://oauth/sensory-os`
/// (docs/integrations/cue-desktop.md in Sensory OS), which the system sign-in sheet
/// catches — or, signed in from a browser, Cue's URL handler.
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

/// The site's sign-in server, as `/api/desktop/v1/config` describes it. Both values are
/// public: they are in every page the site serves.
nonisolated struct SOSAuthConfig: Codable, Sendable, Equatable {
    /// The Supabase project, `https://<ref>.supabase.co`.
    var url: URL
    /// Its publishable key, sent as `apikey` with every sign-in call.
    var key: String
    /// The ways in the site offers: "google", "email".
    var providers: [String]

    var tokenEndpoint: URL { url.appendingPathComponent("auth/v1/token") }
    var offersGoogle: Bool { providers.contains("google") }
    var offersEmail: Bool { providers.contains("email") }
}

/// What is kept in the Keychain while connected.
nonisolated struct SOSTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    /// Supabase's `/auth/v1/token`, and the key it wants.
    var tokenEndpoint: URL
    var apiKey: String
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

/// The sign-in calls themselves, apart from any state.
nonisolated enum SOSAuth {
    /// Where this site signs people in. Read fresh each time: it is one small request,
    /// and a copy kept from before the site changed servers would sign in to the wrong one.
    static func config(_ server: SOSServer) async throws -> SOSAuthConfig {
        struct Answer: Decodable {
            struct Auth: Decodable { let url: URL; let key: String }
            let auth: Auth
            let providers: [String]?
        }
        let url = server.origin.appendingPathComponent("api/desktop/v1/config")
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw SOSAuthError.server("Couldn't reach \(server.origin.host ?? "Sensory OS"): \(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            if status == 404 { throw SOSAuthError.server("\(server.origin.host ?? "That address") doesn't have Cue sign-in yet.") }
            throw SOSAuthError.server(message(in: data) ?? "\(server.origin.host ?? "That address") is not a Sensory OS site Cue can sign in to (\(status)).")
        }
        return SOSAuthConfig(url: answer.auth.url, key: answer.auth.key, providers: answer.providers ?? ["google", "email"])
    }

    /// Supabase's Google sign-in, PKCE flavour: Google, then Supabase, then the site's
    /// callback page with `?code=…&state=…`. The state rides in the redirect address,
    /// which Supabase keeps when it adds the code.
    static func googleURL(_ config: SOSAuthConfig, server: SOSServer, pkce: PKCE, state: String) -> URL {
        var redirect = URLComponents(string: server.redirectURI)!
        redirect.queryItems = [URLQueryItem(name: "state", value: state)]
        var components = URLComponents(url: config.url.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: redirect.url!.absoluteString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    static func exchange(code: String, pkce: PKCE, config: SOSAuthConfig, server: SOSServer) async throws -> SOSTokens {
        try await token(grant: "pkce", ["auth_code": code, "code_verifier": pkce.verifier],
                        endpoint: config.tokenEndpoint, apiKey: config.key, origin: server.origin, keeping: nil)
    }

    static func password(email: String, password: String, config: SOSAuthConfig, server: SOSServer) async throws -> SOSTokens {
        try await token(grant: "password", ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password],
                        endpoint: config.tokenEndpoint, apiKey: config.key, origin: server.origin, keeping: nil)
    }

    static func refresh(_ tokens: SOSTokens) async throws -> SOSTokens {
        guard let refreshToken = tokens.refreshToken else { throw SOSAuthError.signedOut }
        return try await token(grant: "refresh_token", ["refresh_token": refreshToken],
                               endpoint: tokens.tokenEndpoint, apiKey: tokens.apiKey, origin: tokens.origin, keeping: refreshToken)
    }

    private static func token(grant: String, _ fields: [String: String], endpoint: URL, apiKey: String, origin: URL, keeping oldRefresh: String?) async throws -> SOSTokens {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A refused refresh token (signed out on the website, or expired): nothing to retry.
            if (400..<500).contains(status), grant == "refresh_token" { throw SOSAuthError.signedOut }
            if grant == "password", status == 400 { throw SOSAuthError.server(message(in: data) ?? "Invalid email or password.") }
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
                         expiresAt: .now.addingTimeInterval(answer.expires_in ?? 3600),
                         tokenEndpoint: endpoint, apiKey: apiKey, origin: origin)
    }

    static func message(in data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = body["error_description"] as? String ?? body["msg"] as? String ?? body["message"] as? String
            ?? (body["error"] as? String).map { "Sensory OS said: \($0)" }
        // Supabase's own wording for a wrong password.
        if text == "Invalid login credentials" { return "Invalid email or password." }
        return text
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

/// One Google sign-in in progress: what its answer must match, and who is waiting for it.
@MainActor
final class SOSSignIn {
    let server: SOSServer
    let config: SOSAuthConfig
    let pkce = PKCE.random()
    let state = PKCE.random().verifier
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: ASWebAuthenticationSession?

    init(server: SOSServer, config: SOSAuthConfig) {
        self.server = server
        self.config = config
    }

    var url: URL { SOSAuth.googleURL(config, server: server, pkce: pkce, state: state) }

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
            // macOS calls this on a background queue (an XPC reply), not the main thread:
            // the closure is @Sendable so it is not taken for main-actor code, and it hops.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SOSServer.callbackScheme) { @Sendable [weak self] url, error in
                let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let url { self?.finish(.success(url)) }
                    else if cancelled { self?.finish(.failure(SOSAuthError.cancelled)) }
                    else { self?.finish(.failure(SOSAuthError.server(message.map { "The sign-in window failed: \($0)" } ?? "Sign-in did not finish."))) }
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

    /// Gave up waiting: the person never finished, and the server's request has expired.
    func expire() {
        session?.cancel()
        finish(.failure(SOSAuthError.server("The sign-in wasn't finished in time. Try again.")))
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
        return try await SOSAuth.exchange(code: code, pkce: pkce, config: config, server: server)
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
