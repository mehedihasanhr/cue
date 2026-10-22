import AppKit
import BackgroundKit
import Foundation
import RenderKit
import TimelineKit
import UniformTypeIdentifiers

/// The picture turned in space, its colour corrected, and a background that moves — each
/// one change, named for the Undo menu, reachable from the Frame panel and from the menu
/// bar alike.
extension EditorModel {
    // MARK: - Perspective

    var perspective: FramePerspective { timeline.style.perspective }

    func setPerspective(_ perspective: FramePerspective, name: String = "Perspective") {
        guard perspective.sanitised != timeline.style.perspective else { return }
        apply(Commands.setPerspective(perspective, name: name))
    }

    func applyPerspectivePreset(_ preset: FramePerspective.Preset) {
        guard timeline.style.perspective.with(preset) != timeline.style.perspective else { return }
        apply(Commands.applyPerspectivePreset(preset))
    }

    func setStraightensWhenZoomed(_ isOn: Bool) {
        guard isOn != timeline.style.perspective.straightensWhenZoomed else { return }
        apply(Commands.setStraightensWhenZoomed(isOn))
    }

    // MARK: - Colour

    var colorGrade: ColorGrade { timeline.style.grade }

    func setColorGrade(_ grade: ColorGrade, name: String = "Colour") {
        guard grade.sanitised != timeline.style.grade else { return }
        apply(Commands.setColorGrade(grade, name: name))
    }

    func applyColorPreset(_ preset: ColorGrade.Preset) {
        guard timeline.style.grade.with(preset) != timeline.style.grade else { return }
        apply(Commands.applyColorPreset(preset))
    }

    /// Asks for a `.cube` file, copies it into the project and grades the picture with it.
    func loadLUT() {
        let panel = NSOpenPanel()
        panel.title = "Choose a LUT"
        panel.message = "A 3D .cube colour table. It changes the recording only."
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let lut = try CubeLUT.copy(url, into: packageURL)
            apply(Commands.setLUT(lut))
        } catch {
            report(error)
        }
    }

    func removeLUT() {
        guard timeline.style.grade.lut != nil else { return }
        apply(Commands.setLUT(nil))
    }

    // MARK: - Moving backgrounds

    var hasMovingBackground: Bool {
        if case .animated = timeline.style.background { return true }
        return false
    }

    var hasVideoBackground: Bool { timeline.style.background.videoPath != nil }

    func setAnimatedBackground(_ background: AnimatedBackground) {
        guard timeline.style.background != .animated(background) else { return }
        apply(Commands.setAnimatedBackground(background))
    }

    /// Asks for a movie, copies it into the project and loops it behind the picture.
    func chooseBackgroundVideo() {
        guard let url = BackgroundMovieImport.choose() else { return }
        let packageURL = packageURL
        Task {
            do {
                let path = try await BackgroundMovieImport.copy(url, into: packageURL)
                apply(Commands.setVideoBackground(path: path))
            } catch {
                report(error)
            }
        }
    }
}
