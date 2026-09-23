import Foundation
import Testing
@testable import AddOnKit

/// The contract itself: what survives the process boundary, and what a host may offer.
struct BridgeTests {
    @Test func aRequestSurvivesEncoding() throws {
        var request = RecordingRequest()
        request.target = .area(display: 1, rect: CGRect(x: 10, y: 20, width: 300, height: 200))
        request.microphone = true
        request.countdownSeconds = 5

        let decoded = try JSONDecoder().decode(RecordingRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func aRequestRoundTripsThroughAFileAndALaunchURL() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = RecordingRequest(target: .display(7), microphone: true)
        let file = try RequestFile.write(request, in: folder)
        let url = try #require(RequestFile.launchURL(for: file))
        let recovered = try #require(RequestFile.file(from: url))

        #expect(try RequestFile.read(at: recovered) == request)
    }

    /// A path with spaces is the normal case on macOS, not the exotic one.
    @Test func aPathWithSpacesSurvivesTheURL() throws {
        let folder = URL.temporaryDirectory.appending(path: "Klik Studio \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = try RequestFile.write(RecordingRequest(), in: folder)
        let url = try #require(RequestFile.launchURL(for: file))
        #expect(RequestFile.file(from: url)?.path(percentEncoded: false) == file.path(percentEncoded: false))
    }

    @Test(arguments: ["klik://record?request=/tmp/a.json",
                      "klik-studio://edit?request=/tmp/a.json",
                      "klik-studio://record",
                      "klik-studio://record?request="])
    func someoneElsesURLIsNotARequest(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(RequestFile.file(from: url) == nil)
    }

    // MARK: - Capabilities

    private var full: StudioCapabilities {
        StudioCapabilities(version: "1.0.0", canRecordDisplay: true, canRecordWindow: true,
                           canRecordArea: true, canRecordSystemAudio: true,
                           canRecordMicrophone: true, canRecordWebcam: true)
    }

    @Test func aNewCapabilityDefaultsToUnsupported() {
        let minimal = StudioCapabilities(version: "1.0.0")
        #expect(!minimal.canEdit)
        #expect(!minimal.canCaption)
        #expect(!minimal.supports(RecordingRequest(target: .display(1))))
    }

    @Test func aRequestForSomethingUnsupportedIsRefusedBeforeItIsSent() {
        var capabilities = full
        capabilities.canRecordWebcam = false
        #expect(capabilities.supports(RecordingRequest(target: .display(1))))
        #expect(!capabilities.supports(RecordingRequest(target: .display(1), webcam: true)))
    }

    @Test func askMeansAnyTargetWillDo() {
        var capabilities = StudioCapabilities(version: "1.0.0", canRecordArea: true, canRecordSystemAudio: true)
        #expect(capabilities.supports(RecordingRequest()))
        capabilities.canRecordArea = false
        #expect(!capabilities.supports(RecordingRequest()))
    }

    @Test func contractsMustMatchExactly() {
        let capabilities = StudioCapabilities(contract: 2, version: "2.0.0")
        #expect(!capabilities.speaks(contract: 1))
        #expect(capabilities.speaks(contract: 2))
    }

    /// Both apps derive every name from here; a rename in one of them has to fail here
    /// first, not in the field.
    @Test func theNamesBothSidesShareAreStable() {
        #expect(AddOnBridge.studioBundleID == "com.stackrover.klik.studio")
        #expect(AddOnBridge.machServiceName.hasPrefix(AddOnBridge.appGroup),
                "the sandbox refuses a Mach service that isn't prefixed with the app group")
        #expect(AddOnBridge.urlScheme == "klik-studio")
    }
}
