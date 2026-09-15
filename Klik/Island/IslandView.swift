import SwiftUI
import UniformTypeIdentifiers

/// What the island shows: nothing (a black shape hiding on the notch), the capture
/// that was just taken, or the captures strip.
@Observable
final class IslandModel {
    enum Phase: Equatable {
        case collapsed
        case flash(CaptureItem)
        /// A moment's confirmation on the closed island ("Copied", "Task saved").
        case status(IslandStatus)
        /// A compact box asking for one line of text (a new project's name).
        case prompt(IslandPrompt)
        /// A task opened in the compact island: title, status, description.
        case taskDetail(UUID)
        case expanded

        var geometryPhase: IslandGeometry.Phase {
            switch self {
            case .collapsed: .collapsed
            case .flash, .status: .flash
            case .prompt(let prompt): prompt.isForm ? .form : .prompt
            case .taskDetail: .form
            case .expanded: .expanded
            }
        }

        var isFlash: Bool {
            switch self {
            case .flash, .status: true
            case .collapsed, .expanded, .prompt, .taskDetail: false
            }
        }
    }

    var phase: Phase = .collapsed
    var geometry: IslandGeometry?
    /// A drag with files or an image is over the island.
    var dropping = false
    /// Asks the compact box for a line of text; called by the panel.
    var onPrompt: (IslandPrompt) -> Void = { _ in }
    /// The prompt's answer (nil: cancelled); set by the controller.
    var onPromptFinished: (IslandPrompt, PromptAnswer?) -> Void = { _, _ in }
    /// Opens a task in the compact island; called by the panel.
    var onShowTask: (TaskItem) -> Void = { _ in }
    /// Leaves the task detail (back to the open panel); set by the controller.
    var onTaskDetailClosed: (TaskItem?) -> Void = { _ in }
    /// A click on the closed shape opens it.
    var onTap: () -> Void = {}
}

