import CoreMedia
import Foundation
import RecordKit
import TimelineKit

/// The camera lane: stretches where the camera and the screen share the frame differently.
///
/// An extension in its own file, like the shortcuts, so the model's main file does not grow
/// a chapter for every lane. Everything here goes through `apply`, so it undoes like
/// anything else.
extension EditorModel {
    /// The layout region the playhead is in, where two overlap the one in force.
    var cameraLayoutAtPlayhead: CameraLayoutRegion? {
        timeline.cameraLayoutRegion(at: playhead)
    }

    /// The region the Camera menu and the panel act on: the one selected, or failing that
    /// the one under the playhead — the one being looked at.
    var activeCameraLayout: CameraLayoutRegion? {
        if case .cameraLayout(let id) = selection,
           let chosen = timeline.cameraLayouts.first(where: { $0.id == id }) {
            return chosen
        }
        return cameraLayoutAtPlayhead
    }

    /// Whether there is a camera to lay out: a recording made with the camera on.
    var canLayOutCamera: Bool { hasTrack(.webcam) }

    /// A stretch with its own layout, over the selected range if there is one and for a
    /// few seconds from the playhead if there is not — the same two readings of "here" that
    /// Hide Pointer over Selection makes, for its reason.
    ///
    /// - Returns: the new region's id, or `nil` when there was no room.
    @discardableResult
    func addCameraLayout(_ layout: CameraLayout) -> UUID? {
        let span: CMTimeRange
        if let range = selection.range(in: timeline), range.duration >= Clip.minimumDuration {
            span = range
        } else {
            let start = min(playhead, max(.zero, duration - Clip.minimumDuration))
            span = CMTimeRange(start: start, duration: min(CameraLayoutRegion.defaultDuration, duration - start))
        }
        // Only a timeline shorter than the shortest region has no room, and then there is
        // nothing to say: the item simply does nothing, as Add Shortcut does.
        guard span.duration >= Clip.minimumDuration else { return nil }
        let region = CameraLayoutRegion(start: span.start, duration: span.duration, layout: layout)
        apply(Commands.AddCameraLayout(region))
        guard timeline.cameraLayouts.contains(where: { $0.id == region.id }) else { return nil }
        select(.cameraLayout(region.id))
        return region.id
    }

    /// What a drag on the bubble changes.
    enum CameraPlacementTarget: Equatable {
        /// The panel's settings: the whole video, before any move has been made.
        case panel
        /// One move on the camera lane.
        case move(UUID)
    }

    /// Where the bubble is at the playhead, in the terms a drag works in.
    var cameraPlacementAtPlayhead: CameraPlacement? {
        guard let rect = webcamRect else { return nil }
        return CameraPlacement(centre: CGPoint(x: rect.midX, y: rect.midY),
                               size: timeline.webcamSize(at: playhead))
    }

    /// Starts moving or resizing the bubble at the playhead, and says what the drag changes.
    ///
    /// A drag at a new moment is a new move, which is how the camera comes to move many
    /// times over a video. At the very start, with nothing there yet, it is the panel's own
    /// place, which is where the whole video begins. Right at an existing move it adjusts
    /// that one (`Commands.PlaceCamera` decides), and the playhead steps onto the frame where
    /// the glide has finished, so what is being dragged is where the bubble ends up.
    func beginPlacingCamera() -> CameraPlacementTarget? {
        guard let current = cameraPlacementAtPlayhead else { return nil }
        if isPlaying { togglePlayback() }
        if playhead.seconds < 0.05, cameraLayoutAtPlayhead == nil { return .panel }
        let id = UUID()
        apply(Commands.PlaceCamera(id: id, at: playhead, placement: current))
        guard let move = timeline.cameraLayouts.last(where: {
            $0.placement != nil && $0.start <= playhead && playhead < $0.end
        }) ?? timeline.cameraLayouts.first(where: { $0.id == id }) else { return nil }
        select(.cameraLayout(move.id))
        if !timeline.cameraPlacement(at: playhead).isSteady {
            let glide = CMTime(seconds: min(Timeline.cameraMoveTransition, move.duration.seconds / 2),
                               preferredTimescale: 600)
            let inFirstHalf = playhead - move.start < CMTimeMultiplyByFloat64(move.duration, multiplier: 0.5)
            scrub(to: inFirstHalf ? move.start + glide : move.end - glide)
        }
        return .move(move.id)
    }

