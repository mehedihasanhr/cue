import AppKit
import SwiftUI

/// The compact island's snippet form: the keyword, a name, and the template (or the
/// asset the snippet pastes). `{{Name}}` in the template becomes a blank to fill.
struct SnippetFormRow: View {
    let prompt: IslandPrompt
    let store: SnippetStore
    let assets: AssetStore
    let finish: (PromptAnswer?) -> Void

    @Environment(AppPreferences.self) private var preferences
    /// The trigger in front of the keyword: the default from Settings, changeable here.
    @State private var prefix = ""
    @State private var keyword = ""
    @State private var name = ""
    @State private var text = ""
    @State private var editor = MarkdownEditor.Handle()
    @FocusState private var focus: Field?

    private enum Field { case prefix, keyword, name, text }

    /// What gets typed: the prefix and the keyword together.
    private var fullKeyword: String { SnippetStore.cleanKeyword(prefix + keyword) }

    private var editing: Snippet? {
        if case .snippet(let snippet, _, _) = prompt.kind { return snippet }
        return nil
    }

    private var assetID: UUID? {
        if case .snippet(let snippet, _, let asset) = prompt.kind { return snippet?.assetID ?? asset }
        return nil
    }

    private var valid: Bool {
        !SnippetStore.cleanKeyword(keyword).isEmpty && (assetID != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            HStack(spacing: 8) {
                PromptBox {
                    // The trigger, in its own little box; ";" unless changed.
                    TextField("", text: $prefix)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.brand)
                        .multilineTextAlignment(.center)
                        .focused($focus, equals: .prefix)
                        .onSubmit { focus = .keyword }
                        .frame(width: 28)
                        .help("The trigger typed before every keyword (set the default in Settings › Island)")
                    Rectangle().fill(.primary.opacity(0.15)).frame(width: 1, height: 18)
                    TextField("keyword, e.g. welcome", text: $keyword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .focused($focus, equals: .keyword)
                        .onSubmit { focus = .name }
                }
                .frame(width: 220)
                PromptBox {
                    TextField("Name (optional)", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .text }
                        .padding(.horizontal, 8)
                }
            }
            if let assetID, let asset = assets.items.first(where: { $0.id == assetID }) {
                HStack(spacing: 10) {
                    Group {
                        if let thumbnail = assets.thumbnail(for: asset) {
                            Image(nsImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(.primary.opacity(0.6))
                        }
                    }
                    .frame(width: 64, height: 44)
                    .background(.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("Typing the keyword pastes this \(asset.kind == .image ? "image" : "file").")
                            .font(.system(size: 10.5)).foregroundStyle(.primary.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        ForEach(SnippetTemplate.builtIns, id: \.self) { builtIn in
                            Button {
                                editor.insert("{{\(builtIn)}}")
                            } label: {
                                Text("{{\(builtIn)}}")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.8))
                                    .padding(.horizontal, 7).frame(height: 20)
                                    .background(.primary.opacity(0.1), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Fills itself when pasted")
                        }
                        Spacer(minLength: 0)
                        Text("{{Name}} makes a blank to fill when pasting")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.primary.opacity(0.4))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    MarkdownEditor(text: $text, handle: editor, insertImage: { _ in nil }, insertFile: { _ in nil }, onBacktab: { focus = .name })
                        .focused($focus, equals: .text)
                }
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                let blanks = SnippetTemplate.placeholders(in: text).filter { !SnippetTemplate.isBuiltIn($0) }
                Text(fullKeyword.isEmpty ? "Type the keyword anywhere to paste this" : "Type \(fullKeyword) anywhere to paste this" + (blanks.isEmpty ? "" : " · asks for \(blanks.joined(separator: ", "))"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
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
                        Text(editing == nil ? "Create" : "Save").font(.system(size: 12, weight: .semibold))
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
        .background(KeyWindowFocus())
        .onKeyPress(.tab, phases: .down) { press in
            // ⇥ / ⇧⇥ walk the fields (the editor keeps ⇥ for itself).
            let order: [Field] = [.prefix, .keyword, .name, .text]
            guard let current = focus, current != .text || press.modifiers.contains(.shift), let index = order.firstIndex(of: current) else { return .ignored }
            let next = press.modifiers.contains(.shift) ? max(index - 1, 0) : min(index + 1, order.count - 1)
            focus = order[next]
            return .handled
        }
        .onAppear {
            if case .snippet(let snippet, let initialText, _) = prompt.kind {
                let stored = snippet?.keyword ?? ""
                let defaultPrefix = preferences.snippetPrefix
                if !defaultPrefix.isEmpty, stored.hasPrefix(defaultPrefix) {
                    prefix = defaultPrefix
                    keyword = String(stored.dropFirst(defaultPrefix.count))
                } else if stored.isEmpty {
                    prefix = defaultPrefix
                } else {
                    // A keyword saved with another trigger keeps it whole.
                    prefix = ""
                    keyword = stored
                }
                name = snippet?.name ?? ""
                text = snippet?.text ?? initialText
            }
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                focus = .keyword
            }
        }
        .onExitCommand { finish(nil) }
    }

    private func save() {
        guard valid else { return }
        finish(PromptAnswer(title: fullKeyword, notes: text, name: name))
    }
}

/// Fills a snippet's blanks before it is pasted: one field per `{{placeholder}}`.
struct SnippetFillRow: View {
    let snippet: Snippet
    let finish: (PromptAnswer?) -> Void

    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        let blanks = snippet.placeholders
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PromptBadge(symbol: "text.badge.checkmark")
                PromptLabel("Fill in \(snippet.title)")
                Spacer(minLength: 0)
                KeyCap("esc")
                Text("cancel").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blanks.enumerated()), id: \.element) { index, blank in
                        HStack(spacing: 8) {
                            Text(blank)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.7))
                                .frame(width: 110, alignment: .trailing)
                                .lineLimit(1)
                            PromptBox {
                                TextField(blank, text: binding(blank))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .focused($focused, equals: blank)
                                    .onSubmit {
                                        if index + 1 < blanks.count { focused = blanks[index + 1] } else { paste() }
                                    }
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Text(preview)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Cancel") { finish(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.primary.opacity(0.1), in: Capsule())
                Button(action: paste) {
                    HStack(spacing: 6) {
                        Text("Paste").font(.system(size: 12, weight: .semibold))
                        KeyCap("⌘↩")
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 14).padding(.trailing, 8)
                    .frame(height: 30)
                    .background(Color.brand, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(KeyWindowFocus())
        .onKeyPress(.tab, phases: .down) { press in
            // ⇥ / ⇧⇥ move between the blanks, wrapping around.
            guard !blanks.isEmpty else { return .ignored }
            let index = focused.flatMap { blanks.firstIndex(of: $0) } ?? -1
            let next = press.modifiers.contains(.shift) ? (index - 1 + blanks.count) % blanks.count : (index + 1) % blanks.count
            focused = blanks[next]
            return .handled
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                focused = blanks.first
            }
        }
        .onExitCommand { finish(nil) }
    }

    private func binding(_ blank: String) -> Binding<String> {
        Binding(get: { values[blank] ?? "" }, set: { values[blank] = $0 })
    }

    private var preview: String {
        SnippetTemplate.expand(snippet.text, values: values).replacingOccurrences(of: "\n", with: " ")
    }

    private func paste() {
        finish(PromptAnswer(title: snippet.keyword, values: values))
    }
}
