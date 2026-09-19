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
        /// The clock opened in the compact island: time, dates, prayer times.
        case clock
        case expanded

        var geometryPhase: IslandGeometry.Phase {
            switch self {
            case .collapsed: .collapsed
            case .flash: .flash
            case .status(let status): status.clock == nil ? .flash : .prompt
            case .prompt(let prompt): prompt.isForm ? .form : .prompt
            case .taskDetail, .clock: .form
            case .expanded: .expanded
            }
        }

        var isFlash: Bool {
            switch self {
            case .flash, .status: true
            case .collapsed, .expanded, .prompt, .taskDetail, .clock: false
            }
        }

        /// The compact box is as wide as its row (a flash, a status, a confirmation);
        /// text fields and forms keep a fixed width.
        var fitsContent: Bool {
            switch self {
            case .flash, .status: true
            case .prompt(let prompt): prompt.isConfirm
            case .collapsed, .expanded, .taskDetail, .clock: false
            }
        }
    }

    var phase: Phase = .collapsed
    var geometry: IslandGeometry?
    /// The compact box's row width, reported by the row itself (see `fitsContent`).
    var contentWidth: CGFloat?
    /// The clock view's height and natural width, reported by the view, so its box
    /// fits it — nothing in it is ever cut short.
    var clockHeight: CGFloat?
    var clockWidth: CGFloat?
    /// The open panel's width: wide enough for its tab row, at least the fixed size.
    private(set) var panelWidth: CGFloat = IslandPanel.size.width
    /// The window must grow with the panel; set by the controller.
    var onPanelWidthChanged: () -> Void = {}

    func setPanelWidth(_ width: CGFloat) {
        let width = max(width, IslandPanel.size.width).rounded()
        guard width != panelWidth else { return }
        panelWidth = width
        onPanelWidthChanged()
    }

    /// The drawn shape in `phase`: the fixed rect, or the content-fitted one.
    func shapeRect(for phase: Phase) -> CGRect {
        guard let geometry else { return .zero }
        let width: CGFloat? = switch phase {
        case .expanded: panelWidth
        case .clock: clockWidth
        default: phase.fitsContent ? contentWidth : nil
        }
        let height: CGFloat? = phase == .clock ? clockHeight : nil
        return geometry.rect(for: phase.geometryPhase, contentWidth: width, contentHeight: height)
    }
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
    /// Opens the clock in the compact island (a click on a clock status or the
    /// prayer pill); set by the controller.
    var onShowClock: () -> Void = {}
    /// Leaves the clock; set by the controller.
    var onClockClosed: () -> Void = {}
    /// Settings › Time, from the clock; set by the controller.
    var onOpenTimeSettings: () -> Void = {}
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
    let snippets: SnippetStore
    let actions: HistoryActions
    @Environment(PrayerClock.self) private var clock: PrayerClock?

    /// Opening overshoots a touch; closing settles without a bounce. With Reduce
    /// Motion on, everything is a short ease instead.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var openAnimation: Animation { reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.82, blendDuration: 0) }
    static var closeAnimation: Animation { reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0) }
    static var contentAnimation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28) }

    /// Collapsed and settled: the shape is drawn clear so nothing shows beside the
    /// notch. Closing shrinks into the notch first (black all the way), then fades.
    @State private var faded = true

    var body: some View {
        let phase = model.phase
        if let geometry = model.geometry {
            let size = model.shapeRect(for: phase).size
            let collapsed = phase == .collapsed
            let flare: CGFloat = collapsed ? 6 : IslandGeometry.openFlare
            let shape = NotchShape(flare: flare, topRadius: 0, bottomRadius: geometry.radius(for: phase.geometryPhase))
            ZStack(alignment: .top) {
                // Invisible once collapsed (nothing peeks out beside the notch, nor sits
                // on a plain menu bar); the tap target stays.
                shape.fill(faded ? Color.clear : Color.black)
                content(for: phase, strip: geometry.stripHeight)
                    .compositingGroup()
                    .padding(.horizontal, flare) // the body; the flares lie outside it
            }
            .frame(width: size.width + flare * 2, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture {
                if collapsed {
                    model.onTap()
                } else if case .status(let status) = phase, status.clock != nil {
                    model.onShowClock()
                }
            }
            .animation(collapsed ? Self.closeAnimation : Self.openAnimation, value: phase)
            .animation(Self.openAnimation, value: model.contentWidth)
            .animation(Self.openAnimation, value: model.panelWidth)
            .animation(Self.openAnimation, value: model.clockHeight)
            .animation(Self.openAnimation, value: model.clockWidth)
            .task(id: phase) {
                guard collapsed else { faded = false; return } // black at once, then grows
                try? await Task.sleep(for: .milliseconds(460)) // the close animation
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { faded = true }
            }
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
                    .modifier(IdealWidth { model.contentWidth = $0 })
                    .frame(height: IslandGeometry.flashContentHeight)
            }
            .transition(Self.contentTransition)
        case .status(let status):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if let clock = status.clock {
                    ClockRow(status: clock)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.promptContentHeight)
                } else {
                    StatusRow(status: status)
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.flashContentHeight)
                }
            }
            .transition(Self.contentTransition)
        case .prompt(let prompt):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if case .snippet = prompt.kind {
                    SnippetFormRow(prompt: prompt, store: snippets, assets: assets) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else if case .fill(let snippet) = prompt.kind {
                    SnippetFillRow(snippet: snippet) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else if prompt.isForm {
                    TaskFormRow(prompt: prompt, store: tasks) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.formContentHeight)
                } else if prompt.isConfirm {
                    ConfirmRow(prompt: prompt, detail: prompt.detail(tasks)) { answer in model.onPromptFinished(prompt, answer) }
                        .modifier(IdealWidth { model.contentWidth = $0 })
                        .frame(height: IslandGeometry.promptContentHeight)
                } else {
                    PromptRow(prompt: prompt) { answer in model.onPromptFinished(prompt, answer) }
                        .frame(height: IslandGeometry.promptContentHeight)
                }
            }
            .transition(Self.contentTransition)
        case .clock:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                ClockDetail(clock: clock, openSettings: { model.onOpenTimeSettings() }, close: { model.onClockClosed() })
                    .modifier(IdealHeight { model.clockHeight = $0 })
                    .modifier(IdealWidth { model.clockWidth = $0 })
                    .frame(width: model.shapeRect(for: .clock).width, height: model.clockHeight ?? IslandGeometry.formContentHeight)
            }
            .transition(Self.contentTransition)
        case .taskDetail(let id):
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                if let task = tasks.tasks.first(where: { $0.id == id }) {
                    TaskDetailRow(task: task, store: tasks, edit: { model.onPrompt(IslandPrompt(kind: .task(project: task.projectID), editing: task)) },
                                  delete: { model.onPrompt(IslandPrompt(kind: .delete(.task(task)))) },
                                  close: { model.onTaskDetailClosed(task) })
                        .frame(height: IslandGeometry.formContentHeight)
                }
            }
            .transition(Self.contentTransition)
        case .expanded:
            VStack(spacing: 0) {
                Color.clear.frame(height: strip)
                IslandPanel(library: library, clipboard: clipboard, assets: assets, colors: colors, tasksStore: tasks, snippets: snippets, actions: actions, dropping: model.dropping,
                            width: model.panelWidth, onIdealWidth: { model.setPanelWidth($0) }, onPrompt: { model.onPrompt($0) }, onShowTask: { model.onShowTask($0) },
                            onShowClock: { model.onShowClock() })
                    .padding(.horizontal, IslandGeometry.panelHorizontalPadding)
                    .padding(.bottom, IslandGeometry.panelBottomPadding)
            }
            .transition(Self.contentTransition)
        }
    }

    private static var contentTransition: AnyTransition {
        reduceMotion ? .opacity.animation(contentAnimation) : .scale(scale: 0.8, anchor: .top).combined(with: .opacity).animation(contentAnimation)
    }
}

