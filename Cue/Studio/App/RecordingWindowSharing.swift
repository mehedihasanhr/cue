import AppKit

extension NSWindow.SharingType {
    /// For the windows that accompany a recording: the camera bubble, the speaker notes and
    /// Quick Share.
    ///
    /// Left out of other apps' captures in a release, so they stay out of a screen shared in
    /// a call. In a development build they can be captured, so they can be screenshotted
    /// while working on them. Recordings leave them out either way: a display or area
    /// recording excludes every window this app owns.
    static var recordingWindow: NSWindow.SharingType {
        #if DEBUG
        .readOnly
        #else
        .none
        #endif
    }
}
