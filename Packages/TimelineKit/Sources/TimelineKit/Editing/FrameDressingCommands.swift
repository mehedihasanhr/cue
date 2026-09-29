import Foundation

public extension Commands {
    /// Putting a window round the picture, taking it away, or changing its kind.
    ///
    /// Named here rather than at each call site, because the panel and the Frame menu both
    /// make this change and the Undo menu has to say the same thing whichever was used.
    static func setWindowChrome(_ kind: WindowChrome.Kind) -> Restyle {
        Restyle(kind == .none ? "Remove Window Frame" : "Window Frame") { $0.style.chrome.kind = kind }
    }

    /// Light or dark title bar.
    static func setWindowAppearance(_ appearance: WindowChrome.Appearance) -> Restyle {
        Restyle("Window Appearance") { $0.style.chrome.appearance = appearance }
    }

    /// Nothing behind the picture at all.
    static func makeBackgroundTransparent() -> Restyle {
        Restyle("Transparent Background") { $0.style.background = .transparent }
    }

    /// A gradient of one's own, whole. One name for every change to it — a colour, the
    /// angle, the shape — because to the person making it they are all "the gradient".
    static func setBackgroundGradient(_ gradient: BackgroundGradient) -> Restyle {
        Restyle("Gradient") { $0.style.background = .customGradient(gradient) }
    }

    /// Softening the picture while the camera moves fast, for every zoom in the project.
    static func setZoomMotionBlur(_ isOn: Bool) -> Restyle {
        Restyle(isOn ? "Turn On Zoom Motion Blur" : "Turn Off Zoom Motion Blur") { $0.camera.motionBlur = isOn }
    }
}

public extension FrameStyle.Background {
    /// The gradient to start editing from: this one if it is already a gradient of one's
    /// own, the two colours of a stock gradient if it is one of those, and the default
    /// otherwise — so opening the editor on a stock gradient changes nothing until a
    /// colour is.
    var editableGradient: BackgroundGradient {
        switch self {
        case .customGradient(let gradient):
            return gradient
        case .gradient(let from, let to, let angle):
            return BackgroundGradient(stops: [BackgroundGradient.Stop(color: from, location: 0),
                                              BackgroundGradient.Stop(color: to, location: 1)],
                                      shape: .linear,
                                      angle: angle)
        case .color, .image, .wallpaper, .transparent, .animated, .video:
            return BackgroundGradient()
        }
    }

    /// Whether nothing is drawn behind the picture.
    var isTransparent: Bool {
        if case .transparent = self { return true }
        return false
    }
}
