import TimelineKit

/// The window round the picture, a see-through background, a gradient of one's own, and
/// the camera's motion blur — each one change, named for the Undo menu, reachable from the
/// Frame and Zoom panels and from the menu bar alike.
extension EditorModel {
    // MARK: - Window frame

    var windowChrome: WindowChrome { timeline.style.chrome }

    func setWindowChrome(_ kind: WindowChrome.Kind) {
        guard kind != timeline.style.chrome.kind else { return }
        apply(Commands.setWindowChrome(kind))
    }

    func setWindowAppearance(_ appearance: WindowChrome.Appearance) {
        guard appearance != timeline.style.chrome.appearance else { return }
        apply(Commands.setWindowAppearance(appearance))
    }

    // MARK: - Device frame

    func setDeviceFinish(_ finish: WindowChrome.Finish) {
        guard finish != timeline.style.chrome.finish else { return }
        apply(Commands.setDeviceFinish(finish))
    }

    func setDeviceOrientation(_ orientation: WindowChrome.Orientation) {
        guard orientation != timeline.style.chrome.orientation else { return }
        apply(Commands.setDeviceOrientation(orientation))
    }

    func setDeviceCamera(_ isShown: Bool) {
        guard isShown != timeline.style.chrome.showsCamera else { return }
        apply(Commands.setDeviceCamera(isShown))
    }

    // MARK: - Background

    var hasTransparentBackground: Bool { timeline.style.background.isTransparent }

    func makeBackgroundTransparent() {
        guard !hasTransparentBackground else { return }
        apply(Commands.makeBackgroundTransparent())
    }

    /// The gradient the editor is showing: the project's own if it has one, otherwise the
    /// one it would start from. See `FrameStyle.Background.editableGradient`.
    var editableGradient: BackgroundGradient { timeline.style.background.editableGradient }

    /// Whether the background is a gradient somebody built, rather than a stock one.
    var hasCustomGradient: Bool {
        if case .customGradient = timeline.style.background { return true }
        return false
    }

    func setBackgroundGradient(_ gradient: BackgroundGradient) {
        guard timeline.style.background != .customGradient(gradient) else { return }
        apply(Commands.setBackgroundGradient(gradient))
    }

    // MARK: - Camera motion blur

    var blursCameraMotion: Bool { timeline.camera.motionBlur }

    /// For every zoom in the project, like gliding: the camera is one camera.
    /// How quickly every zoom not set by hand goes in and out, and new ones too.
    func setZoomSpeed(_ speed: ZoomSpeed) {
        apply(Commands.setZoomSpeed(speed))
    }

    func setZoomMotionBlur(_ isOn: Bool) {
        guard isOn != timeline.camera.motionBlur else { return }
        apply(Commands.setZoomMotionBlur(isOn))
    }
}
