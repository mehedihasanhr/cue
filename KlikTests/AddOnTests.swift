import AddOnKit
import XCTest

/// Versions, the add-on feed, and what an installation means.
///
/// All of it is pure: nothing here installs an app, touches the network or reads a
/// signature, because the decisions are the part that can be wrong.
final class AddOnTests: XCTestCase {
    // MARK: - Versions

    func testVersionsParseWithMissingComponents() {
        XCTAssertEqual(SemanticVersion("1"), SemanticVersion(1, 0, 0))
        XCTAssertEqual(SemanticVersion("0.5"), SemanticVersion(0, 5, 0))
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
    }

    func testVersionsOrderNumericallyNotAlphabetically() {
        let nine = try! XCTUnwrap(SemanticVersion("0.9.0"))
        let ten = try! XCTUnwrap(SemanticVersion("0.10.0"))
        XCTAssertLessThan(nine, ten, "0.10.0 is newer than 0.9.0; string comparison says otherwise")
        XCTAssertLessThan(try! XCTUnwrap(SemanticVersion("1.0.0")), try! XCTUnwrap(SemanticVersion("1.0.1")))
    }

    /// A build suffix says which build, not which release, so it must not change order.
    func testBuildSuffixIsKeptForDisplayAndIgnoredForOrdering() {
        let plain = try! XCTUnwrap(SemanticVersion("3.7.5"))
        let built = try! XCTUnwrap(SemanticVersion("3.7.5-4595"))
        XCTAssertFalse(plain < built)
        XCTAssertFalse(built < plain)
        XCTAssertEqual(built.description, "3.7.5-4595")
        XCTAssertEqual(built.suffix, "4595")
    }

