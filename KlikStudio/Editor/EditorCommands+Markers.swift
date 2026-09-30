import RecordKit
import SwiftUI
import TimelineKit

/// The markers dropped while recording, in the menus: jumping between them in Playback,
/// cutting at them in Edit.
extension EditorCommands {
    private var markerEditor: EditorModel? { windows.front?.model }

    /// Beside Previous Cut and Next Cut. ⌃; and ⌃' are the keys editors that have markers
    /// use for them, and nothing else in this app does.
    @ViewBuilder
    var markerNavigation: some View {
        Button("Previous Marker") { markerEditor?.goToPreviousMarker() }
            .editorShortcut(.previousMarker, shortcuts)
            .disabled(markerEditor?.previousMarker == nil)
            .help(markerHelp)
        Button("Next Marker") { markerEditor?.goToNextMarker() }
            .editorShortcut(.nextMarker, shortcuts)
            .disabled(markerEditor?.nextMarker == nil)
            .help(markerHelp)
    }

    /// Beside Split at Playhead.
    @ViewBuilder
    var markerSplit: some View {
        Button("Split at Markers") { markerEditor?.splitAtMarkers() }
            .editorShortcut(.splitAtMarkers, shortcuts)
            .disabled(markerEditor?.hasMarkers != true)
            .help(markerHelp)
    }

    private var markerHelp: String {
        markerEditor?.hasMarkers == true
            ? "The markers dropped while recording are the flags on the ruler."
            : "This recording has no markers. Drop one while recording with the flag on the bar."
    }
}
