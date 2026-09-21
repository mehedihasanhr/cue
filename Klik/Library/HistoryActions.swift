import Foundation

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
    /// Opens a clipboard image in the editor, as a capture of its own.
    var editClipboardImage: (ClipboardItem) -> Void = { _ in }
}
