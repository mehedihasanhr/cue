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
    case camera
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
        case .camera: "Camera"
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
        case .camera: "camera.viewfinder"
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
        case .crop, .blur, .annotate: true
        default: false
        }
    }

    /// Whether the preview has to be flattened for this tool to be usable.
    var flattensPreview: Bool { self == .crop }

    /// Why a tool is off, or `nil` when it is on.
    ///
    /// A disabled tool is a promise, so it says what it is waiting for rather than just
    /// going grey. All three of these are fully modelled and persisted today — they are
    /// waiting on a renderer, not on a decision. `StudioSettings.recordsCamera` already
    /// sets this precedent: visibly coming beats quietly missing.
    var unavailableReason: String? {
        switch self {
        case .frame, .crop, .cursor, .blur, .annotate, .captions, .audio:
            nil
        case .camera:
            "The camera bubble arrives with the webcam recorder."
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
        case .camera: "6"
        case .captions: "7"
        case .audio: "8"
        }
    }

    /// The tools the rail shows.
    ///
    /// Shortcuts and Links from the reference are not here: neither has a model behind
    /// it, and a greyed icon for something that does not exist yet is a promise with
    /// nothing to keep it.
    static let rail: [EditorTool] = [.frame, .crop, .blur, .annotate, .cursor, .camera, .captions, .audio]
}
