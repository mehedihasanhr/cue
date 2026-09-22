import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// The note form: one Markdown text whose first line is the title, with the
/// formatting bar (images can be pasted or dropped in) and, when a destination is
/// set up, a Send menu. In the island it has a header and pill buttons; floating
/// (the quick note, ⌥⇧M) it is one pane of glass with round buttons under the text.
struct NoteFormRow: View {
    enum Style { case island, floating }

    let prompt: IslandPrompt
    let store: NoteStore
    var style: Style = .island
    let finish: (PromptAnswer?) -> Void

    @Environment(AppPreferences.self) private var preferences
    @State private var text = ""
    @State private var editor = MarkdownEditor.Handle()
    @FocusState private var focused: Bool
    /// The `/` token at the caret and the row highlighted in the list it brings up.
    @State private var token: String?
    @State private var highlighted = 0

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
        guard token != nil, !rows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): highlighted = (highlighted - 1 + rows.count) % rows.count
        case #selector(NSResponder.moveDown(_:)): highlighted = (highlighted + 1) % rows.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            rows[min(highlighted, rows.count - 1)].pick()
            token = nil
        case #selector(NSResponder.cancelOperation(_:)): token = nil
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
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                focused = true
            }
        }
        .onExitCommand { finish(nil) }
    }

    private var markdownEditor: some View {
        MarkdownEditor(text: $text, handle: editor, insertImage: { data in store.saveImage(data) }, insertFile: { url in store.saveAttachment(url) },
                       imageURL: { store.url(for: $0) }, attachmentURL: { store.url(for: $0) }, fontSize: style == .floating ? 13 : 12)
            .focused($focused)
            .overlay(alignment: .bottomLeading) {
                suggestionList
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
                    .animation(.easeOut(duration: 0.12), value: token)
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
                    Text("Jot something down — the first line is the title · / for formatting")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.3))
                        .padding(.horizontal, 12).padding(.top, 8)
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

    private var floatingBody: some View {
        VStack(spacing: 0) {
            WindowDragStrip()
                .frame(height: 14)
                .overlay { Capsule().fill(.primary.opacity(0.18)).frame(width: 36, height: 4) }
            markdownEditor
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
            floatingBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var floatingBar: some View {
        let bar = HStack(spacing: 8) {
            floatingGlyph("plus", help: "Attach an image… (⌘⇧I)") { chooseImage() }
            Menu {
                formatMenuItems
            } label: {
                Text("/")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .glassCircle()
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Formatting — type / in the text")
            Spacer(minLength: 0)
            Menu {
                sendMenuItems
            } label: {
                HStack(spacing: 6) {
                    Icon("paperplane", size: 14, weight: .semibold)
                    Text("Send").font(.system(size: 13, weight: .medium))
                    Icon("chevron.down", size: 11, weight: .bold).foregroundStyle(.primary.opacity(0.5))
                }
                .foregroundStyle(.primary.opacity(0.9))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .glassPill()
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!valid)
            .help("Save the note and send it to Obsidian, Apple Notes or Notion")
            Button(action: save) {
                Icon("arrow.up", size: 18, weight: .bold)
                    .foregroundStyle(valid ? Color.white : Color.primary.opacity(0.5))
                    .frame(width: 34, height: 34)
                    .glassCircle(tint: valid ? Color.brand : nil)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!valid)
            .help("Save (⌘↩)")
            .animation(.easeOut(duration: 0.15), value: valid)
        }
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { bar }
        } else {
            bar
        }
    }

    private func floatingGlyph(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, size: 19, weight: .medium)
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 34, height: 34)
                .glassCircle()
                .contentShape(Circle())
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
            .fieldChrome(focused: focused)
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Menu {
                    sendMenuItems
                } label: {
                    HStack(spacing: 6) {
                        Icon("paperplane", size: 14, weight: .semibold)
                        Text("Send to").font(.system(size: 12, weight: .medium))
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
                .disabled(!valid)
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

    /// Obsidian, Apple Notes, Notion — each saves the note first, then sends it.
    @ViewBuilder
    private var sendMenuItems: some View {
        ForEach(NoteDestination.allCases) { destination in
            Button {
                send(to: destination)
            } label: {
                Label { Text(destination.title) } icon: { Icon(destination.symbol, weight: .medium) }
            }
        }
        Divider()
        Button("Set up in Settings…") { NSApp.sendAction(#selector(AppDelegate.showNotesSettings(_:)), to: nil, from: nil) }
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
        finish(PromptAnswer(title: TaskText.title(of: text), text: text))
    }

    /// Saves (or updates) the note here and now, closes, and sends the saved note;
    /// `answer.name` carries the note's id so the caller does not save it again.
    private func send(to destination: NoteDestination) {
        guard valid else { return }
        let saved = editing.map { store.update($0, text: text) } ?? store.add(text: text)
        guard let saved else { return }
        finish(PromptAnswer(title: saved.title, text: saved.text, name: saved.id))
        NoteSharing.sendWithFeedback(saved, to: destination, preferences: preferences)
    }
}
