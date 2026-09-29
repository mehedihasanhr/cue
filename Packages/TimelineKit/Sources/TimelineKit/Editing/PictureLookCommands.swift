import Foundation

/// The picture turned in space, its colour corrected, and a background that moves — each
/// one change, named for the Undo menu, whether it came from the Frame panel or the menu.
public extension Commands {
    /// The whole perspective at once: a preset, a slider, the toggle. Held to what can be
    /// drawn on the way in, so the panel and a file can never disagree about the angles.
    static func setPerspective(_ perspective: FramePerspective, name: String = "Perspective") -> Restyle {
        let held = perspective.sanitised
        return Restyle(name) { $0.style.perspective = held }
    }

    /// One of the named angles, keeping the depth shadow and the zoom behaviour.
    static func applyPerspectivePreset(_ preset: FramePerspective.Preset) -> Restyle {
        Restyle(preset == .flat ? "Flatten Picture" : "Perspective: \(preset.title)") {
            $0.style.perspective = $0.style.perspective.with(preset)
        }
    }

    /// Whether zooming in turns the picture square-on.
    static func setStraightensWhenZoomed(_ isOn: Bool) -> Restyle {
        Restyle(isOn ? "Straighten While Zoomed In" : "Keep Tilt While Zoomed In") {
            $0.style.perspective.straightensWhenZoomed = isOn
        }
    }

    /// The colour correction, whole.
    static func setColorGrade(_ grade: ColorGrade, name: String = "Colour") -> Restyle {
        let held = grade.sanitised
        return Restyle(name) { $0.style.grade = held }
    }

    /// One of the named corrections. A loaded table stays where it is.
    static func applyColorPreset(_ preset: ColorGrade.Preset) -> Restyle {
        Restyle(preset == .none ? "Reset Colour" : "Colour: \(preset.title)") {
            $0.style.grade = $0.style.grade.with(preset)
        }
    }

    /// A `.cube` table already copied into the project, or `nil` to take it away.
    static func setLUT(_ lut: LUTReference?) -> Restyle {
        Restyle(lut == nil ? "Remove LUT" : "Load LUT") {
            $0.style.grade.lut = lut
            if lut != nil { $0.style.grade.lutIntensity = 1 }
        }
    }

    /// A background that moves.
    static func setAnimatedBackground(_ background: AnimatedBackground) -> Restyle {
        Restyle("Moving Background") { $0.style.background = .animated(background) }
    }

    /// A movie already copied into the project, played on a loop behind the picture.
    static func setVideoBackground(path: String) -> Restyle {
        Restyle("Background Video") { $0.style.background = .video(path: path) }
    }
}

public extension FrameStyle.Background {
    /// The moving background to start from: this one if it already is one, otherwise the
    /// default, so switching to Motion keeps the project's colours until a palette is picked.
    var editableAnimation: AnimatedBackground {
        if case .animated(let animation) = self { return animation }
        return AnimatedBackground()
    }

    /// The movie a background plays, if it plays one.
    var videoPath: String? {
        if case .video(let path) = self { return path }
        return nil
    }
}
