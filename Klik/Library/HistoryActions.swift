import Foundation

/// Actions the island and the floating panel can trigger; wired by the AppDelegate.
struct HistoryActions {
    var captureFullScreen: () -> Void
    var captureArea: () -> Void
    var captureScrolling: () -> Void
    var captureText: () -> Void
    var pickColor: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    var preview: (CaptureItem) -> Void
    var edit: (CaptureItem) -> Void
    var copy: (CaptureItem) -> Void
    var delete: (CaptureItem) -> Void
}
