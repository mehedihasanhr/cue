import CoreGraphics
import Foundation
import Testing
@testable import RecordKit

/// Recording a connected iPhone or iPad, as far as it can be checked without one.
///
/// The capture itself — CoreMediaIO showing the device, AVFoundation opening it, frames and
/// sound arriving — needs a real device on a real cable, unlocked and trusting this Mac,
/// and no test here pretends otherwise. What is here is every decision made *about* those
/// frames: how big the file is, what a turned device's picture becomes, which family a
/// device is, and what the manifest says about a take of one — including that recordings
/// from before any of this still read exactly as they did.
struct DeviceCaptureTests {
    // MARK: - The file's size

    /// An iPhone 15's screen is 1179 pixels across, which neither encoder will take.
    @Test func theFileIsTheFirstPictureTakenDownToEvenPixels() {
        #expect(DeviceFrameFit.canvas(for: CGSize(width: 1_179, height: 2_556)) == CGSize(width: 1_178, height: 2_556))
        #expect(DeviceFrameFit.canvas(for: CGSize(width: 2_048, height: 2_732)) == CGSize(width: 2_048, height: 2_732))
        #expect(DeviceFrameFit.canvas(for: CGSize(width: 2_556, height: 1_179)) == CGSize(width: 2_556, height: 1_178))
        // Never nothing, whatever a broken first frame says.
        #expect(DeviceFrameFit.canvas(for: .zero) == CGSize(width: 2, height: 2))
    }

    // MARK: - Every later frame

    @Test func aFrameTheFileWasSizedForIsWrittenAsItCame() {
        let canvas = CGSize(width: 1_178, height: 2_556)
        #expect(DeviceFrameFit.plan(source: canvas, canvas: canvas) == .passThrough)
    }

    /// The odd pixel: the same picture, a hair wider than the file. Scaled, not letterboxed
    /// — a one-pixel black line down a phone's edge is visible, a 0.08% squeeze is not.
    @Test func aPictureAPixelOffTheFileIsScaledRatherThanBoxed() {
        let canvas = DeviceFrameFit.canvas(for: CGSize(width: 1_179, height: 2_556))
        #expect(DeviceFrameFit.plan(source: CGSize(width: 1_179, height: 2_556), canvas: canvas) == .stretch)
    }

    /// Turned on its side part-way through: fitted whole, centred, black above and below,
    /// scaled evenly — never cropped, never stretched, never on its side.
    @Test func aTurnedDeviceIsFittedWholeInsideTheFile() throws {
        let canvas = CGSize(width: 1_178, height: 2_556)
        let turned = CGSize(width: 2_556, height: 1_179)
        #expect(DeviceFrameFit.isTurned(turned, from: canvas))

        guard case .fit(let rect) = DeviceFrameFit.plan(source: turned, canvas: canvas) else {
            Issue.record("a turned picture must be fitted")
            return
        }
        // As wide as the file, and as tall as that makes it.
        #expect(rect.width == 1_178)
        #expect(abs(rect.height - (1_179 * 1_178 / 2_556).rounded()) < 0.5)
        // Its shape kept, to within the rounding to whole pixels.
        #expect(abs(rect.width / rect.height - turned.width / turned.height) < 0.01)
        // Centred, inside.
        #expect(rect.minX == 0)
        #expect(abs(rect.midY - canvas.height / 2) <= 1)
        #expect(CGRect(origin: .zero, size: canvas).contains(rect))
    }

    /// And the other way round: a take begun on its side, then stood up.
    @Test func aDeviceStoodUpInALandscapeTakeIsFittedToo() {
        let canvas = CGSize(width: 2_732, height: 2_048)
        guard case .fit(let rect) = DeviceFrameFit.plan(source: CGSize(width: 2_048, height: 2_732), canvas: canvas) else {
            Issue.record("a turned picture must be fitted")
            return
        }
        #expect(rect.height == 2_048)
        #expect(abs(rect.width - 1_536) <= 1)
        #expect(abs(rect.midX - canvas.width / 2) <= 1)
    }

    /// Something other than a turn — a device that changed resolution, say — is fitted as
    /// well rather than stretched: only a pixel or two of difference counts as the same.
    @Test func aDifferentSizeTheSameWayUpIsFittedNotStretched() {
        let canvas = CGSize(width: 1_178, height: 2_556)
        guard case .fit(let rect) = DeviceFrameFit.plan(source: CGSize(width: 750, height: 1_334), canvas: canvas) else {
            Issue.record("a picture of another shape must be fitted")
            return
        }
        #expect(rect.width == 1_178)
        #expect(rect.height < 2_556)
    }

    @Test func aSquarePictureCountsAsUpright() {
        #expect(!DeviceFrameFit.isTurned(CGSize(width: 100, height: 100), from: CGSize(width: 100, height: 200)))
        #expect(DeviceFrameFit.isTurned(CGSize(width: 100, height: 100), from: CGSize(width: 200, height: 100)))
    }

    // MARK: - Which device

    @Test func aDeviceThatSaysWhatItIsIsBelieved() {
        #expect(RecordedDevice.Family.guess(name: "Mehedi\u{2019}s iPhone", pixelSize: nil) == .iPhone)
        #expect(RecordedDevice.Family.guess(name: "Studio iPad Pro", pixelSize: CGSize(width: 1, height: 3)) == .iPad)
    }

