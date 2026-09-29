import CoreMedia
import Foundation
import TimelineKit

extension EditorModel {
    /// Lays a picture over the video.
    ///
    /// As a picture it goes in the middle, at the playhead, for as long as anything drawn
    /// on the picture lasts. As a logo it goes in the corner for the whole video, because
    /// that is what a logo is for — and finding the end of the timeline to stretch it
    /// there is the first thing anybody would otherwise have to do.
    func addPicture(asLogo: Bool) {
        guard let url = OverlayImport.choose(title: asLogo ? "Choose a Logo" : "Choose a Picture") else { return }
        do {
            let imported = try OverlayImport.copy(url, into: packageURL)
            tool = .annotate
            let rect = AnnotationItem.pictureRect(pixelSize: imported.pixelSize, frame: outputSize, asLogo: asLogo)
            // A logo is there from the first frame to the last. Fading in, it would be
            // missing from the first frame — which is the one used as the thumbnail.
            addAnnotation(.image(path: imported.path), rect: rect,
                          during: asLogo ? (.zero, duration) : nil,
                          animation: asLogo ? AnnotationAnimation(entrance: .none, exit: .none) : nil,
                          named: asLogo ? "Add Logo" : "Add Picture")
        } catch {
            report(error)
        }
    }

    /// Puts another picture in the place of this one, keeping its place, size, timing and
    /// animation — everything but the picture.
    func replacePicture(ofAnnotation id: UUID) {
        guard let url = OverlayImport.choose(title: "Choose a Picture") else { return }
        do {
            let imported = try OverlayImport.copy(url, into: packageURL)
            restyleAnnotation(id, "Replace Picture") { $0.kind = .image(path: imported.path) }
        } catch {
            report(error)
        }
    }
}

extension AnnotationItem {
    var isPicture: Bool {
        if case .image = kind { true } else { false }
    }

    /// The picture's file, relative to the project, for a picture.
    var picturePath: String? {
        if case .image(let path) = kind { path } else { nil }
    }
}

extension OverlayImport {
    /// Pictures in the project's folder that nothing in `paths` names.
    static func unused(in packageURL: URL, keeping paths: Set<String>) -> [URL] {
        let folder = packageURL.appendingPathComponent(folderName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { !paths.contains("\(folderName)/\($0.lastPathComponent)") }
    }
}

extension EditorModel {
    /// Deletes pictures the saved edit no longer shows.
    ///
    /// Only as the window closes, and only when everything is saved: until then the undo
    /// stack can bring back a picture that was deleted, and it has to find its file.
    func pruneUnusedPictures() {
        let kept = Set(timeline.annotations.compactMap(\.picturePath))
        for url in OverlayImport.unused(in: packageURL, keeping: kept) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
