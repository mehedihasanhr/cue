import Foundation

/// What a new task can be started from: its description holds it, below an empty first
/// line for the title.
enum TaskSeed {
    /// PNG data of a picture (a capture, edited or not; a copied image).
    case image(Data)
    case text(String)
    /// A file: a picture goes in as an image, anything else as an attachment.
    case file(URL)
}

/// Actions the island and the floating panel can trigger; wired by the AppDelegate.
struct HistoryActions {
    var captureFullScreen: () -> Void
    var captureArea: () -> Void
    var captureWindow: () -> Void = {}
    var captureScrolling: () -> Void
    var captureText: () -> Void
    var pickColor: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    var preview: (CaptureItem) -> Void
    var edit: (CaptureItem) -> Void
    var copy: (CaptureItem) -> Void
    /// The capture's dominant colors, most common first.
    var palette: (CaptureItem) -> [PickedColor] = { _ in [] }
    var delete: (CaptureItem) -> Void
    /// Keeps the capture floating above every window.
    var pinToScreen: (CaptureItem) -> Void = { _ in }
    /// Uploads it and copies the link (Settings › Sharing).
    var shareLink: (CaptureItem) -> Void = { _ in }
    /// A new task with the capture attached.
    var makeTask: (CaptureItem) -> Void = { _ in }
    /// A new task in the floating form, started from anything a card holds.
    var createTask: (TaskSeed) -> Void = { _ in }
    /// Lays other images beside the capture, keeps the comparison and copies it.
    var compare: (CaptureItem, [CapturedImage]) -> Void = { _, _ in }
    /// Opens a clipboard image in the editor, as a capture of its own.
    var editClipboardImage: (ClipboardItem) -> Void = { _ in }
}
