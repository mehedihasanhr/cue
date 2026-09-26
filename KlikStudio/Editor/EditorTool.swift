import SwiftUI

/// What the editor is set up to do, and therefore what the inspector shows.
///
/// One property on `EditorModel` rather than one per surface: the rail and the transport
/// bar both offer Crop, and two booleans claiming to own the same mode is how a tool
/// ends up half-on.
enum EditorTool: String, CaseIterable, Identifiable, Hashable {
    /// The ordinary state: no canvas tool, inspector follows the selection.
    case frame
    case crop
    case blur
    case annotate
    case cursor
    /// Aiming a zoom on the picture. Reached from the zoom inspector rather than from the
    /// rail: it is a tool for a region that is already selected, and a rail button for it
    /// would be one that does nothing most of the time.
    case zoom
    /// The camera bubble: the webcam recording, drawn over the picture.
    ///
    /// Spelled `webcam` rather than `camera`, and that is not pedantry: `Timeline.camera`
    /// is the *zoomed* camera — how steadily it follows the pointer — and `CameraInspector`
    /// edits that. Two things called Camera, one of which is a lens and one of which is a
    /// crop of the recording, is a confusion that would be paid for by every reader of this
    /// file from here on.
    case webcam
    case captions
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frame: "Frame"
        case .crop: "Crop"
        case .blur: "Blur"
        case .annotate: "Annotate"
        case .cursor: "Pointer"
        case .zoom: "Aim"
        case .webcam: "Webcam"
        case .captions: "Captions"
        case .audio: "Audio"
        }
    }

    /// SF Symbols rather than the host app's Hugeicons: `Klik/Support/Icon.swift` is in
    /// the Klik target and Studio cannot reach it. The names are chosen to match keys
    /// that already exist in `HugeIcons.names`, so lifting that system later is a
    /// mechanical swap rather than a redesign.
    var symbol: String {
        switch self {
        case .frame: "photo"
        case .crop: "crop"
        case .blur: "drop.halffull"
        case .annotate: "character.textbox"
        case .cursor: "cursorarrow.rays"
        case .zoom: "dot.scope"
        case .webcam: "person.crop.square"
        case .captions: "captions.bubble"
        case .audio: "waveform"
        }
    }

    /// Whether this tool draws over the preview instead of only filling the inspector.
    ///
    /// Crop is the odd one out: it re-renders the preview flat, because a crop rectangle
    /// cannot be dragged over a picture that is already padded, rounded and zoomed. Blur
    /// and annotation work *on* the composed frame, so they draw over it as it is.
    var isCanvasTool: Bool {
        switch self {
        case .crop, .blur, .annotate, .zoom: true
        default: false
        }
    }

    /// Whether the preview has to be flattened for this tool to be usable.
    var flattensPreview: Bool { self == .crop }

    /// Why a tool is off, or `nil` when it is on.
    ///
    /// Nothing is off any more. The mechanism stays, and deliberately: a disabled tool is a
    /// promise, so it says what it is waiting for rather than just going grey, and the next
    /// feature that lands model-first wants exactly this again. The webcam was the last one
    /// holding a reason, and it now has a recorder and a renderer behind it.
    var unavailableReason: String? {
        switch self {
        case .frame, .crop, .cursor, .blur, .annotate, .captions, .audio, .zoom, .webcam:
            nil
        }
    }

    var isAvailable: Bool { unavailableReason == nil }

    /// ⌘1 … ⌘6, in rail order.
    var shortcut: KeyEquivalent {
        switch self {
        case .frame: "1"
        case .crop: "2"
        case .blur: "3"
        case .annotate: "4"
        case .cursor: "5"
        // Off the end of the rail's numbers, because it is not on the rail — and it is not
        // reachable by ⌘9 either, since the shortcut is only wired up by the rail buttons.
        case .zoom: "9"
        case .webcam: "6"
        case .captions: "7"
        case .audio: "8"
        }
    }

    /// The tools the rail shows.
    ///
    /// Shortcuts and Links from the reference are not here: neither has a model behind
    /// it, and a greyed icon for something that does not exist yet is a promise with
    /// nothing to keep it.
    static let rail: [EditorTool] = [.frame, .crop, .blur, .annotate, .cursor, .webcam, .captions, .audio]
}
