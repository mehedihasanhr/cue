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
    /// The open panel's height: what its content needs, at most the fixed size.
    private(set) var panelHeight: CGFloat = IslandPanel.size.height
    /// The window must grow with the panel; set by the controller.
    var onPanelWidthChanged: () -> Void = {}

    func setPanelWidth(_ width: CGFloat) {
        let width = max(width, IslandPanel.size.width).rounded()
        guard width != panelWidth else { return }
        panelWidth = width
        onPanelWidthChanged()
    }

    func setPanelHeight(_ height: CGFloat) {
        let height = min(height, IslandPanel.size.height).rounded()
        guard height != panelHeight else { return }
        panelHeight = height
    }

    /// The drawn shape in `phase`: the fixed rect, or the content-fitted one.
    func shapeRect(for phase: Phase) -> CGRect {
        guard let geometry else { return .zero }
        let width: CGFloat? = switch phase {
        case .expanded: panelWidth
        case .clock: clockWidth
        default: phase.fitsContent ? contentWidth : nil
        }
        let height: CGFloat? = switch phase {
        case .clock: clockHeight
        case .expanded: panelHeight
        default: nil
        }
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
    @Environment(AppPreferences.self) private var preferences

    /// Opening overshoots a touch; closing settles without a bounce. With Reduce
    /// Motion on, everything is a short ease instead.
    /// Settings › Island › Animation; the view sets it from the preferences it reads.
    nonisolated(unsafe) static var animationStyle: AppPreferences.IslandAnimation = .lively
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || animationStyle != .lively }
    static var openAnimation: Animation { animationStyle == .none ? .linear(duration: 0) : reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.82, blendDuration: 0) }
    static var closeAnimation: Animation { animationStyle == .none ? .linear(duration: 0) : reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0) }
    static var contentAnimation: Animation { animationStyle == .none ? .linear(duration: 0) : reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28) }

    /// Collapsed and settled: the shape is drawn clear so nothing shows beside the
    /// notch. Closing shrinks into the notch first (black all the way), then fades.
    @State private var faded = true

    var body: some View {
        let phase = model.phase
        let _ = { Self.animationStyle = preferences.islandAnimation }()
        if let geometry = model.geometry {
            let size = model.shapeRect(for: phase).size
            let collapsed = phase == .collapsed
            let flare: CGFloat = collapsed ? 6 : IslandGeometry.openFlare
            let shape = NotchShape(flare: flare, topRadius: 0, bottomRadius: geometry.radius(for: phase.geometryPhase))
            ZStack(alignment: .top) {
                // Invisible once collapsed (nothing peeks out beside the notch, nor sits
                // on a plain menu bar); the tap target stays.
                shape.fill(faded && !preferences.islandNotchBackground ? Color.clear : Color.black)
                content(for: phase, strip: geometry.stripHeight)
                    .compositingGroup()
                    .padding(.horizontal, flare) // the body; the flares lie outside it
            }
            // Top-aligned: while the height animates the content may be taller than the
            // frame, and it must overflow downward (clipped), never slide up.
            .frame(width: size.width + flare * 2, height: size.height, alignment: .top)
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
            .animation(Self.openAnimation, value: model.panelHeight)
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
                            width: model.panelWidth, onIdealWidth: { model.setPanelWidth($0) }, onIdealHeight: { model.setPanelHeight($0) },
                            onPrompt: { model.onPrompt($0) }, onShowTask: { model.onShowTask($0) },
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
            Icon("checkmark.circle.fill", size: 21, weight: .semibold)
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
            Icon(status.symbol, size: 21, weight: .semibold)
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
        /// A new group for captures, clipboard entries or colors (with an item to
        /// put in it), or a rename of one.
        case group(GroupKind, assign: GroupAssignment?, editing: ItemGroup?)
    }

    let kind: Kind
    /// What is being created, for the label ("New sub-project in Work").
    var context: String? = nil
    /// An existing task to edit instead of creating one.
    var editing: TaskItem? = nil
    /// The current name, prefilled and selected, for renames.
    var initial = ""
    /// A new task's description to start from (a capture, say).
    var initialNotes = ""
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
        case .group(_, _, let editing): return editing == nil ? "New group" : "Rename group"
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
        case .group: "Group name"
        case .task: "Task title"
        case .rename: "Name"
        case .delete, .snippet, .fill: ""
        }
    }

    var symbol: String {
        switch kind {
        case .project, .group: "folder.badge.plus"
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
    /// A task's whole text (its title is the first line of it).
    var text = ""
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
    /// In the island: a header, a framed editor with its formatting bar, pill
    /// buttons. Floating: one pane — the text alone on the glass, and a bar of
    /// glass buttons under it with a round Create.
    enum Style { case island, floating }

    let prompt: IslandPrompt
    let store: TaskStore
    var style: Style = .island
    let finish: (PromptAnswer?) -> Void

    /// The whole task as one text: the first line is the title (with `#project` and
    /// `!priority` tokens in it, if any), the rest the description.
    @State private var text = ""
    @State private var projectID: UUID?
    @State private var priority: TaskPriority = .medium
    @State private var newProjectName: String?
    @State private var editor = MarkdownEditor.Handle()
    @FocusState private var focus: Field?
    /// The token at the caret (`/`, `#` or `!` and what follows), and the row
    /// highlighted in the list it brings up.
    @State private var token: String?
    @State private var highlighted = 0

    private enum Field { case notes }

    /// One row of a suggestion list: what it shows and what picking it does.
    private struct Suggestion: Identifiable {
        let id: String
        let symbol: String
        let title: String
        var detail: String?
        var tint: Color = .primary
        let pick: () -> Void
    }

    /// `/` lists the formatting commands, `#` the projects, `!` the priorities —
    /// narrowed by what is typed after the mark.
    private var suggestions: [Suggestion] {
        guard let token, let mark = token.first else { return [] }
        let query = token.dropFirst().lowercased()
        func matches(_ text: String) -> Bool { query.isEmpty || TaskTokens.compact(text).contains(query) }
        switch mark {
        case "/":
            let commands: [(String, String, String?, () -> Void)] = [
                ("bold", "Bold", "⌘B", { editor.removeToken(); editor.bold() }),
                ("italic", "Italic", "⌘I", { editor.removeToken(); editor.italic() }),
                ("strikethrough", "Strikethrough", "⌘⇧X", { editor.removeToken(); editor.strikethrough() }),
                ("chevron.left.forwardslash.chevron.right", "Code", "⌘E", { editor.removeToken(); editor.code() }),
                ("textformat.size.larger", "Heading 1", nil, { editor.removeToken(); editor.block(.heading1) }),
                ("textformat.size", "Heading 2", "⌘⇧H", { editor.removeToken(); editor.block(.heading2) }),
                ("textformat.size.smaller", "Heading 3", nil, { editor.removeToken(); editor.block(.heading3) }),
                ("list.bullet", "Bullet list", "⌘⇧L", { editor.removeToken(); editor.block(.bullet) }),
                ("list.number", "Numbered list", "⌘⇧N", { editor.removeToken(); editor.block(.numbered) }),
                ("checklist", "Checklist", "⌘⇧T", { editor.removeToken(); editor.block(.todo) }),
                ("text.quote", "Quote", "⌘⇧Q", { editor.removeToken(); editor.block(.quote) }),
                ("curlybraces", "Code block", nil, { editor.removeToken(); editor.block(.code) }),
                ("photo", "Image…", "⌘⇧I", { editor.removeToken(); chooseImage() }),
                ("folder", "Project…", "#", { editor.replaceToken(with: "#") }),
                ("flag", "Priority…", "!", { editor.replaceToken(with: "!") }),
            ]
            return commands.filter { matches($0.1) }.map { Suggestion(id: $0.1, symbol: $0.0, title: $0.1, detail: $0.2, pick: $0.3) }
        case "#":
            let projects = store.projects.sorted { store.path(to: $0.id).map(\.name).joined(separator: "/") < store.path(to: $1.id).map(\.name).joined(separator: "/") }
            var rows = projects.filter { matches($0.name) }.map { project in
                Suggestion(id: project.id.uuidString, symbol: "folder", title: store.path(to: project.id).map(\.name).joined(separator: " › "), pick: {
                    projectID = project.id
                    editor.replaceToken(with: "#" + TaskTokens.compact(project.name) + " ")
                })
            }
            if !query.isEmpty, !projects.contains(where: { TaskTokens.compact($0.name) == query }) {
                rows.append(Suggestion(id: "new", symbol: "folder.badge.plus", title: "New project “\(token.dropFirst())”", detail: "created when the task is", pick: {
                    editor.replaceToken(with: token + " ")
                }))
            }
            return rows
        case "!":
            return TaskPriority.allCases.filter { matches($0.title) }.map { value in
                Suggestion(id: value.rawValue, symbol: value.symbol, title: value.title, detail: "⌘\((TaskPriority.allCases.firstIndex(of: value) ?? 0) + 1)", tint: value.color, pick: {
                    priority = value
                    editor.replaceToken(with: "!" + value.rawValue + " ")
                })
            }
        default:
            return []
        }
    }

    /// ↑ ↓ move, ↩ ⇥ pick, ⎋ dismisses — while a list is up; otherwise the editor
    /// keeps its keys.
    private func intercept(_ selector: Selector) -> Bool {
        let rows = suggestions
        guard token != nil, !rows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            highlighted = (highlighted - 1 + rows.count) % rows.count
        case #selector(NSResponder.moveDown(_:)):
            highlighted = (highlighted + 1) % rows.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            rows[min(highlighted, rows.count - 1)].pick()
            token = nil
        case #selector(NSResponder.cancelOperation(_:)):
            token = nil
        default:
            return false
        }
        return true
    }

    /// The list, above the caret's line: drawn at the bottom of the editor.
    @ViewBuilder
    private var suggestionList: some View {
        let rows = suggestions
        if token != nil, !rows.isEmpty {
            // Seven rows at a time, the window sliding with the highlight.
            let visible = 7
            let first = max(0, min(highlighted - visible + 1, rows.count - visible))
            let shown = Array(rows.enumerated()).filter { $0.offset >= first && $0.offset < first + visible }
            VStack(spacing: 1) {
                ForEach(shown, id: \.element.id) { index, row in
                    HStack(spacing: 9) {
                        Icon(row.symbol, size: 14, weight: .semibold)
                            .foregroundStyle(row.tint == .primary ? Color.primary.opacity(0.8) : row.tint)
                            .frame(width: 16)
                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let detail = row.detail {
                            Text(detail).font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(index == highlighted ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { row.pick(); token = nil }
                    .onHover { if $0 { highlighted = index } }
                }
            }
            .padding(4)
            .frame(width: 260)
            .liquidGlass(cornerRadius: 10)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            .accessibilityLabel("Suggestions")
        }
    }

    /// The first line that says anything, without its block mark — where the
    /// `#project` and `!priority` tokens live.
    private var firstLine: String { TaskText.splitMark(TaskText.titleLine(of: text)).body }

    private var valid: Bool { !TaskText.plain(TaskTokens.parse(firstLine).title).isEmpty }

    /// `#project` / `!priority` on the first line drive the pickers as they are typed.
    private func applyTokens() {
        let parsed = TaskTokens.parse(firstLine)
        if let priority = parsed.priority { self.priority = priority }
        if let name = parsed.project, let project = store.projects.first(where: { TaskTokens.compact($0.name) == TaskTokens.compact(name) }) {
            projectID = project.id
        }
    }

    var body: some View {
        Group {
            switch style {
            case .island: islandBody
            case .floating: floatingBody
            }
        }
        .background { priorityShortcuts }
        .background(KeyWindowFocus())
        .onAppear {
            if let task = prompt.editing {
                text = task.text
                projectID = task.projectID
                priority = task.priority
            } else if case .task(let project) = prompt.kind {
                projectID = project
                text = prompt.initialNotes.isEmpty ? "" : "\n" + prompt.initialNotes
            }
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                focus = .notes
                if text.hasPrefix("\n") { editor.moveToStart() }
            }
        }
        .onExitCommand { finish(nil) }
    }

    private var markdownEditor: some View {
        MarkdownEditor(text: $text, handle: editor, insertImage: { data in store.saveImage(data) }, insertFile: { url in store.saveAttachment(url) },
                       imageURL: { store.imageURL(for: $0) }, attachmentURL: { store.attachmentURL(for: $0) }, fontSize: style == .floating ? 13 : 12)
            .focused($focus, equals: .notes)
            .overlay(alignment: .bottomLeading) {
                suggestionList
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
                    .animation(.easeOut(duration: 0.12), value: token)
            }
            .onAppear {
                editor.onToken = { new in
                    if new != token { highlighted = 0 }
                    token = new
                }
                editor.interceptCommand = { intercept($0) }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("What needs doing? #project · !priority · / for formatting")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.3))
                        .padding(.horizontal, 12).padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: text) { _, _ in applyTokens() }
    }

    // MARK: Floating

    /// One pane: the text sits straight on the glass, no frame around it; under
    /// it, plain glyphs on the left (attach, format) and on the right the project,
    /// the priority as a pill, and a round Create — all glass buttons.
    private var floatingBody: some View {
        VStack(spacing: 0) {
            markdownEditor
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                floatingGlyph("plus", help: "Attach an image… (⌘⇧I)") { chooseImage() }
                Menu {
                    Button("Bold", action: { editor.bold() }).keyboardShortcut("b")
                    Button("Italic", action: { editor.italic() }).keyboardShortcut("i")
                    Button("Strikethrough", action: { editor.strikethrough() }).keyboardShortcut("x", modifiers: [.command, .shift])
                    Button("Code", action: { editor.code() }).keyboardShortcut("e")
                    Divider()
                    Button("Heading", action: { editor.block(.heading2) }).keyboardShortcut("h", modifiers: [.command, .shift])
                    Button("Bullet list", action: { editor.block(.bullet) }).keyboardShortcut("l", modifiers: [.command, .shift])
                    Button("Numbered list", action: { editor.block(.numbered) }).keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("Checklist", action: { editor.block(.todo) }).keyboardShortcut("t", modifiers: [.command, .shift])
                    Button("Quote", action: { editor.block(.quote) }).keyboardShortcut("q", modifiers: [.command, .shift])
                    Button("Code block", action: { editor.block(.code) })
                } label: {
                    Text("/")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Formatting — type / in the text · #project · !priority")
                Spacer(minLength: 0)
                if newProjectName != nil {
                    PromptBox {
                        Icon("folder.badge.plus", size: 14, weight: .semibold).foregroundStyle(.primary.opacity(0.7)).padding(.leading, 8)
                        InlineTextField(placeholder: "New project name", font: .system(size: 12, weight: .medium), boxed: false) { name in
                            newProjectName = nil
                            if let project = store.addProject(named: name) { projectID = project.id }
                        } cancel: {
                            newProjectName = nil
                        }
                    }
                    .frame(width: 180)
                } else {
                    Menu {
                        projectMenuItems
                    } label: {
                        HStack(spacing: 6) {
                            Icon(projectID == nil ? "folder" : "folder.fill", size: 15, weight: .semibold)
                            if let project = store.project(projectID) {
                                Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, projectID == nil ? 0 : 12)
                        .frame(minWidth: 32, maxWidth: 160)
                        .frame(height: 32)
                        .contentShape(Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Project")
                }
                Menu {
                    ForEach(TaskPriority.allCases, id: \.self) { value in
                        Button { priority = value } label: { Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Icon(priority.symbol, size: 14, weight: .semibold).foregroundStyle(priority.color)
                        Text(priority.title).font(.system(size: 13, weight: .medium))
                        Icon("chevron.down", size: 11, weight: .bold).foregroundStyle(.primary.opacity(0.5))
                    }
                    .foregroundStyle(.primary.opacity(0.9))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .glassPill()
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Priority (⌘1–4)")
                Button(action: create) {
                    Icon("arrow.up", size: 18, weight: .bold)
                        .foregroundStyle(valid ? Color.white : Color.primary.opacity(0.5))
                        .frame(width: 34, height: 34)
                        .background(valid ? Color.brand : Color.primary.opacity(0.12), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(valid ? 0.25 : 0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!valid)
                .help(prompt.editing == nil ? "Create (⌘↩)" : "Save (⌘↩)")
                .animation(.easeOut(duration: 0.15), value: valid)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .padding(.top, 4)
    }

    private func floatingGlyph(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: 19, weight: .medium)
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Island

    private var islandBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PromptBadge(symbol: prompt.symbol)
                PromptLabel(prompt.title)
                Spacer(minLength: 0)
                KeyCap("esc")
                Text("cancel").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
            }
            VStack(spacing: 0) {
                formatBar
                markdownEditor
            }
            .fieldChrome(focused: focus == .notes)
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                if newProjectName != nil {
                    PromptBox {
                        Icon("folder.badge.plus", size: 14, weight: .semibold).foregroundStyle(.primary.opacity(0.7)).padding(.leading, 8)
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
                    .opacity(valid ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!valid)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// ⌘1–⌘4 set the priority (urgent → low).
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
            formatButton("bold", help: "Bold", shortcut: KeyboardShortcut("b")) { editor.bold() }
            formatButton("italic", help: "Italic", shortcut: KeyboardShortcut("i")) { editor.italic() }
            formatButton("strikethrough", help: "Strikethrough", shortcut: KeyboardShortcut("x", modifiers: [.command, .shift])) { editor.strikethrough() }
            formatButton("textformat.size", help: "Heading", shortcut: KeyboardShortcut("h", modifiers: [.command, .shift])) { editor.block(.heading2) }
            formatButton("list.bullet", help: "Bullet list", shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { editor.block(.bullet) }
            formatButton("list.number", help: "Numbered list", shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])) { editor.block(.numbered) }
            formatButton("checklist", help: "Checklist", shortcut: KeyboardShortcut("t", modifiers: [.command, .shift])) { editor.block(.todo) }
            formatButton("text.quote", help: "Quote", shortcut: KeyboardShortcut("q", modifiers: [.command, .shift])) { editor.block(.quote) }
            formatButton("photo", help: "Insert image…", shortcut: KeyboardShortcut("i", modifiers: [.command, .shift])) { chooseImage() }
            Spacer(minLength: 0)
            Text("/ formats · #project · !priority · ⌘1–4 priority · ⌘B ⌘I")
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
            Icon(symbol, size: 13, weight: .semibold)
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
        editor.insertBlock(markdown)
    }

    /// Every project by its path, "No project", and "New project…".
    @ViewBuilder
    private var projectMenuItems: some View {
        Button("No project") { projectID = nil }
        if !store.projects.isEmpty { Divider() }
        ForEach(store.projects.sorted { store.path(to: $0.id).map(\.name).joined(separator: "/") < store.path(to: $1.id).map(\.name).joined(separator: "/") }) { project in
            Button {
                projectID = project.id
            } label: {
                if project.id == projectID {
                    Label { Text(store.path(to: project.id).map(\.name).joined(separator: " › ")) } icon: { Icon("checkmark", weight: .medium) }
                } else {
                    Text(store.path(to: project.id).map(\.name).joined(separator: " › "))
                }
            }
        }
        Divider()
        Button("New Project…") { newProjectName = "" }
    }

    private var projectMenu: some View {
        Menu {
            projectMenuItems
        } label: {
            HStack(spacing: 6) {
                Icon("folder", size: 14, weight: .semibold)
                Text(store.project(projectID).map { store.path(to: $0.id).map(\.name).joined(separator: " › ") } ?? "No project")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Icon("chevron.down", size: 11, weight: .bold)
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

    /// The whole text is the task; the tokens on its first line pick the project
    /// and priority and are taken out of it.
    private func create() {
        let parsed = TaskTokens.parse(firstLine)
        let cleaned = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TaskText.plain(cleaned).isEmpty else { return }
        var projectID = projectID
        if let name = parsed.project {
            // A `#` token names the project; one that matches nothing is created.
            if let project = store.projects.first(where: { TaskTokens.compact($0.name) == TaskTokens.compact(name) }) {
                projectID = project.id
            } else if let project = store.addProject(named: name) {
                projectID = project.id
            }
        }
        let saved = TaskText.replacingTitle(of: text, with: cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        finish(PromptAnswer(title: TaskText.plain(cleaned), text: saved, projectID: projectID, priority: parsed.priority ?? priority))
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
                HStack(spacing: 6) {
                    if let project = store.project(task.projectID) {
                        Label { Text(store.path(to: project.id).map(\.name).joined(separator: " › ")) } icon: { Icon("folder", weight: .medium) }
                    }
                    Text("Added \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                Spacer(minLength: 0)
                PriorityMenu(priority: task.priority) { store.setPriority($0, for: task) }
                statusMenu
            }
            ScrollView {
                MarkdownView(markdown: task.text, imageURL: { store.imageURL(for: $0) }, attachmentURL: { store.attachmentURL(for: $0) })
                    .opacity(task.status == .complete ? 0.6 : 1)
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
                    Label { Text("Edit") } icon: { Icon("pencil", weight: .medium) }
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
                Button { store.setStatus(status, for: task) } label: { Label { Text(status.title) } icon: { Icon(status.symbol, weight: .medium) } }
            }
        } label: {
            HStack(spacing: 5) {
                Icon(task.status.symbol, size: 14, weight: .semibold).foregroundStyle(task.status.color)
                Text(task.status.title).font(.system(size: 12, weight: .semibold))
                Icon("chevron.down", size: 10, weight: .bold).foregroundStyle(.white.opacity(0.5))
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
                Button { pick(value) } label: { Label { Text(value.title) } icon: { Icon(value.symbol, weight: .medium) } }
            }
        } label: {
            HStack(spacing: 5) {
                Icon(priority.symbol, size: 14, weight: .semibold).foregroundStyle(priority.color)
                Text(priority.title).font(.system(size: 12, weight: .semibold))
                Icon("chevron.down", size: 10, weight: .bold).foregroundStyle(.primary.opacity(0.5))
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
        Icon(symbol, size: 18, weight: .semibold)
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
/// A field's box, in the forms' shared chrome.
struct PromptBox<Content: View>: View {
    var height: CGFloat = 32
    var focused = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.trailing, 6)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .fieldChrome(focused: focused)
    }
}

/// The one look every field and card in the forms shares: a faint fill, a hairline
/// edge a little brighter than it, and — with the focus — a brand edge with a soft
/// glow. Radius 10 everywhere.
struct FieldChrome: ViewModifier {
    var focused = false
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(.primary.opacity(focused ? 0.07 : 0.05), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? Color.brand.opacity(0.85) : .primary.opacity(0.12), lineWidth: focused ? 1.5 : 1)
            )
            .shadow(color: Color.brand.opacity(focused ? 0.25 : 0), radius: 6)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension View {
    func fieldChrome(focused: Bool = false, radius: CGFloat = 10) -> some View {
        modifier(FieldChrome(focused: focused, radius: radius))
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
