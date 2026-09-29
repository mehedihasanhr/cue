import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// The picture turned in space, its colour corrected, and the moment a moving background
/// is at — laid on a described frame, from the timeline and the time and nothing else.
extension SceneBuilder {
    /// Every one of the three is `nil` or unchanged for a project that uses none of them,
    /// so its frame is described exactly as it was before they existed.
    func dressingLook(_ scene: SceneDescriptor, _ timeline: Timeline, at time: CMTime) -> SceneDescriptor {
        var scene = scene
        let style = timeline.style
        scene.perspective = perspectiveLayer(style.perspective, zoom: scene.zoom)
        scene.grade = gradeLayer(style.grade)
        // The finished video's own clock, not the recording's: a background runs straight
        // through cuts, speed changes and freeze frames rather than jumping with them.
        if scene.background.moves {
            scene.background = scene.background.at(time: max(0, time.seconds))
        }
        return scene
    }

    /// How much of the way flat a zoom has turned the picture, 0…1, for a camera `zoom`
    /// times in.
    ///
    /// Read off the camera's zoom at this moment rather than off a region, so it follows
    /// the camera exactly: through a glide between two zooms, through a zoom kept in
    /// between two close ones, and out again, with no second idea of when the camera is in.
    /// Fully flat by a third of the way to 2×, which every zoom anybody draws reaches, and
    /// eased at both ends so the turn starts and settles softly.
    static func straightening(forZoom zoom: Double) -> Double {
        let progress = min(1, max(0, (zoom - 1) / 0.35))
        return progress * progress * (3 - 2 * progress)
    }

    func perspectiveLayer(_ perspective: FramePerspective, zoom: Double) -> PerspectiveLayer? {
        let held = perspective.sanitised
        guard !held.isFlat else { return nil }
        let kept = held.straightensWhenZoomed ? 1 - Self.straightening(forZoom: zoom) : 1
        guard kept > 0.0005 else { return nil }
        return PerspectiveLayer(turn: held.turn * kept, lean: held.lean * kept,
                                rotation: held.rotation * kept, depthShadow: held.depthShadow)
    }

    func gradeLayer(_ grade: ColorGrade) -> GradeLayer? {
        let held = grade.sanitised
        guard !held.isNeutral else { return nil }
        return GradeLayer(brightness: held.brightness,
                          contrast: held.contrast,
                          saturation: held.saturation,
                          temperature: held.temperature,
                          tint: held.tint,
                          // A table at no strength is no table: nothing to open.
                          lut: held.lutIntensity > 0.001
                              ? held.lut.map { DefaultBackgroundResolver.url(forPath: $0.path, packageURL: packageURL) }
                              : nil,
                          lutIntensity: held.lutIntensity)
    }
}
