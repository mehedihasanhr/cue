import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// The note form: one Markdown text whose first line is the title, with the
/// formatting bar (images can be pasted or dropped in). Saving also sends a new
/// note wherever Settings › Notes says. In the island it has a header and pill
/// buttons; floating (the quick note, ⌥⇧M) it is one pane of glass with round
/// buttons under the text.
struct NoteFormRow: View {
    enum Style { case island, floating }

    let prompt: IslandPrompt
    let store: NoteStore
    var style: Style = .island
    let finish: (PromptAnswer?) -> Void

    @Environment(AppPreferences.self) private var preferences
    /// The floating window's size, pin and glass — nil in the island.
    @Environment(QuickTaskPanel.Chrome.self) private var chrome: QuickTaskPanel.Chrome?
    @State private var text = ""
    @State private var editor = MarkdownEditor.Handle()
    @FocusState private var focused: Bool
    /// The `/` token at the caret and the row highlighted in the list it brings up.
    @State private var token: String?
    @State private var highlighted = 0
    /// Where this note goes besides its folder — Settings' defaults, changed with
    /// "Save as" for this note only.
    @State private var sendTo: Set<NoteDestination> = []

    private var editing: Note? {
        if case .note(let note) = prompt.kind { return note }
        return nil
    }

    private var valid: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The formatting commands `/` lists, narrowed by what is typed after it.
    private var suggestions: [(id: String, symbol: String, title: String, detail: String?, pick: () -> Void)] {
        guard let token, token.hasPrefix("/") else { return [] }
        let query = token.dropFirst().lowercased()
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
        ]
        return commands.filter { query.isEmpty || $0.1.lowercased().contains(query) }.map { ($0.1, $0.0, $0.1, $0.2, $0.3) }
    }

    private func intercept(_ selector: Selector) -> Bool {
        let rows = suggestions
        // ⎋ never reaches the window from a text view (AppKit's own cancelOperation
        // swallows it), so the form closes itself — the list of commands first.
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if token != nil, !rows.isEmpty { token = nil } else { finish(nil) }
            return true
        }
        guard token != nil, !rows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): highlighted = (highlighted - 1 + rows.count) % rows.count
        case #selector(NSResponder.moveDown(_:)): highlighted = (highlighted + 1) % rows.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            rows[min(highlighted, rows.count - 1)].pick()
            token = nil
        default: return false
        }
        return true
    }

    var body: some View {
        Group {
            switch style {
            case .island: islandBody
            case .floating: floatingBody
            }
        }
        .background(KeyWindowFocus())
        .onAppear {
            text = editing?.text ?? prompt.initialNotes
            sendTo = Set(NoteSharing.connected(preferences))
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                focused = true
            }
        }
        .onExitCommand { finish(nil) }
    }

    private var markdownEditor: some View {
        MarkdownEditor(text: $text, handle: editor, insertImage: { data in store.saveImage(data) }, insertFile: { url in store.saveAttachment(url) },
                       imageURL: { store.url(for: $0) }, attachmentURL: { store.url(for: $0) }, fontSize: style == .floating ? 17 : 12)
            .focused($focused)
            .overlay(alignment: .bottomLeading) {
                // The floating form lists them in a section of its own, as the task form does.
                if style == .island {
                    suggestionList
                        .padding(.leading, 8)
                        .padding(.bottom, 6)
                        .animation(.easeOut(duration: 0.12), value: token)
                }
            }
            .onAppear {
                editor.onToken = { new in
                    if new != token { highlighted = 0 }
                    token = new?.hasPrefix("/") == true ? new : nil
                }
                editor.interceptCommand = { intercept($0) }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(style == .floating ? "Jot something down" : "Jot something down — the first line is the title · / for formatting")
                        .font(.system(size: style == .floating ? 17 : 13))
                        .foregroundStyle(.primary.opacity(style == .floating ? 0.4 : 0.3))
                        .padding(.horizontal, 12).padding(.top, style == .floating ? 6 : 8)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var suggestionList: some View {
        let rows = suggestions
        if token != nil, !rows.isEmpty {
            let visible = 7
            let first = max(0, min(highlighted - visible + 1, rows.count - visible))
            let shown = Array(rows.enumerated()).filter { $0.offset >= first && $0.offset < first + visible }
            VStack(spacing: 1) {
                ForEach(shown, id: \.element.id) { index, row in
                    HStack(spacing: 9) {
                        Icon(row.symbol, size: 14, weight: .semibold).foregroundStyle(Color.primary.opacity(0.8)).frame(width: 16)
                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let detail = row.detail { Text(detail).font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45)) }
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
            .frame(width: 240)
            .liquidGlass(cornerRadius: 10)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            .accessibilityLabel("Formatting")
        }
    }

    // MARK: Floating

    @State private var showsActions = false

    /// The task form's look: the text on the frosted panel, `/` suggestions as a section
    /// under it, and small buttons floating over its foot — formatting, attach and pin
    /// on the left; Save and Actions on the right.
    private var floatingBody: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                markdownEditor
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                formatSuggestions
            }
            .padding(.bottom, 50)
            footer
        }
        .animation(.easeOut(duration: 0.14), value: token)
        .onChange(of: chrome?.size) { _, size in if let size { preferences.notesPanelSize = size } }
    }

    /// `/` formatting as a list section under the text.
    @ViewBuilder
    private var formatSuggestions: some View {
        let rows = suggestions
        if token != nil, !rows.isEmpty {
            let visible = 5
            let first = max(0, min(highlighted - visible + 1, rows.count - visible))
            let shown = Array(rows.enumerated()).filter { $0.offset >= first && $0.offset < first + visible }
            VStack(alignment: .leading, spacing: 2) {
                Text("Formatting")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(shown, id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        Icon(row.symbol, size: 14, weight: .semibold)
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .frame(width: 26, height: 26)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(row.title).font(.system(size: 14)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let detail = row.detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(index == highlighted ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { row.pick(); token = nil }
                    .onHover { if $0 { highlighted = index } }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityLabel("Formatting")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Menu { formatMenuItems } label: {
                smallGlyph("line.3.horizontal.decrease")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Formatting — or type / in the text")
            Button(action: chooseImage) { smallGlyph("photo") }
                .buttonStyle(.plain)
                .help("Attach an image… (⌘⇧I)")
            if let chrome {
                Button { chrome.pinned.toggle() } label: {
                    Image(systemName: chrome.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(chrome.pinned ? Color.white : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(chrome.pinned ? Color.brand : NotionStyle.card, in: Circle())
                        .overlay(Circle().strokeBorder(.primary.opacity(chrome.pinned ? 0 : 0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(chrome.pinned ? "Pinned: stays open above other apps until closed" : "Pin: keep it open above other apps")
                .animation(.easeOut(duration: 0.15), value: chrome.pinned)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button(action: save) {
                    HStack(spacing: 8) {
                        Text(editing == nil ? (sendTo.isEmpty ? "Save Note" : "Save & Send") : "Save Note")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(valid ? Color.primary : Color.primary.opacity(0.4))
                        HStack(spacing: 3) { RaycastKey("⌘"); RaycastKey("↩") }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!valid)
                .help(sendTo.isEmpty ? "Save (⌘↩)" : "Save and send to \(saveAsLabel) (⌘↩)")

                Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 16)

                Button { showsActions.toggle() } label: {
                    HStack(spacing: 8) {
                        Text("Actions").font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 3) { RaycastKey("⌘"); RaycastKey("K") }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k")
                .popover(isPresented: $showsActions, arrowEdge: .top) { actionsList }
            }
            .padding(.horizontal, 3)
            .frame(height: 28)
            .floatingButton(Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func smallGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .floatingButton(Circle())
    }

    /// What ⌘K lists: paste, attach, pin, where the note goes, cancel.
    private var actionsList: some View {
        VStack(alignment: .leading, spacing: 1) {
            actionSection("Note")
            actionRow("Paste from Clipboard", symbol: "doc.on.clipboard", keys: "⌘V") {
                showsActions = false
                if let textView = editor.textView {
                    textView.window?.makeFirstResponder(textView)
                    textView.paste(nil)
                }
            }
            actionRow("Attach Image…", symbol: "photo", keys: "⇧⌘I") { showsActions = false; chooseImage() }
            if let chrome {
                actionRow(chrome.pinned ? "Unpin" : "Pin Above Other Apps", symbol: chrome.pinned ? "pin.slash" : "pin") {
                    chrome.pinned.toggle()
                    showsActions = false
                }
            }
            if editing == nil, !available.isEmpty {
                actionSection("Send to")
                actionRow("Cue only", symbol: "folder", checked: sendTo.isEmpty) { sendTo = [] }
                ForEach(available) { destination in
                    actionRow(destination.title, symbol: "paperplane", checked: sendTo.contains(destination)) {
                        if sendTo.contains(destination) { sendTo.remove(destination) } else { sendTo.insert(destination) }
                    }
                }
                actionRow("Defaults in Settings…", symbol: "gearshape") {
                    showsActions = false
                    NSApp.sendAction(#selector(AppDelegate.showNotesSettings(_:)), to: nil, from: nil)
                }
            }
            Divider().padding(.vertical, 4)
            actionRow("Cancel", symbol: "xmark", keys: "esc") { showsActions = false; finish(nil) }
        }
        .padding(6)
        .frame(width: 280)
    }

    private func actionSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func actionRow(_ title: String, symbol: String, keys: String? = nil, checked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(symbol, size: 13, weight: .medium).foregroundStyle(Color.primary.opacity(0.7)).frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 6)
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                if let keys { Text(keys).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RaycastRowStyle())
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
            .fieldChrome(focused: focused)
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                if editing == nil, !available.isEmpty {
                    Menu {
                        saveAsItems
                    } label: {
                        HStack(spacing: 6) {
                            Icon("paperplane", size: 14, weight: .semibold)
                            Text(saveAsLabel).font(.system(size: 12, weight: .medium)).lineLimit(1)
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
                Spacer(minLength: 0)
                Button("Cancel") { finish(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.primary.opacity(0.1), in: Capsule())
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text("Save").font(.system(size: 12, weight: .semibold))
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
            Text("/ formats · ⌘B ⌘I")
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

    @ViewBuilder
    private var formatMenuItems: some View {
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
    }

    /// The destinations set up in Settings; the ticked ones get this note.
    private var available: [NoteDestination] { NoteSharing.available(preferences) }

    /// "Cue only", or the chosen destinations.
    private var saveAsLabel: String {
        let chosen = NoteDestination.allCases.filter { sendTo.contains($0) }
        return chosen.isEmpty ? "Cue only" : chosen.map(\.title).joined(separator: " · ")
    }

    /// One tick per destination; "Cue only" clears them. Settings › Notes sets the defaults.
    @ViewBuilder
    private var saveAsItems: some View {
        Button {
            sendTo = []
        } label: {
            if sendTo.isEmpty { Label { Text("Cue only") } icon: { Icon("checkmark", weight: .medium) } } else { Text("Cue only") }
        }
        Divider()
        ForEach(available) { destination in
            Button {
                if sendTo.contains(destination) { sendTo.remove(destination) } else { sendTo.insert(destination) }
            } label: {
                if sendTo.contains(destination) {
                    Label { Text(destination.title) } icon: { Icon("checkmark", weight: .medium) }
                } else {
                    Text(destination.title)
                }
            }
        }
        Divider()
        Button("Defaults in Settings…") { NSApp.sendAction(#selector(AppDelegate.showNotesSettings(_:)), to: nil, from: nil) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let markdown = store.saveImage(data) else { return }
        editor.insertBlock(markdown)
    }

    /// The whole text is the note; `answer.text` carries it back.
    private func save() {
        guard valid else { return }
        finish(PromptAnswer(title: TaskText.title(of: text), text: text, sendTo: editing == nil ? sendTo.map(\.rawValue) : []))
    }

}
