import Foundation
import Observation

/// One open editor: the recording it is showing, and the state that belongs to the
/// window rather than to the document.
///
/// Held by the window controller instead of living in `@State` inside the view, because
/// the menu bar has to reach the front editor and a view's private state is reachable
/// from nowhere. The document itself stays where it was — this is the window's business
/// only: what has loaded, what went wrong loading it, and whether the export sheet is up.
@MainActor
@Observable
final class EditorSession {
    /// The recording this window is for, and the identity the window is keyed by.
    let packageURL: URL

    /// `nil` until the recording has been read, which happens in the view because that is
    /// where a slow open belongs — behind a progress spinner rather than a beachball.
    var model: EditorModel?
    var loadError: String?
    var isExporting = false

    init(packageURL: URL) {
        self.packageURL = packageURL
    }
}
