import Foundation
import RecordKit

/// How a recording of an iPhone or iPad looks the first time it is opened.
///
/// A phone's screen on its own, floating on a background, reads as a tall screenshot; the
/// same picture inside a phone reads as a phone, which is what it was. The frames already
/// exist — `WindowChrome.Kind.iPhone` and `.iPad` — so a take that the manifest says is of
/// a device opens wearing the matching one, turned to match the recording (`.automatic`),
/// and everything else about the look is left as the user's defaults made it.
///
/// A device that could not be told apart (`RecordedDevice.Family.other`) gets no frame at
/// all rather than a guessed one: drawing an iPhone round an iPad is a worse first
/// impression than drawing nothing, and the frame is one click away.
extension Timeline {
    /// This timeline wearing the frame for `device`, or unchanged when there is none to wear.
    public func dressed(for device: RecordedDevice?) -> Timeline {
        guard let kind = Self.frame(for: device) else { return self }
        var dressed = self
        // Over whatever the defaults chose: a macOS window or a browser bar round a phone's
        // screen is never what anybody meant, and the defaults were written for the Mac.
        dressed.style.chrome.kind = kind
        dressed.style.chrome.orientation = .automatic
        return dressed
    }

    /// The frame a device wears, if it is known well enough to choose one.
    public static func frame(for device: RecordedDevice?) -> WindowChrome.Kind? {
        switch device?.family {
        case .iPhone: .iPhone
        case .iPad: .iPad
        case .other, nil: nil
        }
    }
}

extension EditorDocument {
    /// Puts a device take in its frame, as where the project starts rather than as an edit
    /// — see `adopt(_:)`. Only for a project nobody has edited: a frame taken off a phone
    /// on purpose stays off.
    public func adoptDeviceLook() {
        guard !hasBeenEdited, Timeline.frame(for: manifest.device) != nil else { return }
        adopt(timeline.dressed(for: manifest.device))
    }

    /// Whether this is a recording of a connected iPhone or iPad — a take with no pointer
    /// in it by nature, rather than one whose pointer was not kept.
    public var isDeviceTake: Bool { manifest.device != nil }
}