    /// Where a drag began from: the place it changes, read from the model rather than from
    /// the frame on screen, which may not have caught up with a move just made.
    func cameraPlacement(of target: CameraPlacementTarget) -> CameraPlacement? {
        switch target {
        case .panel: cameraPlacementAtPlayhead
        case .move(let id): timeline.cameraLayouts.first { $0.id == id }?.placement
        }
    }

    /// Puts the bubble where a drag has got to.
    func placeCamera(_ target: CameraPlacementTarget, centre: CGPoint? = nil, size: Double? = nil) {
        let centre = centre.map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
        let size = size.map { min(0.6, max(0.05, $0)) }
        switch target {
        case .panel:
            apply(Commands.Restyle("Move Camera") {
                if let centre {
                    $0.webcam.corner = .custom
                    $0.webcam.position = centre
                }
                if let size { $0.webcam.size = size }
            })
        case .move(let id):
            guard var placement = timeline.cameraLayouts.first(where: { $0.id == id })?.placement else { return }
            if let centre { placement.centre = centre }
            if let size { placement.size = size }
            apply(Commands.SetCameraPlacement(id: id, placement: placement))
        }
    }

    /// Hands a stretch's bubble back to the Webcam panel.
    func clearCameraPlacement(_ id: UUID) {
        apply(Commands.SetCameraPlacement(id: id, placement: nil))
    }

    /// Changes what one stretch does.
    func setCameraLayout(_ id: UUID, to layout: CameraLayout) {
        apply(Commands.SetCameraLayout(id: id, layout: layout))
    }

    /// Hides the camera wherever nobody speaks for at least `minimum` seconds, as one
    /// step Undo takes back.
    ///
    /// Read from the voice — the first microphone, or the recording's own sound when the
    /// voice is in the video file — and only where the camera lane is empty: a stretch that
    /// already has a layout was set by hand and is left alone.
    func hideCameraDuringSilence(minimum: Double = SilenceFinder.defaultMinimum) {
        let manifest = document.manifest
        guard let voice = manifest.tracks(.microphone).first ?? manifest.audioTracks.first else {
            report(CameraSilenceError.noVoice)
            return
        }
        let url = document.package.url.appendingPathComponent(voice.path)
        Task { @MainActor in
            guard let peaks = try? await WaveformBuilder().peaks(of: url) else {
                report(CameraSilenceError.unreadable)
                return
            }
            let hidden = SilenceFinder.cameraHidden(in: SilenceFinder.silences(in: peaks, minimum: minimum))
                .flatMap { timeline.timelineRanges(ofSource: $0) }
                .filter { range in
                    !timeline.cameraLayouts.contains { !CMTimeRange(start: $0.start, duration: $0.duration).intersection(range).isEmpty }
                }
            guard !hidden.isEmpty else {
                report(CameraSilenceError.noneFound(minimum))
                return
            }
            let regions = hidden.map { CameraLayoutRegion(start: $0.start, duration: $0.duration, layout: .hidden) }
            apply(Commands.Restyle("Hide Camera During Silence") { timeline in
                timeline.cameraLayouts.append(contentsOf: regions)
                timeline.cameraLayouts.sort { $0.start < $1.start }
            })
        }
    }

    /// Takes the whole lane away: the bubble everywhere again.
    func removeAllCameraLayouts() {
        guard !timeline.cameraLayouts.isEmpty else { return }
        apply(Commands.RemoveCameraLayouts())
        if case .cameraLayout = selection { clearSelection() }
    }

    /// Switches the camera on or off for the whole video.
    func toggleCamera() {
        let showing = !timeline.webcam.isEnabled
        apply(Commands.Restyle(showing ? "Turn Camera On" : "Turn Camera Off") { $0.webcam.isEnabled = showing })
    }

    /// What happens to the room behind the person.
    func setCameraBackground(_ background: WebcamSettings.Background) {
        guard timeline.webcam.background != background else { return }
        apply(Commands.Restyle("Camera Background") { $0.webcam.background = background })
    }

    /// Puts the camera's crop back to the whole picture, centred.
    func resetCameraCrop() {
        guard timeline.webcam.crop != WebcamCrop() else { return }
        apply(Commands.Restyle("Reset Camera Framing") { $0.webcam.crop = WebcamCrop() })
    }
}

enum CameraSilenceError: LocalizedError {
    case noVoice
    case unreadable
    case noneFound(Double)

    var errorDescription: String? {
        switch self {
        case .noVoice: "This recording has no voice to listen for silences in."
        case .unreadable: "The voice in this recording couldn't be read."
        case .noneFound(let minimum): "No silences of \(Int(minimum)) seconds or more where the camera lane is free."
        }
    }
}
