import AddOnKit
import Foundation

/// An optional feature that ships as its own application rather than inside Klik.
///
/// Klik stays small because the heavy features are not in it: recording drags in a
/// video encoder, a GPU renderer and a caption model, none of which a user who only
/// takes screenshots should download, launch or keep in memory. So an add-on is a
/// separate signed app, installed on request, and the host holds nothing but this
/// identity and a way to find it.
nonisolated struct AddOn: Sendable, Hashable, Identifiable {
    /// Stable across releases and used as the key everywhere — never the name.
    let id: String
    let bundleID: String
    let name: String
    /// One line, shown under the name in Settings.
    let summary: String
    /// An SF Symbol for the row.
    let symbol: String
    /// The oldest add-on release this build of Klik knows how to talk to. Bumped only
    /// when a contract changes in a way older add-ons cannot satisfy.
    let minimumSupported: SemanticVersion
}

/// How a downloaded release is installed.
///
/// `archive` is installed by Klik itself, into a folder the user grants it — see
/// `AddOnPlacer`. A disk image or a package is handed to macOS, which mounts it or runs
/// it for the user to finish.
nonisolated enum AddOnInstaller: String, Sendable, Codable {
    /// An Apple Archive (`.aar`) of the app, unpacked in-process. The one a sandboxed
    /// app can install on its own: it cannot mount an image or run an installer.
    case archive
    case diskImage
    case package
}

/// One published build of an add-on, as the catalogue feed describes it.
nonisolated struct AddOnRelease: Sendable, Hashable, Codable, Identifiable {
    let addOn: String
    let version: SemanticVersion
    let download: URL
    /// Exact length, checked before the digest so a truncated download fails fast.
    let bytes: Int
    /// SHA-256 of the downloaded file. A published release is immutable, so this is an
    /// assertion rather than a hope — the same contract as the Tesseract language packs.
    let sha256: String
    /// The oldest Klik this release works with, so a new add-on can refuse an old host.
    let minimumHost: SemanticVersion
    let installer: AddOnInstaller
    /// Optional release notes URL for the "What's new" link.
    let notes: URL?

    var id: String { "\(addOn)-\(version.description)" }
}

/// What Klik knows about add-ons without asking the network.
nonisolated enum AddOnCatalog {
    /// The recording and demo-video add-on: capture, timeline editing, zoom and cursor
    /// polish, export. Its bundle identifier is the handle everything else hangs off —
    /// discovery, the signature check and the XPC service name all derive from it.
    static let studio = AddOn(
        id: "studio",
        bundleID: AddOnBridge.studioBundleID,
        name: "Klik Studio",
        summary: "Screen recording, timeline editing, auto-zoom and video export",
        symbol: "record.circle",
        minimumSupported: SemanticVersion(1)
    )

    static let all: [AddOn] = [studio]

    static func addOn(id: String) -> AddOn? { all.first { $0.id == id } }

    /// Where published releases are listed: the feed attached to the newest release of
    /// the public releases repository. GitHub serves `latest/download/<name>` from
    /// whichever release is newest, so publishing a release is publishing its feed.
    ///
    /// A debug build can be pointed elsewhere with `KLIK_ADDON_FEED`, for testing an
    /// install against a feed served from this machine.
    static var feedURL: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["KLIK_ADDON_FEED"] { return URL(string: override) }
        #endif
        return URL(string: "https://github.com/mehedihasanhr/klik-releases/releases/latest/download/addons.json")
    }
}

/// The published feed, decoded.
nonisolated struct AddOnFeed: Sendable, Codable {
    /// Bumped when the shape changes. An unknown version is refused rather than
    /// guessed at, so an old Klik cannot misread a future feed.
    static let supportedFormat = 1

    let formatVersion: Int
    let releases: [AddOnRelease]

    /// The newest release for an add-on that this host is allowed to install.
    ///
    /// A release naming a newer host is skipped rather than offered: installing it
    /// would produce an add-on that immediately refuses to talk to the Klik that
    /// installed it.
    func latest(for addOn: AddOn, hostVersion: SemanticVersion = .host) -> AddOnRelease? {
        releases
            .filter { $0.addOn == addOn.id && $0.minimumHost <= hostVersion }
            .max { $0.version < $1.version }
    }

    static func decode(_ data: Data) throws(AddOnError) -> AddOnFeed {
        let feed: AddOnFeed
        do {
            feed = try JSONDecoder().decode(AddOnFeed.self, from: data)
        } catch {
            throw .malformedFeed
        }
        guard feed.formatVersion == supportedFormat else { throw .unsupportedFeed(feed.formatVersion) }
        return feed
    }
}

