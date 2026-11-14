import AppKit
import SwiftUI

/// The open note as a Notion page: a big title, its properties as rows, a rule, and
/// the whole note in the Markdown editor. In the side peek (with » to close and ⤢ to
/// open it as a full page) or as the page itself. Saved a moment after typing stops,
/// and on leaving.
///
/// A note is one Markdown file whose name is its title, so the title field here is
/// the note's first line: renaming it rewrites that line, and the store renames the
/// file to match — which changes the note's id, so the page tells the dashboard.
struct NotePageView: View {
    enum Style { case peek, page }

    let store: NoteStore
    let note: Note
    let style: Style
    @Environment(NoteDashboardModel.self) private var model

    /// The whole note, as written.
    @State private var text = ""
    /// The text after the last load or save — what tells typing here from a change
    /// made elsewhere (the folder is watched, so a note edited in Obsidian lands here).
    @State private var savedText = ""
    /// Bumped to put the caret in the body's first line (↩ in the title).
    @State private var bodyFocusRequest = 0
    /// The block editor is built once the peek has slid in (a page shows it at once).
    @State private var showsEditor = false
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var titleFocused: Bool

    /// Notion's page column; wider, a line of text gets hard to follow.
    private static let pageColumn: CGFloat = 708

    /// The note as it would be saved: trailing space dropped, as the store does.
    private var textToSave: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dirty: Bool { textToSave != savedText }

    /// The title field: the note's first line. Typing in it rewrites that line and
    /// leaves the rest of the note alone.
    private var titleBinding: Binding<String> {
        Binding(
            get: { TaskText.title(of: text) },
            set: { value in
                // A title is one line: a pasted line break goes.
                let line = value.replacingOccurrences(of: "\n", with: " ")
                text = TaskText.replacingTitle(of: text, with: line)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if style == .peek { peekBar }
            ScrollView {
                content
                    // Room in the margin for the blocks' handles.
                    .padding(.horizontal, style == .page ? 0 : 54)
                    .frame(maxWidth: style == .page ? Self.pageColumn : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, style == .page ? 64 : 0)
            }
            .thinScrollers()
        }
        .onAppear {
            load(note)
            if style == .page {
                showsEditor = true
            } else {
                // After the slide (0.18 s), so the motion is not held up by the build.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.12)) { showsEditor = true }
                }
            }
        }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: note) { _, note in
            // Changed elsewhere (the island, Obsidian, iCloud) with nothing typed
            // here: show it.
            if !dirty, note.text != savedText { load(note) }
        }
        .onDisappear(perform: save)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Untitled", text: titleBinding)
                .textFieldStyle(.plain)
                .font(.system(size: style == .page ? 38 : 28, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .focused($titleFocused)
                // ↩ in the title goes on to the note itself.
                .onSubmit(focusBody)
                .help("Rename the note. The title is its first line, and the file on disk is named after it.")
                .padding(.top, style == .page ? 56 : 22)
                .padding(.bottom, 18)

            property("Words", symbol: "number") {
                Text("\(NoteDashboardQuery.words(in: note))").font(.system(size: 14))
            }
            property("Created", symbol: "clock") {
                Text(note.createdAt.formatted(date: .long, time: .shortened)).font(.system(size: 14))
            }
            property("Last edited", symbol: "clock.arrow.circlepath") {
                Text(dirty ? "Editing…" : note.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 14))
                    .foregroundStyle(dirty ? NotionStyle.tertiary : NotionStyle.text)
            }
            property("File", symbol: "doc.text") {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: note)])
                } label: {
                    Text("\(note.id).md")
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .underline()
                        .foregroundStyle(NotionStyle.accent)
                }
                .buttonStyle(.plain)
                .help("Show in Finder — \(store.fileURL(for: note).path)")
            }

            Hairline()
                .padding(.top, 12)
                .padding(.bottom, 10)

            if showsEditor {
                BlockEditorView(markdown: $text, services: services, focusRequest: bodyFocusRequest)
                    .transition(.opacity)
            } else {
                // Until the panel has finished sliding in: the note's first lines,
                // plain, so there is something there and nothing heavy is built mid-slide.
                Text(TaskText.oneLine(text).prefix(400))
                    .font(.system(size: 16))
                    .foregroundStyle(NotionStyle.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    /// One of the page's properties: a grey label with its glyph, then the value.
    private func property(_ name: String, symbol: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                Text(name).font(.system(size: 14))
            }
            .foregroundStyle(NotionStyle.secondary)
            .frame(width: 150, alignment: .leading)
            value()
                .frame(maxWidth: 280, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    /// The peek's top row: close, open as a full page; when it was edited, and more.
    private var peekBar: some View {
        HStack(spacing: 2) {
            NotionIconButton(symbol: "chevron.right.2", help: "Close (⎋)") { model.openNoteID = nil }
            NotionIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open as full page") { model.noteAsPage = true }
            Spacer(minLength: 8)
            Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.tertiary)
                .padding(.trailing, 4)
            NoteMoreMenu(store: store, note: note)
        }
        .padding(.horizontal, 10)
        .frame(height: NoteDashboardView.topBarHeight)
    }

    private func focusBody() {
        titleFocused = false
        // ↩ in the title before the editor is built: build it, then put the caret in.
        if showsEditor {
            bodyFocusRequest += 1
        } else {
            showsEditor = true
            DispatchQueue.main.async { bodyFocusRequest += 1 }
        }
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
        // Renaming the note renames its file, and the file's name is its id: the
        // dashboard is holding the old one, so hand it the new one.
        if saved.id != note.id, model.openNoteID == note.id { model.openNoteID = saved.id }
    }
}
