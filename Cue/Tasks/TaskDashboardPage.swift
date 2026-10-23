import AppKit
import SwiftUI

/// The open task as a Notion page: a big title, its properties as rows, a rule, and
/// the whole description in the Markdown editor. The title follows the description's
/// first line until it is renamed here. In the side peek (with » to close and ⤢ to open
/// it as a full page) or as the page itself, centred at a readable width. Saved a
/// moment after typing stops, and on leaving.
struct TaskPageView: View {
    enum Style { case peek, page }

    let store: TaskStore
    let task: TaskItem
    let style: Style
    @Environment(TaskDashboardModel.self) private var model

    /// The title typed here; nil while it follows the description.
    @State private var customTitle: String?
    /// The whole description, as written.
    @State private var notes = ""
    /// The stored title and text after the last load or save — what tells typing
    /// here from a change made elsewhere.
    @State private var savedTitle: String?
    @State private var savedText = ""
    /// Bumped to put the caret in the description's first line (↩ in the title).
    @State private var notesFocusRequest = 0
    /// The block editor is built once the peek has slid in (a page shows it at once).
    @State private var showsEditor = false
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var titleFocused: Bool

    /// Notion's page column; wider, a line of text gets hard to follow.
    private static let pageColumn: CGFloat = 708

    /// The title as it would be saved: nil to follow the description.
    private var titleToSave: String? {
        customTitle.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : TaskText.customTitle($0, for: textToSave) }
    }
    /// The description as it would be saved: trailing space dropped, as the store does.
    private var textToSave: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dirty: Bool { titleToSave != savedTitle || textToSave != savedText }

    /// The title field: the title typed here, else the one the description gives —
    /// which changes as the description's first line does, until a title is typed.
    private var titleBinding: Binding<String> {
        Binding(
            get: { customTitle ?? TaskText.autoTitle(of: notes) },
            set: { value in
                // A title is one line: a pasted line break goes.
                let line = value.replacingOccurrences(of: "\n", with: " ")
                customTitle = line == TaskText.autoTitle(of: notes) ? nil : line
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
            load(task)
            if style == .page {
                showsEditor = true
            } else {
                // After the slide (0.18 s), so the motion is not held up by the build.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.12)) { showsEditor = true }
                }
            }
        }
        .onChange(of: customTitle) { _, _ in scheduleSave() }
        .onChange(of: notes) { _, _ in scheduleSave() }
        .onChange(of: task) { _, task in
            // Changed elsewhere (the island, a sync) with nothing typed here: show it.
            if !dirty, task.text != savedText || task.customTitle != savedTitle { load(task) }
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
                // ↩ in the title goes on to the description.
                .onSubmit(focusNotes)
                .onChange(of: titleFocused) { _, focused in
                    // Emptied and left: the title follows the description again.
                    if !focused, customTitle?.trimmingCharacters(in: .whitespaces).isEmpty == true { customTitle = nil }
                }
                .help("Rename the task. Left alone, the title follows the description's first line.")
                .padding(.top, style == .page ? 56 : 22)
                .padding(.bottom, 18)

            property("Status", symbol: "circle.dotted") {
                TagMenu(tag: .status(task.status), help: "Status") { TaskStatusItems(store: store, task: task) }
            }
            property("Priority", symbol: "flag") {
                TagMenu(tag: .priority(task.priority), help: "Priority") { TaskPriorityItems(store: store, task: task) }
            }
            property("Project", symbol: "folder") {
                TagMenu(tag: store.project(task.projectID).map { .project($0.name) }, help: "Project") { TaskProjectItems(store: store, task: task) }
            }
            property("Created", symbol: "clock") {
                Text(task.createdAt.formatted(date: .long, time: .shortened)).font(.system(size: 14))
            }
            property("Last edited", symbol: "clock.arrow.circlepath") {
                Text(dirty ? "Editing…" : task.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 14))
                    .foregroundStyle(dirty ? NotionStyle.tertiary : NotionStyle.text)
            }

            Hairline()
                .padding(.top, 12)
                .padding(.bottom, 10)

            if showsEditor {
                BlockEditorView(markdown: $notes, services: services, focusRequest: notesFocusRequest)
                    .transition(.opacity)
            } else {
                // Until the panel has finished sliding in: the description's first lines,
                // plain, so there is something there and nothing heavy is built mid-slide.
                Text(TaskText.oneLine(notes).prefix(400))
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
            NotionIconButton(symbol: "chevron.right.2", help: "Close (⎋)") { model.openTaskID = nil }
            NotionIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open as full page") { model.taskAsPage = true }
            Spacer(minLength: 8)
            Text("Edited \(task.updatedAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.tertiary)
                .padding(.trailing, 4)
            TaskMoreMenu(store: store, task: task)
        }
        .padding(.horizontal, 10)
        .frame(height: TaskDashboardView.topBarHeight)
    }

    private func focusNotes() {
        titleFocused = false
        // ↩ in the title before the editor is built: build it, then put the caret in.
        if showsEditor {
            notesFocusRequest += 1
        } else {
            showsEditor = true
            DispatchQueue.main.async { notesFocusRequest += 1 }
        }
    }

    /// Where the description's images and files live, and how they open.
    private var services: BlockServices {
        BlockServices(imageURL: { store.imageURL(for: $0) }, attachmentURL: { store.attachmentURL(for: $0) },
                      saveImage: { store.saveImage($0) }, saveFile: { store.saveAttachment($0) },
                      openImage: { url in
                          NSApp.keyWindow?.makeFirstResponder(nil)
                          model.viewingImage = url
                      })
    }

    private func load(_ task: TaskItem) {
        customTitle = task.customTitle
        notes = task.text
        savedTitle = task.customTitle
        savedText = task.text
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

    /// Saves the title and description if they changed — unless that would leave the
    /// task with no title at all (an emptied description and no title of its own),
    /// which waits for one or the other.
    private func save() {
        pendingSave?.cancel()
        guard dirty, let current = store.tasks.first(where: { $0.id == task.id }) else { return }
        let title = titleToSave, text = textToSave
        guard title != nil || !TaskText.title(of: text).isEmpty else { return }
        store.update(current, title: title, text: text)
        savedTitle = title
        savedText = text
    }
}
