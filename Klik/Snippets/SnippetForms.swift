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
                    BuiltInChips { editor.insert($0) }
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

/// Fills a snippet's blanks before it is pasted: the whole template, laid out as it
/// will read, with each `{{blank}}` an inline field. A click on a blank focuses it,
/// ⇥ / ⇧⇥ move between them, ↩ in the last one (or ⌘↩) pastes.
struct SnippetFillRow: View {
    let snippet: Snippet
    let finish: (PromptAnswer?) -> Void
    /// The template's natural width (unwrapped) and its height at the current width,
    /// so the panel can fit itself to the content.
    var onContentSize: (_ naturalWidth: CGFloat, _ height: CGFloat) -> Void = { _, _ in }

    @State private var values: [String: String] = [:]
    @State private var naturalWidth: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focused: String?

    var body: some View {
        let blanks = snippet.placeholders
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PromptBadge(symbol: "text.badge.checkmark")
                PromptLabel("Fill in \(snippet.title)")
                Spacer(minLength: 0)
                KeyCap("⇥")
                Text("next blank").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
                KeyCap("esc")
                Text("cancel").font(.system(size: 10)).foregroundStyle(.primary.opacity(0.45))
            }
            ScrollView {
                TemplateFillView(template: snippet.text, values: $values, focused: $focused) { blank in
                    if let index = blanks.firstIndex(of: blank), index + 1 < blanks.count { focused = blanks[index + 1] } else { paste() }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeight = height
                    onContentSize(naturalWidth, height)
                }
                .background {
                    // The unwrapped width, from a hidden copy laid out without a width —
                    // measured once, then dropped so it costs nothing while typing.
                    if naturalWidth == 0 {
                        TemplateFillView(template: snippet.text, values: .constant([:]), focused: $focused)
                            .fixedSize()
                            .hidden()
                            .disabled(true)
                            .accessibilityHidden(true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                naturalWidth = width + 24
                                onContentSize(naturalWidth, contentHeight)
                            }
                    }
                }
            }
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.15)))
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Text(blanks.count == 1 ? "1 blank" : "\(blanks.count) blanks")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary.opacity(0.5))
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

    private func paste() {
        finish(PromptAnswer(title: snippet.keyword, values: values))
    }
}

/// The template as flowing text with an inline field for each `{{blank}}`; the
/// built-in blanks show what they will be filled with.
struct TemplateFillView: View {
    let template: String
    @Binding var values: [String: String]
    var focused: FocusState<String?>.Binding
    /// ↩ in a blank.
    var submit: (String) -> Void = { _ in }

    private enum Token: Hashable {
        case word(String)
        case blank(String)
        case builtIn(String)
        case newline
    }

    /// Parsed once per template, not on every keystroke into a blank.
    @State private var tokens: [Token] = []
    /// The built-ins' values, read once when the form opens (the clipboard at that
    /// moment), not on every layout.
    @State private var builtIns: [String: String] = [:]