/// Reports a view's ideal width so the island can fit it. A hidden copy laid out at
/// its ideal size does the measuring; the visible view then gets the clamped width
/// and truncates what does not fit.
/// The vertical twin of `IdealWidth`: the height a view wants at its given width.
struct IdealHeight: ViewModifier {
    let report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background {
            content
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .disabled(true)
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
        }
    }
}

struct IdealWidth: ViewModifier {
    let report: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background {
            content
                .fixedSize()
                .hidden()
                .disabled(true) // its buttons must not answer clicks or shortcuts
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report($0) }
        }
    }
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
            Spacer(minLength: 12)
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
    /// How long the island holds it before closing again.
    var duration: Duration = .seconds(1.8)
    /// Drawn as the clock (large time, prayer bar) instead of the plain line.
    var clock: ClockStatus? = nil

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
            Spacer(minLength: 12)
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
        /// Confirm deleting a task or a project.
        case delete(TaskDeletion)
        /// A new snippet (from a template text or an asset), or an edit of one.
        case snippet(Snippet?, initialText: String, assetID: UUID?)
        /// Fill a snippet's blanks before it is pasted.
        case fill(Snippet)
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
        switch kind {
        case .task, .snippet, .fill: true
        default: false
        }
    }

    /// A yes/no box (Cancel / Delete) rather than a text field.
    var isConfirm: Bool {
        if case .delete = kind { return true }
        return false
    }

    /// What a confirmation is about: the task's title, or the project and what goes with it.
    func detail(_ store: TaskStore) -> String {
        switch kind {
        case .delete(.task(let task)): task.title
        case .delete(.project(let project)): store.deletionSummary(for: project)
        default: ""
        }
    }

    var title: String {
        switch kind {
        case .delete(.task): return "Delete this task?"
        case .delete(.project): return "Delete this project?"
        case .project(let parent):
            if parent == nil { return "New project" }
            return context.map { "New sub-project in \($0)" } ?? "New sub-project"
        case .task: return editing == nil ? "New task" : "Edit task"
        case .snippet(let snippet, _, let asset): return snippet == nil ? (asset == nil ? "New snippet" : "New snippet from this file") : "Edit snippet"
        case .fill(let snippet): return "Fill in \(snippet.title)"
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
        case .delete, .snippet, .fill: ""
        }
    }

    var symbol: String {
        switch kind {
        case .project: "folder.badge.plus"
        case .task: "checklist"
        case .rename: "pencil"
        case .delete: "trash"
        case .snippet, .fill: "text.badge.plus"
        }
    }
}

