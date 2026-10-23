import Foundation
import os

/// The app was called Klik before it was Cue. Its pictures and recordings were kept in
/// ~/Pictures/Klik and ~/Movies/Klik Studio, and its recordings were `.klikrec`
/// packages; this moves them to where Cue looks, once, before anything opens them.
/// What is in the old app's own container (clipboard, notes, tasks) stays there: the
/// sandbox lets Cue see only its own.
nonisolated enum LegacyFolders {
    static func moveIfNeeded() {
        let files = FileManager.default
        if let pictures = files.urls(for: .picturesDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() {
            move(pictures.appendingPathComponent("Klik", isDirectory: true),
                 to: pictures.appendingPathComponent("Cue", isDirectory: true))
        }
        if let movies = files.urls(for: .moviesDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath() {
            move(movies.appendingPathComponent("Klik Studio", isDirectory: true),
                 to: movies.appendingPathComponent("Cue Studio", isDirectory: true))
        }
    }

    /// Everything in `old` into `new`, a recording renamed to Cue's extension; a name
    /// `new` already has is left where it was. `old` goes once it is empty.
    private static func move(_ old: URL, to new: URL) {
        let files = FileManager.default
        guard let items = try? files.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        do {
            try files.createDirectory(at: new, withIntermediateDirectories: true)
        } catch {
            Log.app.error("Couldn't make \(new.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        for item in items {
            var name = item.lastPathComponent
            if item.pathExtension == "klikrec" {
                name = item.deletingPathExtension().appendingPathExtension("cuerec").lastPathComponent
            }
            let target = new.appendingPathComponent(name)
            guard !files.fileExists(atPath: target.path) else { continue }
            do {
                try files.moveItem(at: item, to: target)
            } catch {
                Log.app.error("Couldn't move \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let left = (try? files.contentsOfDirectory(atPath: old.path)) ?? []
        if left.allSatisfy({ $0 == ".DS_Store" }) { try? files.removeItem(at: old) }
    }
}
