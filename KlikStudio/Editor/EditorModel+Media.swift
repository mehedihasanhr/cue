import AppKit
import CoreMedia
import Foundation
import RenderKit
import TimelineKit
import UniformTypeIdentifiers

/// More than one source in a project: movies and other takes brought in, subtitles read
/// in, and chapters written out.
extension EditorModel {
    // MARK: - Movies

    /// Brings a movie file in, at the start, the playhead or the end.
    func addVideo() {
        guard let choice = MovieImport.chooseVideo() else { return }
        bringIn(choice, recording: false)
    }

    /// Brings another take's screen and sound in, at the start, the playhead or the end.
    func addRecording() {
        guard let choice = MovieImport.chooseRecording(near: packageURL) else { return }
        bringIn(choice, recording: true)
    }

    /// Copies the file in, then adds its clip as one step — and leaves it selected, with
    /// the playhead on it, so what arrived is what the preview shows.
    ///
    /// The playhead is read when the file has arrived rather than when it was chosen: a
    /// copy can take a while, and the edit may have moved on meanwhile.
    private func bringIn(_ choice: MovieImport.Choice, recording: Bool) {
        let packageURL = packageURL
        Task {
            do {
                let file = recording
                    ? try await MovieImport.copyRecording(choice.url, into: packageURL)
                    : try await MovieImport.copyVideo(choice.url, into: packageURL)
                let time: CMTime = switch choice.place {
                case .start: .zero
                case .playhead: playhead
                case .end: duration
                }
                let command = Commands.AddMedia(file, at: time)
                let before = timeline
                apply(command)
                guard timeline != before else {
                    report(EditorProblem("That movie couldn't be added to the timeline."))
                    return
                }
                select(.clip(command.clip.id))
                if let index = timeline.clips.firstIndex(where: { $0.id == command.clip.id }) {
                    scrub(to: timeline.start(ofClipAt: index))
                }
            } catch {
                report(error)
            }
        }
    }

    /// The filmstrip for a clip: the recording's, or the movie it plays.
    func thumbnails(for clip: Clip) -> ClipThumbnails {
        guard let source = clip.source else { return thumbnails }
        let file = timeline.media(for: clip)
            ?? MediaFile(path: source, name: (source as NSString).lastPathComponent, duration: .zero,
                         pixelSize: .zero, hasSound: false)
        return importedMedia.thumbnails(for: file)
    }

    /// What the clip lane calls an imported clip: the name of the file it came from.
    func mediaName(of clip: Clip) -> String? {
        guard let source = clip.source else { return nil }
        return timeline.media(for: clip)?.name ?? (source as NSString).lastPathComponent
    }

    /// Takes the movies nothing names any more out of the package. Only once the window is
    /// closing with nothing to undo — the same rule the pictures keep — because until then
    /// an undo may want one back.
    func pruneUnusedMovies() {
        let kept = Set(timeline.media.map(\.path) + timeline.clips.compactMap(\.source))
        for url in MovieImport.unused(in: packageURL, keeping: kept) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Subtitles

    /// Reads a SubRip or WebVTT file into the captions, in place of the ones there, as one
    /// step Undo takes back.
    func importSubtitles() {
        let panel = NSOpenPanel()
        panel.title = "Import Subtitles"
        panel.message = "A SubRip (.srt) or WebVTT (.vtt) file timed to this video. It replaces the captions."
        panel.prompt = "Import"
        panel.allowedContentTypes = ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let parsed = try SubtitleImport.parse(try Data(contentsOf: url))
            let cues = try SubtitleImport.captions(from: parsed, within: duration)
            apply(Commands.ImportSubtitles(cues))
            if parsed.skipped > 0 {
                report(EditorProblem(parsed.skipped == 1
                    ? "One line of the file had a time that couldn't be read, and was left out."
                    : "\(parsed.skipped) lines of the file had times that couldn't be read, and were left out."))
            }
        } catch let failure as SubtitleImport.Failure {
            report(failure)
        } catch {
            report(EditorProblem("That file couldn't be read. \(error.localizedDescription)"))
        }
    }

    // MARK: - Chapters

    /// The video's chapters, from the recording's markers and the title slides.
    var chapters: [Chapter] {
        Chapters.list(for: timeline, markers: markerTimes)
    }

    /// Why the chapters would not show on YouTube, or `nil` when they would.
    var youTubeChaptersProblem: Chapters.Problem? {
        Chapters.youTubeProblem(chapters, duration: duration)
    }

    /// Whether there is anything to write: more than the "Intro" every video starts with.
    var hasChapters: Bool { !Chapters.isOnlyIntro(chapters) }

    /// Puts the chapters on the pasteboard, as a YouTube description lists them.
    func copyYouTubeChapters() {
        guard youTubeChaptersProblem == nil else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(Chapters.text(chapters), forType: .string)
    }

    /// Writes the chapters to a text file, one `0:00 Title` to a line.
    func exportChapters() {
        guard hasChapters else { return }
        let panel = NSSavePanel()
        panel.title = "Export Chapters"
        panel.nameFieldStringValue = "\(name) chapters.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (Chapters.text(chapters) + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            report(EditorProblem("The chapters couldn't be written. \(error.localizedDescription)"))
        }
    }
}
