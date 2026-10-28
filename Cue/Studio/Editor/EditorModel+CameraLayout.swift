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
