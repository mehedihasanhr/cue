import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// What a recording says about its camera, and what a configuration has to say before one
/// is ever opened.
///
/// Nothing here starts a capture session or touches a device. That is not a limitation of
/// the tests, it is the thing being tested: the state in which a camera *is* opened is
/// exactly `webcamID != nil`, so everything worth asserting about the camera's existence is
/// assertable from a value.
struct WebcamTrackTests {
    private func temporaryFolder() -> URL {
        let url = URL.temporaryDirectory.appending(path: "RecordKitWebcamTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configuration(destination: URL) -> RecordingConfiguration {
        RecordingConfiguration(target: .display(1), destination: destination, name: "Demo")
    }

    /// No camera unless one was asked for. The default is the whole guarantee: a
    /// configuration made without mentioning the camera cannot open one.
    @Test func aConfigurationAsksForNoCameraByDefault() {
        #expect(configuration(destination: .temporaryDirectory).webcamID == nil)
    }

    /// The camera's file is named in the manifest, separately from the screen's.
    ///
    /// Separately, and that is the point: the two audio tracks share `screen.mov` because
    /// they are tracks of it, while the camera is its own file — everything that reads a
    /// recording asks for the first video track of the file it is pointed at, so a second
    /// video track beside the screen would make "the recording" ambiguous.
    @Test func aManifestNamesTheCamerasOwnFile() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Demo", in: folder)

        let manifest = RecordingManifest(
            name: "Demo",
            duration: 12,
            tracks: [
                .init(kind: .screen, path: "media/screen.mov",
                      pixelSize: CGSize(width: 2_560, height: 1_600), frameRate: 60),
                .init(kind: .microphone, path: "media/screen.mov"),
                .init(kind: .webcam, path: "media/webcam.mov",
                      pixelSize: CGSize(width: 1_280, height: 720), frameRate: 30, codec: "hvc1"),
            ])
        try package.write(manifest)

        let read = try package.readManifest()
        let webcam = try #require(read.track(.webcam))
        #expect(webcam.path == "media/webcam.mov")
        #expect(webcam.path != read.track(.screen)?.path, "the camera is not in the screen's file")
        #expect(webcam.pixelSize == CGSize(width: 1_280, height: 720))
        #expect(webcam.frameRate == 30, "the camera keeps its own rate, not the screen's")
    }

    /// A recording with no camera says so by having no track, and that is what the editor
    /// asks. Every recording made before the camera could be recorded looks like this.
    @Test func aRecordingWithoutACameraHasNoWebcamTrack() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Demo", in: folder)

        try package.write(RecordingManifest(name: "Demo",
                                            tracks: [.init(kind: .screen, path: "media/screen.mov")]))
        #expect(try package.readManifest().track(.webcam) == nil)
    }

    /// A refused camera is its own failure, with its own pane to go to.
    ///
    /// Asserted because the whole reason `RecordingError` has one case per thing a user can
    /// act on is that "grant Camera" and "grant Microphone" are two different lists in
    /// System Settings — and a recovery suggestion that names the wrong one sends somebody
    /// to a switch that is already on.
    @Test func aRefusedCameraIsNotARefusedMicrophone() throws {
        #expect(RecordingError.cameraDenied != RecordingError.microphoneDenied)

        let camera = try #require(RecordingError.cameraDenied.recoverySuggestion)
        #expect(camera.contains("Camera"))
        #expect(!camera.contains("Microphone"))

        let microphone = try #require(RecordingError.microphoneDenied.recoverySuggestion)
        #expect(!microphone.contains("Camera"))
    }
}
