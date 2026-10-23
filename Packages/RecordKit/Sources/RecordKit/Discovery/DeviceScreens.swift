// `@preconcurrency`: `AVCaptureDevice` is not marked `Sendable`, and the notifications it
// posts carry one as their object.
@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation
import os

/// The iPhones and iPads plugged into this Mac with a cable, as things that can be recorded.
///
/// macOS has always been able to show a connected iOS device's screen — it is how QuickTime
/// Player's "New Movie Recording" offers one — but it hides them from every app that has
/// not asked. The asking is a CoreMediaIO property, `AllowScreenCaptureDevices`, set on the
/// system object; once it is set, an unlocked device that trusts this Mac appears to
/// AVFoundation as an ordinary external capture device whose media type is *muxed* —
/// picture and sound from one source, the way a camcorder's used to be.
///
/// Three things about it are not obvious, and each has cost somebody an afternoon:
///
/// - **It is not instant.** Setting the property starts the system talking to the device,
///   and the device turns up a second or several later. A list read straight afterwards is
///   empty, which is why the recorder also watches for devices arriving (`Watcher`) rather
///   than trusting any one reading.
/// - **Setting it repeatedly is punished.** Set many times in quick succession, it blocks
///   for seconds. So it is set once per process, by `allow()`, and never again.
/// - **Discovery has to be woken.** Until something has asked AVFoundation for its devices,
///   the connected and disconnected notifications do not arrive. `allow()` asks once, so
///   that everything after it can rely on the notifications.
///
/// Nothing here opens a device. Listing them lights nothing and records nothing; the one
/// place a device is opened is `DeviceRecorder`, for a take somebody asked for.
public enum DeviceScreens {
    /// Tells CoreMediaIO this process wants to see connected iOS devices. Idempotent and
    /// cheap after the first call — the property is set exactly once per launch.
    public static func allow() {
        _ = allowed
    }

    /// Whether the property was accepted. Read once, lazily, which is how "set once per
    /// process" is enforced rather than hoped for.
    private static let allowed: Bool = {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                               0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
        if status != 0 {
            log.error("CoreMediaIO refused to show screen-capture devices: \(status)")
        }
        // The wake-up: without a first look, the arrival notifications never come.
        _ = discovery().devices
        return status == 0
    }()

    /// Every connected iPhone and iPad this process can see right now.
    ///
    /// Read rather than remembered, like the cameras and microphones: a list held from
    /// launch offers a phone that was unplugged an hour ago. Empty until `allow()` has been
    /// called — and for a moment after, while the system finds them.
    public static var devices: [AVCaptureDevice] {
        discovery().devices.filter(isScreen)
    }

    /// Whether a capture device is an iOS device's screen rather than, say, a capture card.
    ///
    /// Muxed and external is the shape; Apple's model identifier is the confirmation. The
    /// model check is lenient — anything muxed whose model says "iOS" or whose maker is
    /// Apple — because the exact strings are not documented, and being too strict here
    /// would hide the device the whole feature is for.
    static func isScreen(_ device: AVCaptureDevice) -> Bool {
        guard device.hasMediaType(.muxed) else { return false }
        return isScreen(modelID: device.modelID, manufacturer: device.manufacturer)
    }

    /// The model half of `isScreen(_:)`, on its own so it can be checked without a device.
    static func isScreen(modelID: String, manufacturer: String) -> Bool {
        modelID.localizedCaseInsensitiveContains("iOS")
            || manufacturer.localizedCaseInsensitiveContains("Apple")
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
    }

    /// What kind of device this is, for the manifest and the frame the editor draws.
    public static func family(of device: AVCaptureDevice, pixelSize: CGSize? = nil) -> RecordedDevice.Family {
        RecordedDevice.Family.guess(name: device.localizedName, pixelSize: pixelSize)
    }

    private static let log = Logger(subsystem: "com.stackrover.cue.studio", category: "devices")

    /// Calls back whenever a capture device comes or goes, so a list of devices on screen
    /// can be re-read. Any device, not only iOS ones: the notification says which device,
    /// but re-reading the list is cheap and always right, where filtering the notification
    /// is one more place to be wrong about what an iPhone looks like.
    @MainActor
    public final class Watcher {
        private var observers: [any NSObjectProtocol] = []

        public init(onChange: @escaping @MainActor () -> Void) {
            DeviceScreens.allow()
            let center = NotificationCenter.default
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange() }
                })
            }
        }

        /// Stops listening. Called by whoever made this; the observers hold only the
        /// callback, so a watcher that is dropped without it keeps calling a callback that
        /// has nothing left to refresh, which is harmless but wasteful.
        public func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
    }
}
