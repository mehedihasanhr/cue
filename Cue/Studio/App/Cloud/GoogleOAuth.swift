import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Signing in to Google, as an installed app: the authorization-code flow with PKCE.
///
/// The client is Google's "iOS" type, which is the one its own Mac sign-in uses. It has
/// no secret — an app's secret is not one, since anybody can read it out of the bundle —
/// and Google lets it come back on the reversed client ID as a URL scheme, which
/// `ASWebAuthenticationSession` catches itself. So there is no scheme to register and no
/// loopback server for the sandbox to allow.
///
/// The only Drive scope asked for is `drive.file`: the app sees the files it made and
/// nothing else in the user's Drive, which is all a backup needs and is the scope Google
/// does not make an app pass a security review for.
nonisolated struct GoogleOAuth: Sendable {
    let clientID: String

    static let scopes = ["openid", "email", "https://www.googleapis.com/auth/drive.file"]
    static let driveScope = "https://www.googleapis.com/auth/drive.file"

    /// The client ID from `Config/Google.xcconfig`, by way of the Info.plist; nil when this
    /// build was made without one.
    static var configured: GoogleOAuth? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CueGoogleClientID") as? String else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), !id.contains("$(") else { return nil }
        return GoogleOAuth(clientID: id)
    }

    /// `com.googleusercontent.apps.<id>` — the client ID back to front, which is the scheme
    /// Google sends an iOS-type client's answer to.
    var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    func authorizeURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Asked every time, so connecting again after a disconnect still comes back
            // with a refresh token — Google only sends one with a consent.
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        return components.url!
    }

    // MARK: - Tokens

    struct Tokens: Sendable, Equatable {
        var accessToken: String
        var expiresAt: Date
        var refreshToken: String?
        var email: String?
        var scopes: Set<String>
    }

    /// Google's token response.
    static func parseTokens(_ data: Data, now: Date = .now) throws -> Tokens {
        struct Response: Decodable {
            let access_token: String
            let expires_in: Double?
            let refresh_token: String?
            let id_token: String?
            let scope: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return Tokens(accessToken: response.access_token,
                      expiresAt: now.addingTimeInterval(response.expires_in ?? 3600),
                      refreshToken: response.refresh_token,
                      email: response.id_token.flatMap(email(fromIDToken:)),
                      scopes: Set((response.scope ?? "").split(separator: " ").map(String.init)))
    }

    /// The address in an ID token. Read, not verified: the token came straight from
    /// Google over TLS in answer to this app's own request, and the address is only shown.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URL: String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }

    func exchange(code: String, pkce: PKCE) async throws -> Tokens {
        try await tokenRequest(["code": code,
                                "client_id": clientID,
                                "redirect_uri": redirectURI,
                                "grant_type": "authorization_code",
                                "code_verifier": pkce.verifier])
    }

    func refresh(_ refreshToken: String) async throws -> Tokens {
        try await tokenRequest(["client_id": clientID,
                                "refresh_token": refreshToken,
                                "grant_type": "refresh_token"])
    }

    /// Tells Google to forget the grant. Best effort: disconnecting goes ahead locally
    /// whether or not Google could be reached.
    func revoke(_ token: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // `invalid_grant` is a refresh token Google no longer honours: revoked from the
            // account page, or expired. Nothing to retry — the user has to connect again.
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               body["error"] as? String == "invalid_grant" {
                throw DriveError.signedOut
            }
            throw DriveError.http(status, Self.message(in: data) ?? "Google refused the sign-in.")
        }
        return try Self.parseTokens(data)
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    static func message(in data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = body["error"] as? [String: Any] { return error["message"] as? String }
        return body["error_description"] as? String ?? body["error"] as? String
    }
}

// MARK: - Signing in

extension GoogleOAuth {
    /// Shows Google's sign-in and comes back with tokens. Throws `CancellationError` when
    /// the user closes it.
    @MainActor
    func signIn() async throws -> Tokens {
        let pkce = PKCE.random()
        let state = PKCE.random().verifier
        let url = authorizeURL(pkce: pkce, state: state)
        let scheme = callbackScheme

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? DriveError.http(0, "Google sign-in did not finish."))
                }
            }
            session.presentationContextProvider = SignInAnchor.shared
            session.prefersEphemeralWebBrowserSession = false
            SignInAnchor.shared.session = session
            if !session.start() {
                continuation.resume(throwing: DriveError.http(0, "Google sign-in could not be shown."))
            }
        }
        SignInAnchor.shared.session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw CancellationError() }
            throw DriveError.http(0, "Google said: \(error)")
        }
        guard value("state") == state else { throw DriveError.http(0, "The sign-in answer did not match the request.") }
        guard let code = value("code") else { throw DriveError.http(0, "Google sent no sign-in code.") }

        let tokens = try await exchange(code: code, pkce: pkce)
        // Google's consent screen lets each scope be unticked. Without Drive there is
        // nothing to store into, and saying so now beats a 403 on the first upload.
        guard tokens.scopes.contains(Self.driveScope) else { throw DriveError.missingDriveScope }
        return tokens
    }
}

/// The window the sign-in sheet hangs from, and the session kept alive while it runs.
@MainActor
private final class SignInAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SignInAnchor()
    var session: ASWebAuthenticationSession?

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}

// MARK: - PKCE

/// RFC 7636: a random verifier, and the SHA-256 of it the request carries instead.
nonisolated struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    static func random() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCE(verifier: Data(bytes).base64URLEncoded)
    }
}

nonisolated extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
