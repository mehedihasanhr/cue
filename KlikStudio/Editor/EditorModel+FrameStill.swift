import AppKit
import CoreMedia
import RenderKit
import TimelineKit
import UniformTypeIdentifiers

/// The frame at the playhead as a picture: on the pasteboard, or in a file.
///
/// Drawn by `FrameStill`, which is the export's renderer and the export's scale step, at
/// the size the export sheet is set to — so what is copied is one frame of the film
/// somebody would get by exporting, not a screenshot of the preview. The reading of the
/// recording is exact and full-size whatever the preview is doing at the time.
extension EditorModel {
    /// Puts the frame at the playhead on the pasteboard as an image.
    func copyFrame() {
        Task {
            guard let image = await still() else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects([NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))])
        }
    }

    /// Writes the frame at the playhead as a PNG, wherever the person says.
    func saveFrameAs() {
        let panel = NSSavePanel()
        panel.title = "Save Frame"
        // The moment in the name, with dots for the colons a file name cannot have.
        let moment = Timecode.precise(playhead).replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "\(name) at \(moment).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let image = await still(), let data = FrameStill.pngData(of: image) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                report(EditorProblem("The frame couldn't be written. \(error.localizedDescription)"))
            }
        }
    }

    /// The frame at the playhead, drawn as the export would draw it. `nil` after saying why.
    ///
    /// Stops playback first: reaching for a frame is reaching for a particular frame, and
    /// the one under a moving playhead is gone by the time it is drawn.
    private func still() async -> CGImage? {
        if isPlaying { togglePlayback() }
        guard let videoURL = document.videoURL else {
            report(EditorProblem("This recording's video file is missing."))
            return nil
        }
        // The size the export sheet is set to, which is what "the export size" means in
        // this app: the settings someone chose last are the ones the sheet will show.
        let settings = ExportModel().settings
        do {
            return try await FrameStill.render(timeline, at: playhead,
                                               builder: sceneBuilder,
                                               cursor: document.cursorTrack,
                                               videoURL: videoURL,
                                               webcamURL: document.webcamURL,
                                               packageURL: packageURL,
                                               fitting: settings)
        } catch {
            report(error)
            return nil
        }
    }
}
