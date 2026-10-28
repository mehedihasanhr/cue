import SwiftUI
import TimelineKit

/// The File menu's items for bringing movies in and writing chapters out, and the
/// Captions menu's for reading subtitles in.
extension EditorCommands {
    private var mediaEditor: EditorModel? { windows.menuTarget?.model }

    /// Beside Save Frame As…, in File: things that come into the project from a file.
    @ViewBuilder
    var mediaItems: some View {
        Button("Add Video") { mediaEditor?.addVideo() }
            .disabled(mediaEditor == nil)
            .help("Copy a movie into the project and play it at the start, the playhead or the end.")
        Button("Add Recording") { mediaEditor?.addRecording() }
            .disabled(mediaEditor == nil)
            .help("Copy another take's screen and sound into the project. Its pointer and clicks stay behind.")
    }

    /// Below them, in File: the chapters, for a video's description.
    @ViewBuilder
    var chapterItems: some View {
        let problem = mediaEditor?.youTubeChaptersProblem
        Button("Copy YouTube Chapters") { mediaEditor?.copyYouTubeChapters() }
            .disabled(mediaEditor == nil || problem != nil)
            .help(problem?.reason
                  ?? "Put “0:00 Intro” and a line for every marker and title slide on the pasteboard, for the video's description.")
        Button("Export Chapters") { mediaEditor?.exportChapters() }
            .disabled(mediaEditor?.hasChapters != true)
            .help(mediaEditor?.hasChapters == true
                  ? "Write the chapters to a text file, one “0:00 Title” to a line."
                  : "There are no chapters yet. Drop markers while recording or add title slides to mark where parts begin.")
    }

    /// In Captions, beside the exports it is the other half of.
    @ViewBuilder
    var subtitleImportItem: some View {
        Button("Import Subtitles") { mediaEditor?.importSubtitles() }
            .disabled(mediaEditor == nil)
            .help("Read a SubRip (.srt) or WebVTT (.vtt) file into the captions, in place of the ones there.")
    }
}
