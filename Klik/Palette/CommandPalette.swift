import AppKit
import SwiftUI

/// Something the palette can do without an item.
enum PaletteCommand: CaseIterable, Identifiable {
    case captureArea, captureWindow, captureFullScreen, captureScrolling, captureText, pickColor
    case newTask, newSnippet, clipboardList, klikPanel, clock, settings, unghostPins

    var id: Self { self }

    var title: String {
        switch self {
        case .captureArea: "Capture area"
        case .captureWindow: "Capture window"
        case .captureFullScreen: "Capture full screen"
        case .captureScrolling: "Scrolling capture"
        case .captureText: "Capture text (OCR)"
        case .pickColor: "Pick a color"
        case .newTask: "New task"
        case .newSnippet: "New snippet"
        case .clipboardList: "Clipboard list"
        case .klikPanel: "Klik panel"
        case .clock: "Clock and prayer times"
        case .settings: "Settings"
        case .unghostPins: "Unghost pinned screenshots"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: "viewfinder"
        case .captureWindow: "macwindow"
        case .captureFullScreen: "display"
        case .captureScrolling: "rectangle.expand.vertical"
        case .captureText: "text.viewfinder"
        case .pickColor: "eyedropper"
        case .newTask: "checklist"
        case .newSnippet: "text.badge.plus"
        case .clipboardList: "doc.on.clipboard"
        case .klikPanel: "cursorarrow.rays"
        case .clock: "clock"
        case .settings: "gearshape"
        case .unghostPins: "eye"
        }
    }

    /// Other words that should find it.
    var keywords: String {
        switch self {
        case .captureArea: "screenshot region selection"
        case .captureWindow: "screenshot app shadow"
        case .captureFullScreen: "screenshot display"
        case .captureScrolling: "screenshot long page"
        case .captureText: "ocr read copy text"
        case .pickColor: "eyedropper picker"
        case .newTask: "todo add"
        case .newSnippet: "text expander template"
        case .clipboardList: "history paste"
        case .klikPanel: "library history"
        case .clock: "time prayer"
        case .settings: "preferences shortcuts"
        case .unghostPins: "pin screenshot click-through see-through"
        }
    }

    /// A colour of its own, so the list scans by eye.
    var tint: Color {
        switch self {
        case .captureArea: .teal
        case .captureWindow: .cyan
        case .captureFullScreen: .blue
        case .captureScrolling: .indigo
        case .captureText: .green
        case .pickColor: .orange
        case .newTask: .mint
        case .newSnippet: .yellow
        case .clipboardList: .purple
        case .klikPanel: .cyan
        case .clock: .red
        case .settings: .gray
        case .unghostPins: .gray
        }
    }

    /// The shortcut that also does it, for the row's trailing hint.
    var hotkey: HotkeyID? {
        switch self {
        case .captureArea: .region
        case .captureWindow: .window
        case .captureFullScreen: .fullScreen
        case .captureScrolling: .scrolling
        case .captureText: .captureText
        case .pickColor: .pickColor
        case .newTask: .quickTask
        case .clipboardList: .clipboardPanel
        case .klikPanel: .showPanel
        default: nil
        }
    }
}

/// What the palette hands back to the app.
struct PaletteActions {
    var run: (PaletteCommand) -> Void
    /// Puts the item where the cursor was (or on the clipboard when it cannot be
    /// pasted); returns false when Accessibility access is missing.
    var paste: (IslandItem) -> Bool
    var copy: (IslandItem) -> Void
    /// The secondary verb (⌘O): edit a capture, open an asset, show a task…
    var open: (IslandItem) -> Void
    var pasteText: (String) -> Bool
    /// ⌘P on a capture: keep it floating on screen.
    var pin: (IslandItem) -> Void = { _ in }
    /// ⌘L on a capture: upload it and copy the link.
    var shareLink: (IslandItem) -> Void = { _ in }
}

/// One list over everything (⌥⇧Space): actions, quick answers, and every capture,
/// clipboard entry, asset, color, task and snippet. Type to filter, ↑↓ to choose,
/// ↩ to paste or run, ⌘↩ to copy, ⌘O to open, ⌘1–9 for the first nine, ⎋ to close.
struct CommandPaletteView: View {
    static let size = CGSize(width: 600, height: 500)

