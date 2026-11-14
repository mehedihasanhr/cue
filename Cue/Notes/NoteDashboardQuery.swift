import Foundation

/// What the notes window needs to know about a note, apart from any view so it can
/// be tested.
///
/// There is little of it, deliberately: notes are files in folders, and the window
/// shows them as such. The filtering, grouping and counting a database view would
/// need has no place here.
nonisolated enum NoteDashboardQuery {
    /// Whether a note matches what was typed in the search field: its title, its
    /// words, or the folder it sits in, ignoring case.
    static func matches(_ note: Note, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return note.title.localizedCaseInsensitiveContains(needle)
            || note.text.localizedCaseInsensitiveContains(needle)
            || note.folder.localizedCaseInsensitiveContains(needle)
    }

    /// Whether a note holds a picture or a file of its own, rather than only words.
    /// The list gives those a fuller glyph. `NoteStore.attachmentsFolder` spelled out
    /// here: this stays off the main actor, and the store's copy is on it.
    static func carriesFiles(_ note: Note) -> Bool {
        note.text.contains("cue://") || note.text.contains("cue-file://") || note.text.contains("attachments/")
    }
}