/// What a prompt hands back.
struct PromptAnswer {
    var title: String
    var notes = ""
    var projectID: UUID?
    var priority: TaskPriority = .medium
    /// A snippet's name.
    var name = ""
    /// A snippet's filled blanks.
    var values: [String: String] = [:]
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

/// The compact island's yes/no box: what is about to be deleted, Cancel and Delete.
/// ⎋ cancels, ↩ deletes; as wide as its content.
private struct ConfirmRow: View {
    let prompt: IslandPrompt
    let detail: String
    let finish: (PromptAnswer?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            PromptBadge(symbol: prompt.symbol, tint: .red)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            Button("Cancel") { finish(nil) }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.white.opacity(0.1), in: Capsule())
            Button("Delete") { finish(PromptAnswer(title: "")) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(.red.opacity(0.85), in: Capsule())
        }
        .padding(.horizontal, 16)
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
    @State private var priority: TaskPriority = .medium
    @State private var newProjectName: String?
    @State private var editor = MarkdownEditor.Handle()
    @FocusState private var focus: Field?
    /// Which completion for the title's last `#` / `!` token is highlighted.
    @State private var suggestionIndex = 0

    private enum Field { case title, notes }

    /// A completion offered under the title while a `#` or `!` token is being typed.
    private enum Suggestion: Hashable {
        case project(TaskProject)
        case newProject(String)
        case priority(TaskPriority)