    let library: CaptureLibrary
    let clipboard: ClipboardHistory
    let assets: AssetStore
    let colors: ColorStore
    let tasks: TaskStore
    let snippets: SnippetStore
    let shortcuts: ShortcutController
    let actions: PaletteActions
    var close: () -> Void = {}
    var onNeedsAccessibility: () -> Void = {}

    @Environment(AppPreferences.self) private var preferences
    @State private var query = ""
    @State private var selected = 0
    @State private var done: String?
    @State private var recent: [IslandItem] = []
    @FocusState private var focused: Bool

    enum Row: Identifiable {
        case command(PaletteCommand)
        case answer(QuickAnswer)
        case item(IslandItem)

        var id: String {
            switch self {
            case .command(let command): "command.\(command)"
            case .answer(let answer): "answer.\(answer.id)"
            case .item(let item): "item.\(item.id)"
            }
        }
    }

    struct Section: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    private var sections: [Section] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty {
            return [
                Section(title: "Actions", rows: PaletteCommand.allCases.map(Row.command)),
                Section(title: "Recent", rows: recent.map(Row.item)),
            ].filter { !$0.rows.isEmpty }
        }
        let answers = QuickAnswers.answers(for: query).map(Row.answer)
        let commands = PaletteCommand.allCases.filter { command in
            terms.allSatisfy { "\(command.title) \(command.keywords)".localizedCaseInsensitiveContains($0) }
        }.map(Row.command)
        let items = Array(IslandSearch.hits(for: query, library: library, clipboard: clipboard, assets: assets,
                                            colors: colors, tasks: tasks, snippets: snippets)
            .filter { if case .answer = $0 { false } else { true } }.prefix(40)).map(Row.item)
        return [
            Section(title: "Answers", rows: answers),
            Section(title: "Actions", rows: commands),
            Section(title: "Results", rows: items),
        ].filter { !$0.rows.isEmpty }
    }

    var body: some View {
        let sections = sections
        let rows = sections.flatMap(\.rows)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: query.isEmpty ? "command" : "magnifyingglass").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(query.isEmpty ? .white.opacity(0.6) : Color.brand)
                    .contentTransition(.symbolEffect(.replace))
                TextField("Type a command, search, or calculate…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { perform(at: selected, in: rows) }
                    .onKeyPress(.downArrow) { move(1, in: rows) }
                    .onKeyPress(.upArrow) { move(-1, in: rows) }
                    .onChange(of: query) { _, _ in selected = 0 }
                    .accessibilityLabel("Command palette")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.white.opacity(0.08), in: Capsule(style: .continuous))

            if rows.isEmpty {
                Spacer()
                Text("Nothing for “\(query)”").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                            ForEach(Array(sections.enumerated()), id: \.element.id) { position, section in
                                if position > 0 {
                                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 8).padding(.top, 6)
                                }
                                HStack {
                                    Text(section.title.uppercased())
                                        .font(.system(size: 9.5, weight: .bold))
                                        .tracking(0.6)
                                    Spacer()
                                    if section.rows.count > 1 {
                                        Text("\(section.rows.count)").font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                    }
                                }
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                                ForEach(section.rows) { row in
                                    let index = rows.firstIndex { $0.id == row.id } ?? 0
                                    self.row(row, index: index, selected: index == selected)
                                        .id(row.id)
                                }
                            }
                        }
                    }
                    .onChange(of: selected) { _, index in
                        guard rows.indices.contains(index) else { return }
                        proxy.scrollTo(rows[index].id, anchor: nil)
                    }
                }
            }

            HStack(spacing: 10) {
                hint("↑↓", "choose")
                hint("↩", primaryVerb(rows))
                if let verbs = secondaryVerbs(rows) {
                    if let copy = verbs.copy { hint("⌘↩", copy) }
                    if let open = verbs.open { hint("⌘O", open) }
                }
                hint("⌘1–9", "pick")
                Spacer(minLength: 0)
                hint("⎋", "close")
            }
            .padding(.horizontal, 4)
            .animation(.easeOut(duration: 0.12), value: selected)
        }
        .padding(14)
        .background { keyboardShortcuts(rows) }
        .foregroundStyle(.white)
        .onAppear {
            recent = Array(IslandSearch.everything(library: library, clipboard: clipboard, assets: assets, colors: colors, snippets: snippets).prefix(8))
            DispatchQueue.main.async { focused = true }
        }
    }

    private func primaryVerb(_ rows: [Row]) -> String {
        guard rows.indices.contains(selected) else { return "run" }
        switch rows[selected] {
        case .command: return "run"
        case .answer: return clipboard.canPaste ? "paste" : "copy"
        case .item(let item):
            if case .task = item { return "open" }
            return clipboard.canPaste ? "paste" : "copy"
        }
    }

    /// What ⌘↩ and ⌘O do for the chosen row, or nil when they do nothing more than ↩.
    private func secondaryVerbs(_ rows: [Row]) -> (copy: String?, open: String?)? {
        guard rows.indices.contains(selected) else { return nil }
        switch rows[selected] {
        case .command: return nil
        case .answer: return (clipboard.canPaste ? "copy" : nil, nil)
        case .item(let item):
            let open: String? = switch item {
            case .capture: "edit · ⌘P pin · ⌘L link"
            case .asset: "open"
            case .snippet: "edit"
            case .task: nil
            case .clipboard, .color, .answer: nil
            }
            return (clipboard.canPaste ? "copy" : nil, open)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ row: Row, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            icon(for: row)
                .frame(width: 30, height: 24)
                .background(tileTint(for: row).opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: row)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if let subtitle = subtitle(for: row) {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if done == row.id {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
            } else if case .command(let command) = row, let hotkey = command.hotkey, let display = shortcuts.entries[hotkey]?.hotkey?.displayString {
                Text(display)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.75 : 0.35))
            } else if selected {
                Text(rowVerb(row))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.1), in: Capsule())
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            // A brand mark on the left edge, the way a focused row reads without a box.
            RoundedRectangle(cornerRadius: 1.5).fill(Color.brand).frame(width: 3, height: 18).opacity(selected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { perform(at: index, in: nil) }
        .onHover { if $0 { self.selected = index } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(for: row))
        .accessibilityValue(subtitle(for: row) ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }

    /// "↩ paste", said on the chosen row.
    private func rowVerb(_ row: Row) -> String {
        switch row {
        case .command: "↩ run"
        case .answer: clipboard.canPaste ? "↩ paste" : "↩ copy"
        case .item(let item):
            if case .task = item { "↩ open" } else { clipboard.canPaste ? "↩ paste" : "↩ copy" }
        }
    }

    private func tileTint(for row: Row) -> Color {
        switch row {
        case .command(let command): command.tint
        case .answer: Color.brand
        case .item(let item):
            switch item {
            case .capture: .teal
            case .clipboard: .purple
            case .asset: .orange
            case .color: .white
            case .task(let task): task.status.color
            case .snippet: .yellow
            case .answer: Color.brand
            }
        }
    }

    @ViewBuilder
    private func icon(for row: Row) -> some View {
        switch row {
        case .command(let command):
            Image(systemName: command.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(command.tint)
        case .answer(let answer):
            if let color = answer.color {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.swiftUIColor)
            } else {
                Image(systemName: answer.symbol).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            }
        case .item(let item):
            switch item {
            case .capture(let capture):
                if let image = library.thumbnail(for: capture) {
                    Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                } else { Image(systemName: "photo") }
            case .clipboard(let entry):
                if entry.kind == .color, let color = PickedColor(hex: entry.text) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.swiftUIColor)
                } else if entry.kind == .image, let image = clipboard.thumbnail(for: entry) {
                    Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                } else {
                    Image(systemName: Self.symbol(for: entry.kind)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            case .asset(let asset):
                if let image = assets.thumbnail(for: asset) {
                    Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                } else { Image(systemName: "doc").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)) }
            case .color(let entry):
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(entry.color.swiftUIColor)
            case .task(let task):
                Image(systemName: task.status.symbol).font(.system(size: 13)).foregroundStyle(task.status.color)
            case .snippet:
                Image(systemName: "text.badge.checkmark").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            case .answer(let answer):
                Image(systemName: answer.symbol).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func title(for row: Row) -> String {
        switch row {
        case .command(let command): command.title
        case .answer(let answer): answer.value
        case .item(let item):
            switch item {
            case .capture(let capture): capture.hasDefaultName ? "Screenshot" : capture.title
            case .clipboard(let entry): entry.name ?? entry.title
            case .asset(let asset): asset.fileName
            case .color(let entry): entry.name ?? preferences.colorFormat.string(for: entry.color)
            case .task(let task): task.title
            case .snippet(let snippet): snippet.keyword + (snippet.name.isEmpty ? "" : " · \(snippet.name)")
            case .answer(let answer): answer.value
            }
        }
    }

    private func subtitle(for row: Row) -> String? {
        switch row {
        case .command: return nil
        case .answer(let answer): return answer.label
        case .item(let item):
            let when = item.date.formatted(.relative(presentation: .named))
            switch item {
            case .capture(let capture): return "Capture · \(capture.dimensions) · \(when)"
            case .clipboard(let entry): return "\(entry.sourceName ?? entry.kind.rawValue.capitalized) · \(when)"
            case .asset: return "Asset · \(when)"
            case .color(let entry): return "Color · \(entry.name == nil ? "" : preferences.colorFormat.string(for: entry.color) + " · ")\(when)"
            case .task(let task): return "Task · \(task.status.title) · \(task.priority.title)"
            case .snippet(let snippet): return "Snippet · " + snippet.text.split(whereSeparator: \.isNewline).first.map(String.init).map { String($0.prefix(60)) }.orEmpty
            case .answer(let answer): return answer.label
            }
        }
    }

    private static func symbol(for kind: ClipboardItem.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "paintpalette"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }

    // MARK: - Keys

    private func keyboardShortcuts(_ rows: [Row]) -> some View {
        Group {
            Button("") { copy(at: selected, in: rows) }.keyboardShortcut(.return, modifiers: .command)
            Button("") { open(at: selected, in: rows) }.keyboardShortcut("o", modifiers: .command)
            Button("") { pin(at: selected, in: rows) }.keyboardShortcut("p", modifiers: .command)
            Button("") { share(at: selected, in: rows) }.keyboardShortcut("l", modifiers: .command)
            ForEach(0..<9, id: \.self) { index in
                Button("") { perform(at: index, in: rows) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(key)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func move(_ delta: Int, in rows: [Row]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        selected = min(max(selected + delta, 0), rows.count - 1)
        return .handled
    }

    // MARK: - Doing

    /// ↩ / click: run the action, paste the answer, paste (or open) the item.
    private func perform(at index: Int, in rows: [Row]?) {
        let rows = rows ?? sections.flatMap(\.rows)
        guard rows.indices.contains(index), done == nil else { return }
        switch rows[index] {
        case .command(let command):
            close()
            actions.run(command)
        case .answer(let answer):
            take(rows[index].id) { if !actions.pasteText(answer.value) { onNeedsAccessibility() } }
        case .item(let item):
            if case .task = item {
                close()
                actions.open(item)
            } else {
                take(rows[index].id) { if !actions.paste(item) { onNeedsAccessibility() } }
            }
        }
    }

    private func copy(at index: Int, in rows: [Row]) {
        guard rows.indices.contains(index), done == nil else { return }
        switch rows[index] {
        case .command: perform(at: index, in: rows)
        case .answer(let answer):
            take(rows[index].id) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(answer.value, forType: .string)
            }
        case .item(let item):
            take(rows[index].id) { actions.copy(item) }
        }
    }

    /// ⌘L: a capture uploaded, its link copied.
    private func share(at index: Int, in rows: [Row]) {
        guard rows.indices.contains(index), case .item(let item) = rows[index], case .capture = item else { return }
        close()
        actions.shareLink(item)
    }

    /// ⌘P: a capture as a floating window.
    private func pin(at index: Int, in rows: [Row]) {
        guard rows.indices.contains(index), case .item(let item) = rows[index], case .capture = item else { return }
        close()
        actions.pin(item)
    }

    private func open(at index: Int, in rows: [Row]) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .item(let item):
            close()
            actions.open(item)
        default:
            perform(at: index, in: rows)
        }
    }

    /// Ticks the row for a beat, closes, then does it (the paste needs the panel gone).
    private func take(_ id: String, then action: @escaping () -> Void) {
        done = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            close()
            action()
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