    /// A device called "Work" is told apart by the shape of its screen.
    @Test func aDeviceNamedAnythingElseIsToldApartByItsShape() {
        let guess = { RecordedDevice.Family.guess(name: "Work", pixelSize: $0) }
        #expect(guess(CGSize(width: 1_179, height: 2_556)) == .iPhone)   // iPhone 15
        #expect(guess(CGSize(width: 2_556, height: 1_179)) == .iPhone)   // on its side
        #expect(guess(CGSize(width: 750, height: 1_334)) == .iPhone)     // iPhone SE
        #expect(guess(CGSize(width: 2_048, height: 2_732)) == .iPad)     // iPad Pro 12.9
        #expect(guess(CGSize(width: 1_640, height: 2_360)) == .iPad)     // iPad Air
        #expect(guess(CGSize(width: 1_488, height: 2_266)) == .iPad)     // iPad mini
        #expect(guess(nil) == .other)
    }

    @Test func aDevicesPointsAreItsOwn() {
        #expect(RecordedDevice.Family.iPhone.displayScale == 3)
        #expect(RecordedDevice.Family.iPad.displayScale == 2)
        #expect(RecordedDevice.Family.other.displayScale == 2)
    }

    /// Lenient about the identifiers Apple does not document, strict about the shape.
    @Test func anIOSScreenIsRecognisedByItsModel() {
        #expect(DeviceScreens.isScreen(modelID: "iOS Device", manufacturer: "Apple Inc."))
        #expect(DeviceScreens.isScreen(modelID: "iPad Screen", manufacturer: "Apple Inc."))
        #expect(!DeviceScreens.isScreen(modelID: "HDMI Capture", manufacturer: "Elgato"))
    }

    // MARK: - The target

    @Test func aDeviceTargetIsNotOnTheMacsScreen() {
        let target = CaptureTarget.device(uniqueID: "abc")
        #expect(target.displayID == nil)
        #expect(target.deviceID == "abc")
        #expect(!target.isOnScreen)
        #expect(CaptureTarget.display(1).isOnScreen)
        #expect(CaptureTarget.display(1).deviceID == nil)
        #expect(target.origin(inside: CGRect(x: 10, y: 20, width: 5, height: 5)) == CGPoint(x: 10, y: 20))
    }

    @Test func aHostsDeviceRequestBecomesADeviceTarget() throws {
        #expect(CaptureTarget(RecordingRequest.Target.device(uniqueID: "abc")) == .device(uniqueID: "abc"))
        // Through the file a host actually writes, as far as the wire goes.
        let data = try JSONEncoder().encode(RecordingRequest(target: .device(uniqueID: "abc")))
        let read = try JSONDecoder().decode(RecordingRequest.self, from: data)
        #expect(CaptureTarget(read.target) == .device(uniqueID: "abc"))
    }

    // MARK: - The manifest

    private func decode(_ json: String) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingManifest.self, from: Data(json.utf8))
    }

    /// A manifest written before devices could be recorded: no `device`, and a cursor.
    private let oldManifest = """
    {"formatVersion":1,"name":"Old take","createdAt":"2025-11-02T10:00:00Z","duration":12.5,
     "displayScale":2,"tracks":[{"kind":"screen","path":"media/screen.mov","pixelSize":[3024,1964],"frameRate":60}],
     "telemetry":{"cursor":"telemetry/cursor.jsonl","input":"telemetry/input.jsonl"},"recordedBy":"Klik Studio"}
    """

    @Test func aRecordingFromBeforeDevicesStillOpensAsAScreenTake() throws {
        let manifest = try decode(oldManifest)
        #expect(manifest.device == nil)
        #expect(manifest.telemetry.cursor == "telemetry/cursor.jsonl")
        #expect(manifest.track(.screen)?.pixelSize == CGSize(width: 3_024, height: 1_964))
    }

    /// A device take: the device named, the device's sound as its system audio, and no
    /// pointer, clicks or focus — named by their absence rather than by empty files.
    @Test func aDeviceTakesManifestRoundTrips() throws {
        let folder = URL.temporaryDirectory.appending(path: "RecordKitDeviceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try RecordingPackage.create(named: "Phone", in: folder)

        var manifest = RecordingManifest(
            name: "Phone",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 8,
            displayScale: 3,
            tracks: [
                .init(kind: .screen, path: "media/screen.mov", pixelSize: CGSize(width: 1_178, height: 2_556), frameRate: 60),
                .init(kind: .systemAudio, path: "media/device-audio.m4a", name: "Mehedi\u{2019}s iPhone", deviceID: "abc"),
            ],
            telemetry: .init(markers: "telemetry/markers.jsonl"))
        manifest.device = RecordedDevice(name: "Mehedi\u{2019}s iPhone", family: .iPhone, deviceID: "abc")
        try package.write(manifest)

        let read = try package.readManifest()
        #expect(read == manifest)
        #expect(read.device?.family == .iPhone)
        #expect(read.telemetry.cursor == nil)
        #expect(read.telemetry.input == nil)
        #expect(read.telemetry.focus == nil)
        #expect(read.audioTracks.map(\.path) == ["media/device-audio.m4a"])
    }

    /// A family a newer build knows about reads as "other", not as a recording that will
    /// not open.
    @Test func anUnknownFamilyDoesNotCostTheRecording() throws {
        let json = """
        {"formatVersion":1,"name":"Future","createdAt":"2027-01-01T00:00:00Z","duration":1,"displayScale":2,
         "tracks":[],"telemetry":{},"recordedBy":"Klik Studio",
         "device":{"name":"Goggles","family":"visionPro"}}
        """
        let manifest = try decode(json)
        #expect(manifest.device?.family == .other)
        #expect(manifest.device?.name == "Goggles")
        #expect(manifest.device?.deviceID == nil)
    }

    // MARK: - Errors

    @Test func aSilentDeviceSaysWhatToDoOnTheDevice() {
        let error = RecordingError.deviceSilent("Mehedi\u{2019}s iPhone")
        #expect(error.errorDescription?.contains("Mehedi\u{2019}s iPhone") == true)
        #expect(error.recoverySuggestion?.contains("Unlock") == true)
    }
}
