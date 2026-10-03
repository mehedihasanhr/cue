import os
import AppKit
import Foundation
import Security

/// Finding an installed add-on.
///
/// A protocol because everything above it — the registry, the Settings pane, the
/// recording client — needs to be testable without an app installed on the machine
/// running the tests.
@MainActor
protocol AddOnLocating {
    func locate(_ addOn: AddOn) -> InstalledAddOn?
}

/// Asks LaunchServices where the add-on is, then asks the code signature whether to
/// believe it.
///
/// Discovery is by bundle identifier rather than by path: the user installs the add-on
/// the ordinary way (drag to Applications, or an installer package), so Klik has no say
/// in where it lands and no business guessing.
@MainActor
struct LaunchServicesAddOnLocator: AddOnLocating {
    /// A copy the user pointed Klik at, used in preference to whatever LaunchServices
    /// knows about. For developing the add-on, and for anyone who keeps applications
    /// somewhere unusual. It is signature-checked like any other copy.
    var localBuild: URL?

    init(localBuild: URL? = nil) {
        self.localBuild = localBuild
    }

    func locate(_ addOn: AddOn) -> InstalledAddOn? {
        // A copy the user chose is the answer, readable or not: when it can't be used,
        // they need to hear why.
        if let localBuild {
            guard let version = Self.version(at: localBuild) else {
                Log.addOns.error("\(addOn.bundleID, privacy: .public) at \(localBuild.path, privacy: .public) has no readable version")
                return InstalledAddOn(url: localBuild, version: SemanticVersion(0), untrustedReason: "no version")
            }
            return InstalledAddOn(url: localBuild, version: version, untrustedReason: Self.untrustedReason(for: localBuild))
        }

        // Otherwise the newest copy Klik can read, of every copy LaunchServices knows.
        // Asking for just one handed back whichever it liked — a build in a developer
        // folder, say — which the sandbox will not let Klik read, so the add-on showed
        // as untrusted and Install was never offered. A copy Klik cannot read is one it
        // cannot use either, so it is passed over rather than reported.
        // One in the Trash is not installed, though LaunchServices keeps it on the list
        // and macOS refuses to open it from there.
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: addOn.bundleID)
        let readable = (known + Self.placed(addOn))
            .filter { !$0.pathComponents.contains(".Trash") }
            .compactMap { url in Self.version(at: url).map { (url: url, version: $0) } }
        guard let newest = readable.max(by: { $0.version < $1.version }) else { return nil }
        return InstalledAddOn(url: newest.url, version: newest.version, untrustedReason: Self.untrustedReason(for: newest.url))
    }

    /// Where Klik itself installed an add-on this session. The process that does the
    /// installing goes on getting LaunchServices' old answer for a while — a newly placed
    /// copy is missing from it for seconds — so Settings went back to offering Install
    /// with the app sitting in Applications.
    static var placedCopies: [String: URL] = [:]

    private static func placed(_ addOn: AddOn) -> [URL] {
        guard let url = placedCopies[addOn.bundleID],
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return [url]
    }

    private static func version(at url: URL) -> SemanticVersion? {
        (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(SemanticVersion.init)
    }

    /// Why this bundle should not be trusted, or `nil` when it should be.
    ///
    /// Bundle identifiers are a naming convention, not a credential: anything can claim
    /// `com.stackrover.klik.studio`. The signature is what makes it the add-on, so the
    /// team identifier has to match Klik's own before the host will talk to it.
    ///
    /// A host with no team identifier is a local development build (an ad-hoc or
    /// self-signed signature carries none). There is nothing to match against, so the
    /// check is logged and skipped — refusing here would make the add-on untestable on
    /// exactly the builds it is developed against.
    static func untrustedReason(for url: URL) -> String? {
        guard let hostTeam = teamIdentifier(ofSelf: ()) else {
            Log.addOns.notice("Unsigned host build: skipping the add-on team check for \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return "unreadable signature"
        }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        guard validity == errSecSuccess else { return "invalid signature (\(validity))" }

        guard let team = teamIdentifier(of: code) else { return "no team identifier" }
        guard team == hostTeam else { return "signed by \(team)" }
        return nil
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Klik's own team identifier, or `nil` when this build has none.
    ///
    /// The unused parameter keeps the name distinct from the `SecStaticCode` overload
    /// above without inventing a second verb for the same question.
    private static func teamIdentifier(ofSelf _: Void) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var statik: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &statik) == errSecSuccess, let statik else { return nil }
        return teamIdentifier(of: statik)
    }
}
