import AppKit
import CoreMedia
import Foundation
import RecordKit
import RenderKit
import TimelineKit
import UniformTypeIdentifiers

/// Bringing a movie into a project: any video file, or the screen of another recording.
///
/// Copied in, for the reason sounds and pictures are: a project that points at a file
/// somewhere else stops working the moment it is moved, sent or backed up. The copy goes in
/// the package's `Movies` folder under a fresh name, and the timeline records what it
/// measured — see `MediaFile`.
enum MovieImport {
    /// What to put in and where: the file chosen, and the place picked beside it.
    struct Choice {
        let url: URL
        let place: EditorModel.TitlePlace
    }

    nonisolated enum Failure: Error, LocalizedError {
        case notARecording
        case sameRecording
        case noScreen

        var errorDescription: String? {
            switch self {
            case .notARecording: "That isn't a Klik recording. Choose a file ending in .klikrec."
            case .sameRecording: "That is the recording already open. Choose another take."
            case .noScreen: "That recording has no screen video in it."
            }
        }
    }

    /// Where the last movie went, so the next one is offered the same place.
    @MainActor private static var lastPlace: EditorModel.TitlePlace = .end

    /// Asks for a movie file, and where in the edit it goes.
    @MainActor
    static func chooseVideo() -> Choice? {
        let panel = NSOpenPanel()
        panel.title = "Add Video"
        panel.message = "A movie to play in the edit. It is copied into the project."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return run(panel)
    }

    /// Asks for another recording, and where in the edit its screen goes.
    ///
    /// A `.klikrec` is a *package* to the open panel: the app exports its type as one (see
    /// `StudioInfo.plist`), so the panel shows it as a single file. Asking for folders only
    /// — as this once did, on the belief that no type was declared — greyed out every
    /// recording, and Add Recording could never add one. Files of the recording's type are
    /// what can be chosen; folders stay choosable too, for a Mac where Launch Services has
    /// not registered the type and a recording is still a plain folder. Anything that turns
    /// out not to be a recording is refused after, with a reason.
    @MainActor
    static func chooseRecording(near package: URL) -> Choice? {
        let panel = NSOpenPanel()
        panel.title = "Add Recording"
        panel.message = "Another take, to play in this one. Its screen and sound are copied into the project; its pointer and clicks stay behind."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType("com.stackrover.klik.recording")
            ?? UTType(filenameExtension: RecordingPackage.fileExtension, conformingTo: .package)
            ?? .package]
        panel.allowsMultipleSelection = false
        panel.directoryURL = package.deletingLastPathComponent()
        return run(panel)
    }

    @MainActor
    private static func run(_ panel: NSOpenPanel) -> Choice? {
        let places = NSPopUpButton(frame: .zero, pullsDown: false)
        let choices = EditorModel.TitlePlace.allCases
        places.addItems(withTitles: choices.map(\.menuTitle))
        places.selectItem(at: choices.firstIndex(of: lastPlace) ?? choices.count - 1)
        let label = NSTextField(labelWithString: "Put it:")
        let row = NSStackView(views: [label, places])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let place = choices.indices.contains(places.indexOfSelectedItem) ? choices[places.indexOfSelectedItem] : .end
        lastPlace = place
        return Choice(url: url, place: place)
    }

    // MARK: - Copying

    /// Copies a movie file into the package and measures it.
    ///
    /// Off the main thread: a movie can be gigabytes, and the editor should go on drawing
    /// while it copies.
    @concurrent nonisolated static func copyVideo(_ url: URL, into packageURL: URL) async throws -> MediaFile {
        // Measured before anything is copied, so a file that is not a movie costs nothing.
        let measured = try await MediaImport.measure(url)
        let (destination, path) = try place(extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension,
                                            in: packageURL)
        try FileManager.default.copyItem(at: url, to: destination)
        return MediaFile(path: path, name: url.lastPathComponent, duration: measured.duration,
                         pixelSize: measured.pixelSize, hasSound: measured.hasSound, kind: .video)
    }

    /// Copies another take's screen, and its sound, into the package as one movie.
    ///
    /// The take as it was recorded, not as it was edited: its own cuts, zooms and captions
    /// were made against its own clock, which this project does not keep. Its pointer and
    /// clicks stay behind for the same reason — see `MediaFile.Kind.recording`.
    @concurrent nonisolated static func copyRecording(_ url: URL, into packageURL: URL) async throws -> MediaFile {
        guard url.pathExtension == RecordingPackage.fileExtension else { throw Failure.notARecording }
        guard url.standardizedFileURL != packageURL.standardizedFileURL else { throw Failure.sameRecording }
        let other = RecordingPackage(url: url)
        guard let manifest = try? other.readManifest() else { throw Failure.notARecording }
        guard let screen = manifest.track(.screen) else { throw Failure.noScreen }
        let picture = other.url.appendingPathComponent(screen.path)
        let sounds = manifest.audioTracks.map { other.url.appendingPathComponent($0.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }

        let (destination, path) = try place(extension: "mov", in: packageURL)
        if sounds.isEmpty {
            // A take recorded before the sources were separate carries its sound inside
            // the screen's file already.
            try FileManager.default.copyItem(at: picture, to: destination)
        } else {
            try await MediaImport.combine(picture: picture, sounds: sounds, into: destination)
        }
        do {
            let measured = try await MediaImport.measure(destination)
            return MediaFile(path: path, name: manifest.name, duration: measured.duration,
                             pixelSize: measured.pixelSize, hasSound: measured.hasSound, kind: .recording)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// A fresh name in the package's movies folder: two `clip.mov`s from two folders are
    /// two different movies, and one must not replace the other.
    nonisolated private static func place(extension pathExtension: String, in packageURL: URL) throws -> (URL, String) {
        let folder = packageURL.appendingPathComponent(MediaFile.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(pathExtension)"
        return (folder.appendingPathComponent(name), "\(MediaFile.folderName)/\(name)")
    }

    /// The movies in a package that the edit no longer names, for tidying up when a window
    /// closes with nothing left to undo.
    nonisolated static func unused(in packageURL: URL, keeping kept: Set<String>) -> [URL] {
        let folder = packageURL.appendingPathComponent(MediaFile.folderName, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else {
            return []
        }
        return names
            .filter { !kept.contains("\(MediaFile.folderName)/\($0)") }
            .map { folder.appendingPathComponent($0) }
    }
}
