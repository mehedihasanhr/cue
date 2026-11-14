import AppKit
import SwiftUI

/// The note being read, filling the right-hand side: a thin bar saying where it is
/// and when it changed, its title, and the note itself in the Markdown editor.
///
/// No property table. A note has no status, priority or project to show — it has
/// words — so the words get the room.
///
/// A note is one Markdown file whose name is its title, so the title field here is
/// the note's first line: renaming it rewrites that line, and the store renames the
/// file to match — which changes the note's id, so this tells the list.
struct NoteDetail: View {
    let store: NoteStore
    let buttons: WindowButtons
    let note: Note?
    @Environment(NoteDashboardModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            bar
            if let note {
                NoteEditor(store: store, note: note)
                    .id(note.id)
            } else {
                empty
            }
        }
    }

    /// The top bar: the window's buttons when the list is away, where the note sits,
    /// when it was written, and what can be done to it.
    private var bar: some View {
        HStack(spacing: 2) {
            if model.sidebarHidden {
                NoteWindowChrome(buttons: buttons)
                    .padding(.trailing, 4)
            }
            if let note {
                crumbs(for: note)
            }
            Spacer(minLength: 12)
            if let note {
                Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 13))
                    .foregroundStyle(NotionStyle.tertiary)
                    .padding(.trailing, 2)
                Menu {
                    NoteRowMenu(store: store, note: note)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(NotionStyle.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NoteDashboardView.topBarHeight)
    }

    /// Where the note sits, as its folders: clicking one unfolds it in the list.
    private func crumbs(for note: Note) -> some View {
        let parts = note.folder.isEmpty ? [] : note.folder.components(separatedBy: "/")
        return HStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Button {
                    model.reveal(parts[0...index].joined(separator: "/"))
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(part).font(.system(size: 13)).lineLimit(1)
                    }
                    .foregroundStyle(NotionStyle.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotionHoverStyle())
                Text("/").font(.system(size: 13)).foregroundStyle(NotionStyle.tertiary)
            }
            Text(note.name)
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(NotionStyle.tertiary)
            Text(store.notes.isEmpty ? "No notes yet" : "Pick a note")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(NotionStyle.secondary)
            Text(store.notes.isEmpty ? "⌘N starts one, ⇧⌘N makes a folder." : "Choose one on the left, or press ⌘N for a new one.")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One note, open: its title and its Markdown. Saved a moment after typing stops,
/// and on leaving.
private struct NoteEditor: View {
    let store: NoteStore
    let note: Note
    @Environment(NoteDashboardModel.self) private var model

    /// The whole note, as written.
    @State private var text = ""
    /// The text after the last load or save — what tells typing here from a change
    /// made elsewhere (the folder is watched, so a note edited in Obsidian lands here).
    @State private var savedText = ""
    /// Bumped to put the caret in the body's first line (↩ in the title).
    @State private var bodyFocusRequest = 0
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var titleFocused: Bool

    /// A line of text gets hard to follow much wider than this.
    private static let column: CGFloat = 720

    private var textToSave: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dirty: Bool { textToSave != savedText }

    /// The title field: the note's first line. Typing in it rewrites that line and
    /// leaves the rest of the note alone.
    private var titleBinding: Binding<String> {
        Binding(
            get: { TaskText.title(of: text) },
            set: { value in
                // A title is one line: a pasted line break goes.
                text = TaskText.replacingTitle(of: text, with: value.replacingOccurrences(of: "\n", with: " "))
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Untitled", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 32, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .focused($titleFocused)
                    .onSubmit { bodyFocusRequest += 1 }
                    .help("Rename the note. The title is its first line, and the file on disk is named after it.")
                    .padding(.top, 34)
                    .padding(.bottom, 16)

                BlockEditorView(markdown: $text, services: services, focusRequest: bodyFocusRequest)
                    .padding(.bottom, 60)
            }
            // Room in the margin for the blocks' handles.
            .padding(.leading, 54)
            .padding(.trailing, 32)
            .frame(maxWidth: Self.column, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .thinScrollers()
        .onAppear { load(note) }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: note) { _, note in
            // Changed elsewhere (the island, Obsidian, iCloud) with nothing typed
            // here: show it.
            if !dirty, note.text != savedText { load(note) }
        }
        .onDisappear(perform: save)
    }

    /// Where the note's images and files live, and how they open.
    private var services: BlockServices {
        BlockServices(imageURL: { store.url(for: $0) }, attachmentURL: { store.url(for: $0) },
                      saveImage: { store.saveImage($0) }, saveFile: { store.saveAttachment($0) },
                      openImage: { url in
                          NSApp.keyWindow?.makeFirstResponder(nil)
                          model.viewingImage = url
                      })
    }

    private func load(_ note: Note) {
        text = note.text
        savedText = note.text
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard dirty else { return }
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Saves the note if it changed — unless that would leave it with no title at
    /// all, which a file cannot have; that waits for one.
    private func save() {
        pendingSave?.cancel()
        guard dirty, let current = store.notes.first(where: { $0.id == note.id }) else { return }
        let text = textToSave
        guard !TaskText.title(of: text).isEmpty else { return }
        guard let saved = store.update(current, text: text) else { return }
        savedText = saved.text
        // Renaming the note renames its file, and the file's path is its id: the
        // list is holding the old one, so hand it the new one.
        if saved.id != note.id, model.openNoteID == note.id { model.openNoteID = saved.id }
    }
}
