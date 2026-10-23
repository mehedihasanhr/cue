import RecordKit
import SwiftUI

/// What the editor is set up to do, and therefore what the inspector shows.
///
/// One property on `EditorModel` rather than one per surface: the rail and the transport
/// bar both offer Crop, and two booleans claiming to own the same mode is how a tool
/// ends up half-on.
enum VideoEditorTool: String, CaseIterable, Identifiable, Hashable {
    /// The ordinary state: no canvas tool, inspector follows the selection.
    case frame
    case crop
    case blur
    case annotate
    case cursor
    /// The camera bubble: the webcam recording, drawn over the picture.
    ///
    /// Spelled `webcam` rather than `camera`, and that is not pedantry: `Timeline.camera`
    /// is the *zoomed* camera — how steadily it follows the pointer — and `CameraControls`
    /// edits that. Two things called Camera, one of which is a lens and one of which is a
    /// crop of the recording, is a confusion that would be paid for by every reader of this
    /// file from here on.
    case webcam
    case captions
    case audio
    /// The shortcuts pressed during the take, drawn as keys over the picture.
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frame: "Frame"
        case .crop: "Crop"
        // "Mask" rather than "Blur" now that the same tool covers and spotlights as well:
        // a tool called Blur that dims everything *except* its rectangle is misnamed.
        case .blur: "Mask"
        case .annotate: "Annotate"
        case .cursor: "Pointer"
        case .webcam: "Webcam"
        case .captions: "Captions"
        case .audio: "Audio"
        case .keyboard: "Keyboard"
        }
    }

    /// SF Symbols rather than the host app's Hugeicons: `Cue/Support/Icon.swift` is in
    /// the Cue target and Studio cannot reach it. The names are chosen to match keys
    /// that already exist in `HugeIcons.names`, so lifting that system later is a
    /// mechanical swap rather than a redesign.
    var symbol: String {
        switch self {
        case .frame: "photo"
        case .crop: "crop"
        case .blur: "drop.halffull"
        case .annotate: "character.textbox"
        case .cursor: "cursorarrow.rays"
        case .webcam: "person.crop.square"
        case .captions: "captions.bubble"
        case .audio: "waveform"
        case .keyboard: "keyboard"
        }
    }

    /// Whether this tool draws over the preview instead of only filling the inspector.
    ///
    /// Crop is the odd one out: it re-renders the preview flat, because a crop rectangle
    /// cannot be dragged over a picture that is already padded, rounded and zoomed. Blur
    /// and annotation work *on* the composed frame, so they draw over it as it is.
    var isCanvasTool: Bool {
        switch self {
        case .crop, .blur, .annotate: true
        default: false
        }
    }

    /// Whether the preview has to be flattened for this tool to be usable.
    ///
    /// Only crop. Cropping is direct manipulation of the *source* frame, and a crop
    /// rectangle cannot be dragged over a picture that is already cropped, padded, rounded
    /// and zoomed — the tool would be showing its own answer.
    ///
    /// Framing a zoom needs the zooms out of the way for the same reason and nothing else
    /// out of the way at all, which is why it is not a tool and not here: see
    /// `EditorModel.isFramingZoom`.
    var flattensPreview: Bool { self == .crop }

    /// Why a tool is off, or `nil` when it is on.
    ///
    /// Nothing is off any more. The mechanism stays, and deliberately: a disabled tool is a
    /// promise, so it says what it is waiting for rather than just going grey, and the next
    /// feature that lands model-first wants exactly this again. The webcam was the last one
    /// holding a reason, and it now has a recorder and a renderer behind it.
    var unavailableReason: String? {
        switch self {
        case .frame, .crop, .cursor, .blur, .annotate, .captions, .audio, .webcam, .keyboard:
            nil
        }
    }

    var isAvailable: Bool { unavailableReason == nil }

    /// The menu command that chooses this tool, whose shortcut — ⌘1 to ⌘9 in rail order
    /// unless somebody changed it — is looked up in `EditorShortcutPreferences`.
    var command: EditorCommand {
        switch self {
        case .frame: .toolFrame
        case .crop: .toolCrop
        case .blur: .toolMask
        case .annotate: .toolAnnotate
        case .cursor: .toolPointer
        case .webcam: .toolWebcam
        case .captions: .toolCaptions
        case .audio: .toolAudio
        case .keyboard: .toolKeyboard
        }
    }

    /// The tools the inspector's tabs show, in order — the order ⌘1 to ⌘9 follow.
    ///
    /// Shortcuts and Links from the reference are not here: neither has a model behind
    /// it, and a greyed icon for something that does not exist yet is a promise with
    /// nothing to keep it.
    static let rail: [VideoEditorTool] = [.frame, .crop, .blur, .annotate, .cursor, .webcam, .captions, .audio, .keyboard]
}