/// The island silhouette: top corners flare outward into the bezel (a small flare
/// closed, a wide one open), bottom corners are rounded. All radii animate, so the
/// closed notch morphs into the open panel.
nonisolated struct NotchShape: Shape {
    /// Outward curve at the top corners (the notch meeting the bezel).
    var flare: CGFloat
    /// Inward rounding of the top corners (the open panel).
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(flare, AnimatablePair(topRadius, bottomRadius)) }
        set { flare = newValue.first; topRadius = newValue.second.first; bottomRadius = newValue.second.second }
    }

    /// `rect` includes the flares: the body spans `minX + flare … maxX - flare`, and
    /// the flares sweep from the body's top corners out to the rect's top corners.
    func path(in rect: CGRect) -> Path {
        let flare = min(self.flare, rect.width / 4)
        let body = rect.insetBy(dx: flare, dy: 0)
        let top = min(topRadius, body.width / 2, body.height / 2)
        let bottom = min(bottomRadius, body.width / 2, body.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if flare > 0 {
            path.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY + flare), control: CGPoint(x: body.minX, y: body.minY))
        } else {
            path.addLine(to: CGPoint(x: body.minX + top, y: body.minY))
            path.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY + top), control: CGPoint(x: body.minX, y: body.minY))
        }
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: body.minX + bottom, y: body.maxY), control: CGPoint(x: body.minX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - bottom), control: CGPoint(x: body.maxX, y: body.maxY))
        if flare > 0 {
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + flare))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: body.maxX, y: body.minY))
        } else {
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + top))
            path.addQuadCurve(to: CGPoint(x: body.maxX - top, y: body.minY), control: CGPoint(x: body.maxX, y: body.minY))
        }
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    let model: IslandModel
    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let tasks: TaskStore
    let actions: HistoryActions

    /// Opening overshoots a touch; closing settles without a bounce.
    static let openAnimation = Animation.spring(response: 0.36, dampingFraction: 0.82, blendDuration: 0)
    static let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    static let contentAnimation = Animation.smooth(duration: 0.28)

    var body: some View {
        let phase = model.phase
        if let geometry = model.geometry {
            let size = geometry.rect(for: phase.geometryPhase).size
            let collapsed = phase == .collapsed
            let flare: CGFloat = collapsed ? 6 : IslandGeometry.openFlare
            let shape = NotchShape(flare: flare, topRadius: 0, bottomRadius: geometry.radius(for: phase.geometryPhase))
            ZStack(alignment: .top) {
                shape.fill(.black)
                content(for: phase, strip: geometry.stripHeight)
                    .compositingGroup()
                    .padding(.horizontal, flare) // the body; the flares lie outside it
            }
            .frame(width: size.width + flare * 2, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { if collapsed { model.onTap() } }
            .animation(collapsed ? Self.closeAnimation : Self.openAnimation, value: phase)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private func content(for phase: IslandModel.Phase, strip: CGFloat) -> some View {
        switch phase {
        case .collapsed:
            EmptyView()
        case .flash(let item):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                FlashRow(item: item, library: library)
                    .frame(height: IslandGeometry.flashContentHeight)
            }
            .transition(Self.contentTransition)
        case .status(let status):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                StatusRow(status: status)
                    .frame(height: IslandGeometry.flashContentHeight)
            }
            .transition(Self.contentTransition)
        case .prompt(let prompt):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if prompt.isForm {
                    TaskFormRow(prompt: prompt, store: tasks) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else {
                    PromptRow(prompt: prompt) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.promptContentHeight)
                }
            }
            .transition(Self.contentTransition)
        case .taskDetail(let id):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if let task = tasks.tasks.first(where: { $0.id == id }) {
                    TaskDetailRow(task: task, store: tasks, edit: { model.onPrompt(IslandPrompt(kind: .task(project: task.projectID), editing: task)) },
                                  close: { model.onTaskDetailClosed(task) })
                        .frame(height: IslandGeometry.formContentHeight)
                }
            }
            .transition(Self.contentTransition)
        case .expanded:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                IslandPanel(library: library, clipboard: clipboard, assets: assets, colors: colors, tasksStore: tasks, actions: actions, dropping: model.dropping, onPrompt: { model.onPrompt($0) }, onShowTask: { model.onShowTask($0) })
                    .padding(.horizontal, IslandGeometry.panelHorizontalPadding)
                    .padding(.bottom, IslandGeometry.panelBottomPadding)
            }
            .transition(Self.contentTransition)
        }
    }

    private static let contentTransition: AnyTransition = .scale(scale: 0.8, anchor: .top)
        .combined(with: .opacity)
        .animation(contentAnimation)
}

/// "Just captured": the thumbnail and a copied confirmation.
private struct FlashRow: View {
    let item: CaptureItem
    let library: CaptureLibrary

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = library.thumbnail(for: item) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 48, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.15)))

            VStack(alignment: .leading, spacing: 1) {
                Text("Copied to clipboard")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(item.dimensions)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }
}

/// A moment's confirmation: "Copied", "Task saved", "Saved to Assets" — with what it
/// was about (a thumbnail, a swatch, a line of text) when there is one.
struct IslandStatus: Equatable, Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var image: NSImage? = nil
    var swatch: PickedColor? = nil

    /// Green for done, orange for "nothing to do", white otherwise.
    var tint: Color {
        if symbol.contains("checkmark") || symbol.contains("arrow.down.fill") { return .green }
        if symbol == "tray" || symbol.hasPrefix("exclamationmark") { return .orange }
        return .white
    }
}

/// The status as a row: its image or swatch, title, subtitle, and the symbol.
private struct StatusRow: View {
    let status: IslandStatus

    var body: some View {
        HStack(spacing: 10) {
            if let swatch = status.swatch {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(swatch.swiftUIColor)
                    .frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.2)))
            } else if let image = status.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 48, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.15)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let subtitle = status.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: status.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(status.tint)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }
}

/// Something the compact island asks for: one line (a project's name) or a small
/// form (a task).
struct IslandPrompt: Hashable {
    enum Kind: Hashable {
        case project(parent: UUID?)
        case task(project: UUID?)
        /// Rename a card (capture, asset, clipboard entry or color).
        case rename(IslandDetail)
    }

