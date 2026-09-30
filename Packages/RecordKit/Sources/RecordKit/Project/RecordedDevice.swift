import CoreGraphics
import Foundation

/// The iPhone or iPad a take is a recording of, as the manifest remembers it.
///
/// Stored rather than looked up when the project opens, for the reason a microphone's name
/// is: the phone will not be on the cable next week, and the editor still has to know that
/// what it is showing is a phone — to put a phone round it, and to know that the missing
/// pointer track is not a missing file but a take that never had a pointer in it.
public struct RecordedDevice: Codable, Equatable, Sendable {
    /// What kind of device, for the frame the editor draws round it.
    public enum Family: String, Codable, Sendable, CaseIterable {
        case iPhone, iPad
        /// A device that could not be told apart — kept rather than guessed, so the editor
        /// can leave the choice of frame to the user instead of drawing the wrong one.
        case other

        /// Leniently: a family a newer build wrote reads as `.other` rather than failing
        /// the whole manifest, because a manifest that will not decode is a recording that
        /// will not open, and the family only ever decides a frame.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Family(rawValue: raw) ?? .other
        }

        /// Which of the two a device is, from what AVFoundation says about it.
        ///
        /// The device's own name is asked first, because it usually says so — "Mehedi's
        /// iPhone" — but it is whatever the owner typed, and nothing stops a phone being
        /// called "Work". So the picture's shape decides otherwise: every iPhone since the X
        /// is about 2.17 to 1, the older ones 16 to 9 (1.78), and every iPad sits between
        /// 4 to 3 (1.33) and the mini's 1.52. The line at 1.6 falls in the gap between the
        /// two families, and a picture that is not known yet is left as `.other`.
        public static func guess(name: String, pixelSize: CGSize?) -> Family {
            let lowered = name.lowercased()
            if lowered.contains("ipad") { return .iPad }
            if lowered.contains("iphone") { return .iPhone }
            guard let size = pixelSize, size.width > 1, size.height > 1 else { return .other }
            let long = max(size.width, size.height), short = min(size.width, size.height)
            return long / short >= 1.6 ? .iPhone : .iPad
        }

        /// Pixels per point of the device's own screen, so a take of one is measured in the
        /// points its apps are laid out in, the way a Mac take is in the Mac's. Every iPhone
        /// with a screen shaped like a current one is 3×, every iPad 2×; a device that
        /// could not be told apart is taken at 2×, which is the gentler of the two mistakes.
        public var displayScale: Double {
            switch self {
            case .iPhone: 3
            case .iPad, .other: 2
            }
        }
    }

    /// What the device calls itself, for the library and the editor's title.
    public var name: String
    public var family: Family
    /// The capture device's `uniqueID` — not to open it again, but to tell two of the same
    /// model apart, the same use `Track.deviceID` has.
    public var deviceID: String?

    public init(name: String, family: Family, deviceID: String? = nil) {
        self.name = name
        self.family = family
        self.deviceID = deviceID
    }
}