        var title: String {
            switch self {
            case .project(let project): project.name
            case .newProject(let name): "New project “\(name)”"
            case .priority(let priority): priority.title
            }
        }

        var symbol: String {
            switch self {
            case .project: "folder"
            case .newProject: "folder.badge.plus"
            case .priority(let priority): priority.symbol
            }
        }

        /// What replaces the token when accepted.
        var token: String {
            switch self {
            case .project(let project): "#" + project.name.filter { !$0.isWhitespace }
            case .newProject(let name): "#" + name
            case .priority(let priority): "!" + priority.rawValue
            }
        }
    }

    /// The title's last word, if it is a `#` or `!` token still being typed.
    private var typingToken: String? {
        guard !title.hasSuffix(" "), let last = title.split(whereSeparator: \.isWhitespace).last else { return nil }
        let token = String(last)
        return token.hasPrefix("#") || token.hasPrefix("!") ? token : nil
    }

    private var suggestions: [Suggestion] {
        guard let token = typingToken else { return [] }
        let fragment = TaskTokens.compact(String(token.dropFirst()))
        if token.hasPrefix("#") {
            let matches = store.projects.filter { TaskTokens.compact($0.name).hasPrefix(fragment) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var result = matches.prefix(5).map(Suggestion.project)
            if !fragment.isEmpty, !matches.contains(where: { TaskTokens.compact($0.name) == fragment }) {
                result.append(.newProject(String(token.dropFirst())))
            }
            return result
        }
        return TaskPriority.allCases.filter { fragment.isEmpty || $0.rawValue.hasPrefix(fragment) }.map(Suggestion.priority)
    }

    /// Replaces the token being typed with the highlighted completion.
    @discardableResult
    private func acceptSuggestion() -> Bool {
        let suggestions = suggestions
        guard !suggestions.isEmpty, let token = typingToken else { return false }
        let chosen = suggestions[min(suggestionIndex, suggestions.count - 1)]
        title = String(title.dropLast(token.count)) + chosen.token + " "
        suggestionIndex = 0
        return true
    }

    private func moveSuggestion(_ delta: Int) -> KeyPress.Result {
        let count = suggestions.count
        guard count > 0 else { return .ignored }
        suggestionIndex = (suggestionIndex + delta + count) % count
        return .handled
    }

    /// `#project` / `!priority` in the title drive the pickers as they are typed.
    private func applyTokens() {
        let parsed = TaskTokens.parse(title)
        if let priority = parsed.priority { self.priority = priority }
        if let name = parsed.project, let project = store.projects.first(where: { TaskTokens.compact($0.name) == TaskTokens.compact(name) }) {
            projectID = project.id
        }
        if suggestionIndex >= suggestions.count { suggestionIndex = 0 }
    }

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
                TextField("Task title — #project !priority", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .focused($focus, equals: .title)
                    .onSubmit { if !acceptSuggestion() { focus = .notes } }
                    .onKeyPress(.tab) { acceptSuggestion() ? .handled : { focus = .notes; return .handled }() }
                    .onKeyPress(.downArrow) { moveSuggestion(1) }
                    .onKeyPress(.upArrow) { moveSuggestion(-1) }
                    .onChange(of: title) { _, _ in applyTokens() }
                    .padding(.horizontal, 8)
            }
            .overlay(alignment: .topLeading) {
                if !suggestions.isEmpty, focus == .title { suggestionRow.offset(y: 34) }
            }
            .zIndex(1)
            VStack(spacing: 0) {
                formatBar
                MarkdownEditor(text: $notes, handle: editor, insertImage: { data in store.saveImage(data) }, insertFile: { url in store.saveAttachment(url) },
                               onBacktab: { focus = .title })
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
                PriorityMenu(priority: priority) { priority = $0 }
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
        .background { priorityShortcuts }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(KeyWindowFocus())
        .onAppear {
            if let task = prompt.editing {
                title = task.title
                notes = task.notes
                projectID = task.projectID
                priority = task.priority
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

    /// Completions for the `#` / `!` token being typed: ↑↓ to choose, ⇥ or ↩ to take.
    private var suggestionRow: some View {
        let suggestions = suggestions
        return HStack(spacing: 4) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                let chosen = index == min(suggestionIndex, suggestions.count - 1)
                Button {
                    suggestionIndex = index
                    acceptSuggestion()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: suggestion.symbol).font(.system(size: 9, weight: .bold))
                        Text(suggestion.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(chosen ? .black : .primary.opacity(0.85))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(chosen ? Color.white : Color.primary.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            KeyCap("⇥").padding(.leading, 4)
        }
        .padding(6)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    /// ⌘1 – ⌘4 set the priority from anywhere in the form.
    private var priorityShortcuts: some View {
        ForEach(Array(TaskPriority.allCases.enumerated()), id: \.element) { index, value in
            Button("") { priority = value }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Bold, italic, heading, list, quote, image — applied to the selection or the line.
    private var formatBar: some View {
        HStack(spacing: 2) {
            formatButton("bold", help: "Bold", shortcut: KeyboardShortcut("b")) { editor.wrap("**", "**") }
            formatButton("italic", help: "Italic", shortcut: KeyboardShortcut("i")) { editor.wrap("*", "*") }
            formatButton("textformat.size", help: "Heading", shortcut: KeyboardShortcut("h", modifiers: [.command, .shift])) { editor.prefixLine("## ") }
            formatButton("list.bullet", help: "Bullet list", shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { editor.prefixLine("- ") }
            formatButton("list.number", help: "Numbered list", shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])) { editor.prefixLine("1. ") }
            formatButton("text.quote", help: "Quote", shortcut: KeyboardShortcut("q", modifiers: [.command, .shift])) { editor.prefixLine("> ") }
            formatButton("photo", help: "Insert image…", shortcut: KeyboardShortcut("i", modifiers: [.command, .shift])) { chooseImage() }
            Spacer(minLength: 0)
            Text("#project · !priority · ⌘1–4 priority · ⌘B ⌘I · ⇧⇥ back to title")
                .font(.system(size: 9.5))
                .foregroundStyle(.primary.opacity(0.4))
                .lineLimit(1)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func formatButton(_ symbol: String, help: String, shortcut: KeyboardShortcut, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .help("\(help) (\(shortcut.display))")
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
        let parsed = TaskTokens.parse(title)
        let cleaned = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var projectID = projectID
        if let name = parsed.project {
            // A `#` token names the project; one that matches nothing is created.
            if let project = store.projects.first(where: { TaskTokens.compact($0.name) == TaskTokens.compact(name) }) {
                projectID = project.id
            } else if let project = store.addProject(named: name) {
                projectID = project.id
            }
        }
        finish(PromptAnswer(title: cleaned, notes: notes, projectID: projectID, priority: parsed.priority ?? priority))
    }
}

extension KeyboardShortcut {
    /// "⌘⇧H", for help text.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key.character).uppercased()
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
    /// ⇧⇥ in the editor (moves focus back to the title).
    var onBacktab: () -> Void = {}

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
        textView.onBacktab = onBacktab
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
        var onBacktab: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func insertBacktab(_ sender: Any?) {
            onBacktab?()
        }

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
    let delete: () -> Void
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
                PriorityMenu(priority: task.priority) { store.setPriority($0, for: task) }
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
                Button("Delete…", action: delete)
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

/// The priority as a pill with a menu, the same shape as the status pill.
struct PriorityMenu: View {
    let priority: TaskPriority
    let pick: (TaskPriority) -> Void

    var body: some View {
        Menu {
            ForEach(TaskPriority.allCases, id: \.self) { value in
                Button { pick(value) } label: { Label(value.title, systemImage: value.symbol) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: priority.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(priority.color)
                Text(priority.title).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.primary.opacity(0.5))
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
        .help("Priority")
    }
}

// MARK: - Prompt pieces

struct PromptBadge: View {
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

struct PromptLabel: View {
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
struct PromptBox<Content: View>: View {
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
struct KeyWindowFocus: NSViewRepresentable {
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