    let kind: Kind
    /// What is being created, for the label ("New sub-project in Work").
    var context: String? = nil
    /// An existing task to edit instead of creating one.
    var editing: TaskItem? = nil
    /// The current name, prefilled and selected, for renames.
    var initial = ""
    /// A thumbnail to show beside a rename.
    var image: NSImage? = nil
    /// A swatch to show beside a rename.
    var swatch: PickedColor? = nil
    let id = UUID()

    static func == (lhs: IslandPrompt, rhs: IslandPrompt) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isForm: Bool {
        if case .task = kind { return true }
        return false
    }

    var title: String {
        switch kind {
        case .project(let parent):
            if parent == nil { return "New project" }
            return context.map { "New sub-project in \($0)" } ?? "New sub-project"
        case .task: return editing == nil ? "New task" : "Edit task"
        case .rename(let detail):
            switch detail {
            case .capture: return "Rename capture"
            case .asset: return "Rename file"
            case .clipboard: return "Name this clipboard entry"
            case .color: return "Name this color"
            }
        }
    }

    var placeholder: String {
        switch kind {
        case .project: "Project name"
        case .task: "Task title"
        case .rename: "Name"
        }
    }

    var symbol: String {
        switch kind {
        case .project: "folder.badge.plus"
        case .task: "checklist"
        case .rename: "pencil"
        }
    }
}

/// What a prompt hands back.
struct PromptAnswer {
    var title: String
    var notes = ""
    var projectID: UUID?
}