    private static func tokenize(_ template: String) -> [Token] {
        var result: [Token] = []
        var rest = Substring(template)
        func words(_ text: Substring) {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { result.append(.newline) }
                for word in line.split(whereSeparator: \.isWhitespace) { result.append(.word(String(word))) }
            }
        }
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            words(rest[..<open.lowerBound])
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result.append(SnippetTemplate.isBuiltIn(name) ? .builtIn(name) : .blank(name))
            rest = rest[close.upperBound...]
        }
        words(rest)
        return result
    }

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 8) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .word(let word):
                    Text(word).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.9)).frame(height: 18)
                case .newline:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: LineBreak.self, value: true)
                case .builtIn(let name):
                    Text(builtIns[name] ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.7))
                        .padding(.horizontal, 4)
                        .frame(height: 18)
                        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .help("{{\(name)}} fills itself")
                case .blank(let name):
                    blankField(name)
                }
            }
        }
        .onAppear {
            guard tokens.isEmpty else { return }
            tokens = Self.tokenize(template)
            let clipboard = NSPasteboard.general.string(forType: .string)
            for case .builtIn(let name) in tokens where builtIns[name] == nil {
                builtIns[name] = SnippetTemplate.expand("{{\(name)}}", values: [:], clipboard: clipboard)
            }
        }
    }

    /// An inline field that reads like the text around it: the same font, a tint
    /// and an underline instead of a box; it grows with what is typed and lights
    /// up while focused.
    private func blankField(_ name: String) -> some View {
        let text = Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
        let active = focused.wrappedValue == name
        let shown = text.wrappedValue.isEmpty ? name : text.wrappedValue
        let width = max(36, (shown as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 10)
        return TextField(name, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.85))
            .focused(focused, equals: name)
            .onSubmit { submit(name) }
            .padding(.horizontal, 4)
            .frame(width: width, height: 18)
            .background((active ? Color.brand : Color.primary).opacity(active ? 0.2 : 0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(alignment: .bottom) {
                Rectangle().fill(active ? Color.brand : Color.primary.opacity(0.35)).frame(height: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = name }
    }
}

/// Marks a subview that forces the flow onto a new line.
nonisolated private struct LineBreak: LayoutValueKey {
    static let defaultValue = false
}

/// Lays subviews out left to right, wrapping like text; a `LineBreak` subview starts
/// a new row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    private struct Placement {
        var origin: CGPoint
        var size: CGSize
    }

    /// Subview sizes and whether each breaks the line, measured once per layout pass
    /// rather than once for the size and again for the placement.
    struct Cache {
        var sizes: [CGSize] = []
        var breaks: [Bool] = []
    }

    func makeCache(subviews: Subviews) -> Cache { measure(subviews) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = measure(subviews) }

    private func measure(_ subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, breaks: subviews.map { $0[LineBreak.self] })
    }

    /// Rows wrap at `width` (never, when nil); items sit centred in their row.
    private func place(_ cache: Cache, width: CGFloat?) -> (placements: [Placement], size: CGSize) {
        var placements: [Placement] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        var rowStart = 0
        func closeRow() {
            for index in rowStart..<placements.count {
                placements[index].origin.y += (rowHeight - placements[index].size.height) / 2
            }
            rowStart = placements.count
        }
        for (size, breaksLine) in zip(cache.sizes, cache.breaks) {
            if breaksLine {
                closeRow()
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
                placements.append(Placement(origin: CGPoint(x: x, y: y), size: .zero))
                rowStart = placements.count
                continue
            }
            if let width, x > 0, x + size.width > width {
                closeRow()
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            placements.append(Placement(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        closeRow()
        return (placements, CGSize(width: maxX, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let laid = place(cache, width: proposal.width)
        return CGSize(width: proposal.width ?? laid.size.width, height: laid.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let laid = place(cache, width: bounds.width)
        for (subview, placement) in zip(subviews, laid.placements) {
            subview.place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(placement.size))
        }
    }
}


// MARK: - Built-in chips

/// One built-in a snippet can use: what to insert and what it does.
private struct BuiltIn: Identifiable {
    let token: String
    let insert: String
    let about: String
    var id: String { token }

    static let all: [BuiltIn] = [
        BuiltIn(token: "{{Name}}", insert: "{{Name}}", about: "A blank: Klik asks for it when the snippet is pasted (any word works)."),
        BuiltIn(token: "{{date}}", insert: "{{date}}", about: "Today, written out — September 20, 2026."),
        BuiltIn(token: "{{time}}", insert: "{{time}}", about: "The time now — 5:20 PM."),
        BuiltIn(token: "{{datetime}}", insert: "{{datetime}}", about: "Date and time — Sep 20, 2026 at 5:20 PM."),
        BuiltIn(token: "{{date:yyyy-MM-dd}}", insert: "{{date:yyyy-MM-dd}}", about: "The date in a format of your own: yyyy-MM-dd, EEEE, MMM d… ({{time:HH:mm}} too)."),
        BuiltIn(token: "{{clipboard}}", insert: "{{clipboard}}", about: "Whatever is on the clipboard at that moment."),
        BuiltIn(token: "{{uuid}}", insert: "{{uuid}}", about: "A fresh UUID."),
        BuiltIn(token: "{{cursor}}", insert: "{{cursor}}", about: "Where the caret lands after the paste."),
        BuiltIn(token: "{{shell:…}}", insert: "{{shell:}}", about: "What a shell command prints — {{shell:git branch --show-current}} — given two seconds, inside Klik's sandbox."),
    ]
}

/// The built-ins as chips in a row that scrolls sideways, fading at the edges when
/// there is more; ⓘ opens the whole list with what each one does.
private struct BuiltInChips: View {
    let insert: (String) -> Void
    @State private var showingAll = false
    @State private var scrolledToStart = true
    @State private var scrolledToEnd = false

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BuiltIn.all) { builtIn in
                        Button { insert(builtIn.insert) } label: {
                            Text(builtIn.token)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(builtIn.token == "{{Name}}" ? Color.brand : .primary.opacity(0.8))
                                .fixedSize()
                                .padding(.horizontal, 7).frame(height: 20)
                                .background(builtIn.token == "{{Name}}" ? Color.brand.opacity(0.14) : .primary.opacity(0.1), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(builtIn.about)
                        .accessibilityLabel(builtIn.token)
                        .accessibilityHint(builtIn.about)
                    }
                }
                .onGeometryChange(for: [Bool].self) { proxy in
                    let frame = proxy.frame(in: .named("chips"))
                    let width = proxy.bounds(of: .named("chips"))?.width ?? 0
                    return [frame.minX >= -1, frame.maxX <= width + 1]
                } action: { edges in
                    scrolledToStart = edges[0]
                    scrolledToEnd = edges[1]
                }
            }
            .coordinateSpace(name: "chips")
            .mask {
                // Fades say there is more to scroll to, on whichever side is hidden.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: scrolledToStart ? 0 : 18)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: scrolledToEnd ? 0 : 18)
                }
                .animation(.easeOut(duration: 0.15), value: scrolledToStart)
                .animation(.easeOut(duration: 0.15), value: scrolledToEnd)
            }
            Button { showingAll.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Every built-in and what it does")
            .accessibilityLabel("About the built-ins")
            .popover(isPresented: $showingAll, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Built-ins").font(.system(size: 12, weight: .semibold))
                    ForEach(BuiltIn.all) { builtIn in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button { insert(builtIn.insert); showingAll = false } label: {
                                Text(builtIn.token)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(builtIn.token == "{{Name}}" ? Color.brand : .primary)
                                    .padding(.horizontal, 6).frame(height: 20)
                                    .background(.primary.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(width: 150, alignment: .leading)
                            Text(builtIn.about).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Click one to insert it at the caret.").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
                }
                .padding(14)
                .frame(width: 440)
            }
        }
    }
}