    func testNonsenseIsRejectedRatherThanGuessedAt() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("beta"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion("-1.0"))
    }

    // MARK: - Feed

    private func feed(_ releases: [(String, String, String)], format: Int = 1) -> AddOnFeed {
        AddOnFeed(formatVersion: format, releases: releases.map { addOn, version, host in
            AddOnRelease(addOn: addOn,
                         version: SemanticVersion(version)!,
                         download: URL(string: "https://example.com/\(addOn)-\(version).dmg")!,
                         bytes: 1_000,
                         sha256: String(repeating: "a", count: 64),
                         minimumHost: SemanticVersion(host)!,
                         installer: .diskImage,
                         notes: nil)
        })
    }

    func testTheLatestReleaseWins() {
        let feed = feed([("studio", "1.0.0", "0.5.0"), ("studio", "1.2.0", "0.5.0"), ("studio", "1.1.0", "0.5.0")])
        XCTAssertEqual(feed.latest(for: AddOnCatalog.studio, hostVersion: SemanticVersion("0.6.0")!)?.version,
                       SemanticVersion(1, 2, 0))
    }

    /// Offering a release that needs a newer Klik would install an add-on that
    /// immediately refuses to talk to the Klik that installed it.
    func testAReleaseNeedingANewerHostIsNotOffered() {
        let feed = feed([("studio", "1.0.0", "0.5.0"), ("studio", "2.0.0", "1.0.0")])
        XCTAssertEqual(feed.latest(for: AddOnCatalog.studio, hostVersion: SemanticVersion("0.5.0")!)?.version,
                       SemanticVersion(1, 0, 0))
    }

    func testAnotherAddOnsReleasesAreIgnored() {
        let feed = feed([("something-else", "9.0.0", "0.1.0")])
        XCTAssertNil(feed.latest(for: AddOnCatalog.studio, hostVersion: SemanticVersion("9.9.9")!))
    }

    func testAFeedFromTheFutureIsRefusedRatherThanMisread() {
        let data = try! JSONEncoder().encode(feed([("studio", "1.0.0", "0.5.0")], format: 99))
        XCTAssertThrowsError(try AddOnFeed.decode(data)) { error in
            XCTAssertEqual(error as? AddOnError, .unsupportedFeed(99))
        }
    }

    func testRubbishIsAMalformedFeed() {
        XCTAssertThrowsError(try AddOnFeed.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? AddOnError, .malformedFeed)
        }
    }

    func testAFeedRoundTrips() throws {
        let original = feed([("studio", "1.4.0", "0.5.0")])
        let decoded = try AddOnFeed.decode(JSONEncoder().encode(original))
        XCTAssertEqual(decoded.releases, original.releases)
    }

    // MARK: - Availability

    /// Not named `release`: `XCTestCase` inherits `release()` from ObjC.
    private var studioRelease: AddOnRelease {
        feed([("studio", "1.2.0", "0.1.0")]).releases[0]
    }

    func testNothingInstalledMeansNotInstalled() {
        let availability = AddOnResolver.availability(for: AddOnCatalog.studio, installed: nil, release: studioRelease)
        XCTAssertEqual(availability, .notInstalled(release: studioRelease))
        XCTAssertFalse(availability.isUsable)
        XCTAssertEqual(availability.offeredRelease, studioRelease)
    }

    func testNothingInstalledAndNothingPublishedStillReads() {
        XCTAssertEqual(AddOnResolver.availability(for: AddOnCatalog.studio, installed: nil, release: nil),
                       .notInstalled(release: nil))
    }

    func testAnInstalledAddOnAtTheLatestVersionIsReady() {
        let installed = InstalledAddOn(url: URL(fileURLWithPath: "/Applications/Klik Studio.app"),
                                       version: SemanticVersion(1, 2, 0),
                                       untrustedReason: nil)
        let availability = AddOnResolver.availability(for: AddOnCatalog.studio, installed: installed, release: studioRelease)
        XCTAssertEqual(availability, .ready(installed: SemanticVersion(1, 2, 0)))
        XCTAssertTrue(availability.isUsable)
        XCTAssertNil(availability.offeredRelease, "there is nothing to offer when it is current")
    }

    /// An older-but-supported add-on still records; the update is an offer, not a wall.
    func testAnOlderSupportedVersionIsUsableAndUpdatable() {
        let installed = InstalledAddOn(url: URL(fileURLWithPath: "/Applications/Klik Studio.app"),
                                       version: SemanticVersion(1, 1, 0),
                                       untrustedReason: nil)
        let availability = AddOnResolver.availability(for: AddOnCatalog.studio, installed: installed, release: studioRelease)
        XCTAssertEqual(availability, .updatable(installed: SemanticVersion(1, 1, 0), release: studioRelease))
        XCTAssertTrue(availability.isUsable)
    }

    func testAVersionBelowTheMinimumIsNotUsable() {
        let installed = InstalledAddOn(url: URL(fileURLWithPath: "/Applications/Klik Studio.app"),
                                       version: SemanticVersion(0, 9, 0),
                                       untrustedReason: nil)
        let availability = AddOnResolver.availability(for: AddOnCatalog.studio, installed: installed, release: studioRelease)
        XCTAssertEqual(availability, .tooOld(installed: SemanticVersion(0, 9, 0),
                                             required: AddOnCatalog.studio.minimumSupported,
                                             release: studioRelease))
        XCTAssertFalse(availability.isUsable)
    }

    /// A bundle identifier is a naming convention, not a credential. Anything can claim
    /// the add-on's — the signature is what makes it the add-on.
    func testAWrongSignatureBeatsAGoodVersion() {
        let installed = InstalledAddOn(url: URL(fileURLWithPath: "/tmp/Klik Studio.app"),
                                       version: SemanticVersion(9, 9, 9),
                                       untrustedReason: "signed by SOMEONEELSE")
        let availability = AddOnResolver.availability(for: AddOnCatalog.studio, installed: installed, release: studioRelease)
        XCTAssertEqual(availability, .untrusted(reason: "signed by SOMEONEELSE"))
        XCTAssertFalse(availability.isUsable)
        XCTAssertNil(availability.offeredRelease)
    }

    // MARK: - Catalogue

    func testTheCatalogueIsInternallyConsistent() {
        XCTAssertEqual(Set(AddOnCatalog.all.map(\.id)).count, AddOnCatalog.all.count, "ids must be unique")
        for addOn in AddOnCatalog.all {
            XCTAssertTrue(addOn.bundleID.hasPrefix("com.stackrover.klik."),
                          "an add-on's bundle id has to sit under Klik's own")
            XCTAssertFalse(addOn.name.isEmpty)
            XCTAssertFalse(addOn.summary.isEmpty)
        }
    }

    // MARK: - Downloads

    func testDownloadsLandInTheContainerAndNotInTheBundle() {
        let url = AddOnDownloads.fileURL(for: studioRelease)
        XCTAssertEqual(url.pathExtension, "dmg")
        XCTAssertTrue(url.path.contains("Klik/AddOns"))
        XCTAssertFalse(url.path.contains(".app/Contents"),
                       "writing into the bundle invalidates the signature and drops the Screen Recording grant")
    }

    // MARK: - Requests

    /// What the settings say is what gets asked for. Checked without launching
    /// anything, because "did Klik ask for the microphone?" is a question about the
    /// request, not about the add-on.
    @MainActor
    func testSettingsBecomeTheRequestKlikSends() {
        let preferences = StudioPreferences()
        preferences.countdownSeconds = 5
        preferences.recordsSystemAudio = false
        preferences.recordsMicrophone = true
        preferences.opensEditorAfterRecording = true

        let request = preferences.request(target: .display(3))
        XCTAssertEqual(request.target, .display(3))
        XCTAssertEqual(request.countdownSeconds, 5)
        XCTAssertFalse(request.systemAudio)
        XCTAssertTrue(request.microphone)
        XCTAssertTrue(request.opensEditorWhenFinished)
    }

    /// A countdown nobody would want is clamped rather than sent on.
    @MainActor
    func testAnAbsurdCountdownIsClamped() {
        let preferences = StudioPreferences()
        preferences.countdownSeconds = -4
        XCTAssertEqual(preferences.request().countdownSeconds, 0)
        preferences.countdownSeconds = 600
        XCTAssertEqual(preferences.request().countdownSeconds, 10)
    }

    /// A field a newer Klik sends must not change what an older add-on does, so it
    /// defaults to off.
    func testTheOpenEditorFlagDefaultsToOff() {
        XCTAssertFalse(RecordingRequest().opensEditorWhenFinished)
    }

    func testARecordingRequestSurvivesTheProcessBoundary() throws {
        var request = RecordingRequest()
        request.target = .area(display: 1, rect: CGRect(x: 10, y: 20, width: 300, height: 200))
        request.microphone = true
        request.countdownSeconds = 5
        request.opensEditorWhenFinished = true
        request.destination = URL(fileURLWithPath: "/Users/someone/Movies/Demos")

        let decoded = try JSONDecoder().decode(RecordingRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }
}