/// The compact island's one-line form: an icon, what is being created, and the field.
private struct PromptRow: View {
    let prompt: IslandPrompt
    let finish: (PromptAnswer?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let image = prompt.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 44, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15)))
            } else if let swatch = prompt.swatch {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(swatch.swiftUIColor)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15)))
            } else {
                PromptBadge(symbol: prompt.symbol)
            }
            VStack(alignment: .leading, spacing: 4) {
                PromptLabel(prompt.title)
                PromptBox {
                    InlineTextField(placeholder: prompt.placeholder, initial: prompt.initial, font: .system(size: 13, weight: .medium), boxed: false, selectAll: true,
                                    commit: { finish(PromptAnswer(title: $0)) }, cancel: { finish(nil) })
                    KeyCap("↩")
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

/// The compact island's task form: title, a Markdown description with a formatting
/// bar (images can be pasted or dropped in), and the project — a dropdown that can
/// also create a new project on the spot.
struct TaskFormRow: View {
    let prompt: IslandPrompt
    let store: TaskStore
    let finish: (PromptAnswer?) -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var projectID: UUID?
    @State private var newProjectName: String?
    @State private var editor = MarkdownEditor.Handle()
    @FocusState private var focus: Field?

    private enum Field { case title, notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PromptBadge(symbol: prompt.symbol)
                PromptLabel(prompt.title)
                Spacer(minLength: 0)
                KeyCap("esc")
                Text("cancel").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
            }
            PromptBox {
                TextField("Task title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .notes }
                    .padding(.horizontal, 8)
            }
            VStack(spacing: 0) {
                formatBar
                MarkdownEditor(text: $notes, handle: editor, insertImage: { data in store.saveImage(data) }, insertFile: { url in store.saveAttachment(url) })
                    .focused($focus, equals: .notes)
            }
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.15)))
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                if newProjectName != nil {
                    PromptBox {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary.opacity(0.7)).padding(.leading, 8)
                        InlineTextField(placeholder: "New project name", font: .system(size: 12, weight: .medium), boxed: false) { name in
                            newProjectName = nil
                            if let project = store.addProject(named: name) { projectID = project.id }
                        } cancel: {
                            newProjectName = nil
                        }
                    }
                } else {
                    projectMenu
                }
                Spacer(minLength: 0)
                Button("Cancel") { finish(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.primary.opacity(0.1), in: Capsule())
                Button(action: create) {
                    HStack(spacing: 6) {
                        Text(prompt.editing == nil ? "Create" : "Save").font(.system(size: 12, weight: .semibold))
                        KeyCap("⌘↩")
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 14).padding(.trailing, 8)
                    .frame(height: 30)
                    .background(Color.brand, in: Capsule())
                    .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(KeyWindowFocus())
        .onAppear {
            if let task = prompt.editing {
                title = task.title
                notes = task.notes
                projectID = task.projectID
            } else if case .task(let project) = prompt.kind {
                projectID = project
            }
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                focus = .title
            }
        }
        .onExitCommand { finish(nil) }
    }

    /// Bold, italic, heading, list, quote, image — applied to the selection or the line.
    private var formatBar: some View {
        HStack(spacing: 2) {
            formatButton("bold", help: "Bold") { editor.wrap("**", "**") }
            formatButton("italic", help: "Italic") { editor.wrap("*", "*") }
            formatButton("textformat.size", help: "Heading") { editor.prefixLine("## ") }
            formatButton("list.bullet", help: "Bullet list") { editor.prefixLine("- ") }
            formatButton("list.number", help: "Numbered list") { editor.prefixLine("1. ") }
            formatButton("text.quote", help: "Quote") { editor.prefixLine("> ") }
            formatButton("photo", help: "Insert image…") { chooseImage() }
            Spacer(minLength: 0)
            Text("Markdown · paste or drop images and files")
                .font(.system(size: 9.5))
                .foregroundStyle(.primary.opacity(0.4))
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func formatButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let markdown = store.saveImage(data) else { return }
        editor.insert(markdown)
    }

    /// Every project by its path, "No project", and "New project…".
    private var projectMenu: some View {
        Menu {
            Button("No project") { projectID = nil }
            if !store.projects.isEmpty { Divider() }
            ForEach(store.projects.sorted { store.path(to: $0.id).map(\.name).joined(separator: "/") < store.path(to: $1.id).map(\.name).joined(separator: "/") }) { project in
                Button {
                    projectID = project.id
                } label: {
                    if project.id == projectID {
                        Label(store.path(to: project.id).map(\.name).joined(separator: " › "), systemImage: "checkmark")
                    } else {
                        Text(store.path(to: project.id).map(\.name).joined(separator: " › "))
                    }
                }
            }
            Divider()
            Button("New Project…") { newProjectName = "" }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                Text(store.project(projectID).map { store.path(to: $0.id).map(\.name).joined(separator: " › ") } ?? "No project")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func create() {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        finish(PromptAnswer(title: cleaned, notes: notes, projectID: projectID))
    }
}

/// A plain-text Markdown editor (an `NSTextView`) that takes pasted and dropped
/// images and files, saving them through `insertImage` / `insertFile` and inserting
/// the returned Markdown.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let handle: Handle
    let insertImage: (Data) -> String?
    let insertFile: (URL) -> String?

    /// Lets the toolbar reach the text view.
    final class Handle {
        weak var textView: EditorTextView?

        func wrap(_ prefix: String, _ suffix: String) { textView?.wrapSelection(prefix, suffix) }
        func prefixLine(_ prefix: String) { textView?.prefixCurrentLine(prefix) }
        func insert(_ string: String) { textView?.insertMarkdown(string) }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.insertImage = insertImage
        textView.insertFile = insertFile
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        handle.textView = textView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? EditorTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    final class EditorTextView: NSTextView {
        var insertImage: ((Data) -> String?)?
        var insertFile: ((URL) -> String?)?

        override var acceptsFirstResponder: Bool { true }

        // Pasting an image or files inserts them as Markdown; text pastes as plain text.
        override func paste(_ sender: Any?) {
            if takeContent(from: NSPasteboard.general) { return }
            pasteAsPlainText(sender)
        }

        // NSTextView has its own ideas about which drags it takes (and consults them
        // again in `draggingUpdated` / `prepareForDragOperation`), so every step is
        // overridden for files and images — the island's cards among them.
        private static func carriesContent(_ sender: any NSDraggingInfo) -> Bool {
            let types = sender.draggingPasteboard.types ?? []
            return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            Self.carriesContent(sender) ? .copy : super.draggingEntered(sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            Self.carriesContent(sender) ? .copy : super.draggingUpdated(sender)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            Self.carriesContent(sender) || super.prepareForDragOperation(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if Self.carriesContent(sender) {
                window?.makeFirstResponder(self)
                return takeContent(from: sender.draggingPasteboard)
            }
            return super.performDragOperation(sender)
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            if let sender, Self.carriesContent(sender) { return }
            super.concludeDragOperation(sender)
        }

        /// Files become images (when they are pictures) or attachments; raw image
        /// data becomes an image. Returns false when there is nothing of the kind.
        func takeContent(from pasteboard: NSPasteboard) -> Bool {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                var inserted = false
                for url in urls {
                    let isImage = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"].contains(url.pathExtension.lowercased())
                    let markdown = isImage ? (try? Data(contentsOf: url)).flatMap { insertImage?($0) } : insertFile?(url)
                    if let markdown {
                        insertMarkdown(markdown)
                        inserted = true
                    }
                }
                return inserted
            }
            guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let markdown = insertImage?(data) else { return false }
            insertMarkdown(markdown)
            return true
        }

        /// Inserts on its own line and tells the delegate.
        func insertMarkdown(_ markdown: String) {
            let range = selectedRange()
            let text = string as NSString
            let needsNewlineBefore = range.location > 0 && text.character(at: range.location - 1) != 10
            let snippet = (needsNewlineBefore ? "\n" : "") + markdown + "\n"
            insertText(snippet, replacementRange: range)
            didChangeText()
        }

        func wrapSelection(_ prefix: String, _ suffix: String) {
            let range = selectedRange()
            let selected = (string as NSString).substring(with: range)
            let replacement = prefix + (selected.isEmpty ? "text" : selected) + suffix
            insertText(replacement, replacementRange: range)
            if selected.isEmpty {
                setSelectedRange(NSRange(location: range.location + prefix.count, length: 4))
            }
            didChangeText()
        }

        func prefixCurrentLine(_ prefix: String) {
            let text = string as NSString
            let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
            insertText(prefix, replacementRange: NSRange(location: lineRange.location, length: 0))
            didChangeText()
        }
    }
}

/// A task in the compact island: title, project and status on top, the rendered
/// description below, Edit and Close.
private struct TaskDetailRow: View {
    let task: TaskItem
    let store: TaskStore
    let edit: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PromptBadge(symbol: task.status.symbol, tint: task.status == .pending ? Color.white.opacity(0.2) : task.status.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .semibold))
                        .strikethrough(task.status == .complete, color: .white.opacity(0.5))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let project = store.project(task.projectID) {
                            Label(store.path(to: project.id).map(\.name).joined(separator: " › "), systemImage: "folder")
                        }
                        Text("Added \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                statusMenu
            }
            ScrollView {
                if task.notes.isEmpty {
                    Text("No description — Edit to add one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownView(markdown: task.notes, imageURL: { store.imageURL(for: $0) }, attachmentURL: { store.attachmentURL(for: $0) })
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    KeyCap("esc")
                    Text("back").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: close) // the hint is a button too
                Spacer(minLength: 0)
                Button("Delete") { store.delete(task); close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.white.opacity(0.08), in: Capsule())
                Button(action: edit) {
                    Label("Edit", systemImage: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Color.brand, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .foregroundStyle(.primary)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button { store.setStatus(status, for: task) } label: { Label(status.title, systemImage: status.symbol) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: task.status.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(task.status.color)
                Text(task.status.title).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.primary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Prompt pieces

private struct PromptBadge: View {
    let symbol: String
    var tint: Color = .brand

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: Circle())
    }
}

private struct PromptLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.6))
            .lineLimit(1)
    }
}

/// A bordered field container.
private struct PromptBox<Content: View>: View {
    var height: CGFloat = 30
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.trailing, 6)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.15)))
    }
}

/// Makes the island the key window so the form's fields receive typing.
private struct KeyWindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {}

    final class KeyView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeKey() }
        }
    }
}
