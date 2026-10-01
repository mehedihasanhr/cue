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
    /// Whether the export sheet opens on the selected stretch rather than the whole
    /// edit. Set by the menu item that asked for the sheet, read by the sheet as it opens.
    var exportsSelection = false

    /// Whether the inspector column is showing.
    ///
    /// The window's business rather than the document's — hiding it gives the picture the
    /// width, and says nothing about the edit — so it is here, where the menu bar can reach
    /// it, and not on `EditorModel`. Remembered for the next window too: somebody who works
    /// with the panel put away has decided how they like the editor, not how they like this
    /// one recording.
    var showsInspector: Bool = EditorSession.storedShowsInspector {
        didSet { UserDefaults.standard.set(showsInspector, forKey: Self.showsInspectorKey) }
    }

    private static let showsInspectorKey = "editor.showsInspector"

    private static var storedShowsInspector: Bool {
        UserDefaults.standard.object(forKey: showsInspectorKey) as? Bool ?? true
    }

    init(packageURL: URL) {
        self.packageURL = packageURL
    }
}