/// What the host can say about an add-on right now.
nonisolated enum AddOnAvailability: Sendable, Equatable {
    /// Nothing installed. `release` is `nil` while no build is published yet.
    case notInstalled(release: AddOnRelease?)
    /// Installed, but older than this Klik can talk to.
    case tooOld(installed: SemanticVersion, required: SemanticVersion, release: AddOnRelease?)
    /// Installed and usable, with a newer build published.
    case updatable(installed: SemanticVersion, release: AddOnRelease)
    case ready(installed: SemanticVersion)
    /// Found, but not signed by the team that signs Klik. Treated as absent: an app
    /// wearing the right bundle identifier is exactly what a host must not trust.
    case untrusted(reason: String)

    var isUsable: Bool {
        switch self {
        case .ready, .updatable: true
        case .notInstalled, .tooOld, .untrusted: false
        }
    }

    /// The version to install or update to, if any.
    var offeredRelease: AddOnRelease? {
        switch self {
        case .notInstalled(let release), .tooOld(_, _, let release): release
        case .updatable(_, let release): release
        case .ready, .untrusted: nil
        }
    }
}

/// Deciding what an installation means is pure, so it can be tested without an
/// installed app, a network or a keychain.
nonisolated enum AddOnResolver {
    static func availability(for addOn: AddOn,
                             installed: InstalledAddOn?,
                             release: AddOnRelease?) -> AddOnAvailability {
        guard let installed else { return .notInstalled(release: release) }
        if let reason = installed.untrustedReason { return .untrusted(reason: reason) }
        if installed.version < addOn.minimumSupported {
            return .tooOld(installed: installed.version, required: addOn.minimumSupported, release: release)
        }
        if let release, installed.version < release.version {
            return .updatable(installed: installed.version, release: release)
        }
        return .ready(installed: installed.version)
    }
}

/// An add-on found on disk.
nonisolated struct InstalledAddOn: Sendable, Hashable {
    let url: URL
    let version: SemanticVersion
    /// Why the signature check failed, or `nil` when it passed.
    let untrustedReason: String?
}

nonisolated enum AddOnError: Error, LocalizedError, Equatable {
    case notPublished
    case malformedFeed
    case unsupportedFeed(Int)
    case http(Int)
    case wrongSize(expected: Int, got: Int)
    case wrongDigest
    case notInstalled
    case tooOld(installed: SemanticVersion, required: SemanticVersion)
    case untrusted(String)
    case launchFailed(String)
    /// macOS refused to open the add-on (Gatekeeper); the user has been told why already.
    case blocked
    case installFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPublished: "This add-on hasn't been published yet."
        case .malformedFeed: "Klik couldn't read the add-on list."
        case .unsupportedFeed(let version): "The add-on list is version \(version), which this Klik doesn't understand."
        case .http(let status): "The download server answered \(status)."
        case .wrongSize(let expected, let got): "The download was \(got) bytes, not \(expected)."
        case .wrongDigest: "The download didn't match its checksum."
        case .notInstalled: "That add-on isn't installed."
        case .tooOld(let installed, let required): "Klik Studio \(installed) is installed, but \(required) or later is needed."
        case .untrusted(let reason): "The installed add-on isn't signed by Klik's developer (\(reason))."
        case .launchFailed(let reason): "The add-on wouldn't start: \(reason)"
        case .blocked: "macOS didn't open the add-on."
        case .installFailed(let reason): "Klik couldn't install it: \(reason)"
        case .downloadFailed(let reason): "The download didn't finish (\(reason)). Try again."
        }
    }
}
