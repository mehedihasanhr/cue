import AppKit
import SwiftUI

/// The clipboard history alone, as a keyboard-driven list (⌘⇧C by default): type to
/// filter, ↑↓ to choose, ↩ to paste the entry into the front app (⌘↩ copies only),
/// ⌘1–⌘9 for the first nine, ⎋ to close. Pinned entries come first.
struct ClipboardPanelView: View {
    static let size = CGSize(width: 470, height: 580)

    let clipboard: ClipboardHistory
    /// Closes the panel; called before pasting so ⌘V lands in the front app.
    var close: () -> Void = {}
    /// Pasting needs Accessibility access; asks for it the first time it is missing.
    var onNeedsAccessibility: () -> Void = {}
    /// Opens an image entry in the editor (the panel closes first).
    var onEdit: (ClipboardItem) -> Void = { _ in }
    /// Where the cursor was when the panel opened: the paste goes back there.
    var frontField: FrontField?

    @State private var search = ""
    @State private var selected = 0
    /// With ⇧↑↓, the other end of a range of rows; ↩ then pastes them all, joined.
    @State private var anchor: Int?
    /// The row just taken, shown with a tick for a beat before the panel closes.
    @State private var done: UUID?
    @FocusState private var searchFocused: Bool
    /// Sections folded away by their heading's chevron; their rows leave the list.
    @State private var folded: Set<Section> = []

    private enum Section: String { case pinned = "Pinned", recent = "Recent" }

    /// The matching entries, pinned first.
    private var matches: (pinned: [ClipboardItem], recent: [ClipboardItem]) {
        let terms = search.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let all = clipboard.items.filter { item in
            terms.allSatisfy { term in
                [item.title, item.text, item.sourceName ?? "", item.name ?? ""].contains { $0.lowercased().contains(term) }
            }
        }
        return (all.filter(\.pinned), all.filter { !$0.pinned })
    }

    /// "Pinned" and "Recent" headings — only when both are there and nothing is being
    /// searched for, so the list stays a plain list.
    private var sectioned: Bool {
        let matches = matches
        return search.isEmpty && !matches.pinned.isEmpty && !matches.recent.isEmpty
    }

    /// The rows on screen, top to bottom: what the keys and ⌘1–⌘9 count through.
    private var items: [ClipboardItem] {
        let matches = matches
        guard sectioned else { return matches.pinned + matches.recent }
        return (folded.contains(.pinned) ? [] : matches.pinned) + (folded.contains(.recent) ? [] : matches.recent)
    }

    var body: some View {
        let items = items
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                TextField("Search clipboard", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .focused($searchFocused)
                    .onSubmit { paste(at: selected, in: items) }
                    .onKeyPress(.downArrow) { move(1, in: items) }
                    .onKeyPress(.upArrow) { move(-1, in: items) }
                    .onKeyPress(.downArrow, phases: .down) { press in press.modifiers.contains(.shift) ? extend(1, in: items) : .ignored }
                    .onKeyPress(.upArrow, phases: .down) { press in press.modifiers.contains(.shift) ? extend(-1, in: items) : .ignored }
                    .onKeyPress(.home) { jump(to: 0, in: items) }
                    .onKeyPress(.end) { jump(to: items.count - 1, in: items) }
                    .onKeyPress(.pageUp) { move(-8, in: items) }
                    .onKeyPress(.pageDown) { move(8, in: items) }
                    .onChange(of: search) { _, _ in selected = 0; anchor = nil }
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search (⎋ closes the panel)")
                    .accessibilityLabel("Clear the search")
                }
                Text("\(items.count)")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.1), in: Capsule(style: .continuous))
                    .fixedSize()
                    .accessibilityLabel(search.isEmpty ? "\(items.count) entries" : "\(items.count) matches")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 44)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))

            if items.isEmpty && !sectioned {
                Spacer()
                VStack(spacing: 4) {
                    Text(clipboard.items.isEmpty ? "Nothing copied yet" : "No matches")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(clipboard.items.isEmpty ? "Copy anything and it lands here." : "Try fewer words, or ⎋ to close.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .accessibilityElement(children: .combine)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    FadingScrollView(depth: 22) {
                        LazyVStack(spacing: 2) {
                            let pinnedCount = items.prefix(while: \.pinned).count
                            if sectioned { heading(.pinned) }
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if sectioned, index == pinnedCount { heading(.recent) }
                                row(item, index: index, selected: index == selected || inRange(index),
                                    divided: index >= pinnedCount && index + 1 < items.count && !(index == selected || index + 1 == selected))
                                    .id(item.id)
                            }
                            if sectioned, pinnedCount == items.count { heading(.recent) }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: selected) { _, index in
                        guard items.indices.contains(index) else { return }
                        proxy.scrollTo(items[index].id, anchor: nil)
                    }
                }
            }

            // What fits in the width; ⌥↩ (plain) and ⇧↑↓ (several) work unlisted.
            HStack(spacing: 14) {
                hint("↑↓", "choose")
                hint("↩", clipboard.canPaste ? "paste" : "copy")
                hint("⌘↩", "copy")
                hint("⌘P", "pin")
                Spacer(minLength: 0)
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18)
                hint("esc", "close")
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Keys: up and down choose, return \(clipboard.canPaste ? "pastes" : "copies"), command return copies, command 1 to 9 pick a row, command P pins, command delete removes, escape closes")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background { shortcuts(items) }
        .foregroundStyle(.white)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private func row(_ item: ClipboardItem, index: Int, selected: Bool, divided: Bool) -> some View {
        HStack(spacing: 12) {
            preview(item)
                .frame(width: 66, height: 44)
                .background(.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                    if let icon = clipboard.sourceIcon(for: item) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text("\(item.sourceName ?? item.kind.rawValue.capitalized) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if done == item.id {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
                    .frame(height: 24)
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.6))
                    .frame(minWidth: 30, minHeight: 24)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            Menu {
                actions(item, index: index)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Color.brand.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Color.brand.opacity(0.9) : .clear, lineWidth: 1.5))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(divided ? 0.07 : 0)).frame(height: 1).padding(.horizontal, 8).offset(y: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { paste(at: index, in: items) }
        .onHover { if $0 { self.selected = index } }
        .contextMenu { actions(item, index: index) }
        // One element per row, so VoiceOver reads the entry rather than its parts,
        // and the menu's actions are on the rotor instead of a right-click away.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(describe(item))
        .accessibilityValue(index < 9 ? "Command \(index + 1)" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(clipboard.canPaste ? "Pastes into the app you came from" : "Copies to the clipboard")
        .accessibilityAction { paste(at: index, in: items) }
        .accessibilityAction(named: "Copy") { copy(item) }
        .accessibilityAction(named: item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
        .accessibilityAction(named: "Delete") { delete(item, at: index, in: items) }
    }

    /// What VoiceOver says for a row: what it is, where it came from, when, and
    /// whether it is pinned.
    private func describe(_ item: ClipboardItem) -> String {
        var parts = ["\(item.kind.rawValue.capitalized): \(item.title)"]
        if let source = item.sourceName { parts.append("from \(source)") }
        parts.append(item.createdAt.formatted(.relative(presentation: .named)))
        if item.pinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    /// A section's heading; its chevron folds the section's rows away.
    private func heading(_ section: Section) -> some View {
        Button {
            anchor = nil
            selected = 0
            withAnimation(.snappy(duration: 0.2)) {
                if folded.contains(section) { folded.remove(section) } else { folded.insert(section) }
            }
        } label: {
            HStack {
                Text(section.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(folded.contains(section) ? 0 : 180))
            }
            .padding(.horizontal, 8)
            .padding(.top, section == .pinned ? 4 : 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(folded.contains(section) ? "Folded" : "Shown")
    }

    /// What a row's ⋯ button and right-click offer.
    @ViewBuilder
    private func actions(_ item: ClipboardItem, index: Int) -> some View {
        Button("Paste") { paste(at: index, in: items) }
        Button("Copy") { copy(item) }
            .keyboardShortcut(.return, modifiers: .command)
        if item.kind == .text || item.kind == .link {
            transformMenu(item)
        }
        if item.kind == .image {
            Button("Edit…") {
                close()
                onEdit(item)
            }
        }
        Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            .keyboardShortcut("p", modifiers: .command)
        Divider()
        Button("Delete", role: .destructive) { delete(item, at: index, in: items) }
            .keyboardShortcut(.delete, modifiers: .command)
    }

    /// The row's tile: the picture, the colour, a few lines of the code, the app it
    /// came from, or a symbol for what it is.
    @ViewBuilder
    private func preview(_ item: ClipboardItem) -> some View {
        if item.kind == .color, let color = PickedColor(hex: item.text) {
            color.swiftUIColor
        } else if item.kind == .image, let image = clipboard.thumbnail(for: item) {
            Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
        } else if item.kind == .text, let language = CodeSnippet.detect(item.text) {
            Text(miniature(item.text, as: language))
                .lineLimit(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(.black.opacity(0.35))
        } else if item.kind == .text, let icon = clipboard.sourceIcon(for: item) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
        } else {
            Image(systemName: symbol(for: item)).font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
        }
    }

    /// Code, coloured, at a size that fits a few lines in the tile.
    private func miniature(_ text: String, as language: CodeSnippet.Language) -> AttributedString {
        var code = CodeSnippet.highlighted(text, as: language, limit: 240)
        code.font = .system(size: 5.5, design: .monospaced)
        return code
    }

    /// Deletes the row and keeps the selection where it was on screen.
    private func delete(_ item: ClipboardItem, at index: Int, in items: [ClipboardItem]) {
        clipboard.delete(item)
        anchor = nil
        selected = min(index, items.count - 2 >= 0 ? items.count - 2 : 0)
    }

    /// "Paste as…" for a text row: the transforms that would change it. The panel
    /// closes first so the paste lands where the cursor was.
    private func transformMenu(_ item: ClipboardItem) -> some View {
        Menu("Paste as") {
            ForEach(TextTransform.applicable(to: item.text)) { transform in
                Button(transform.title) { paste(item, as: transform) }
            }
        }
    }

    private func paste(_ item: ClipboardItem, as transform: TextTransform) {
        guard done == nil, let result = transform.apply(to: item.text) else { return }
        done = item.id
        close()
        clipboard.copy(text: result)
        if !clipboard.pressPaste(returningTo: frontField) { onNeedsAccessibility() }
    }

    /// ⌘↩ copies without pasting; ⌥↩ pastes as plain text; ⌘1–⌘9 take a row straight away.
    private func shortcuts(_ items: [ClipboardItem]) -> some View {
        Group {
            Button("") { if items.indices.contains(selected) { copy(items[selected]) } }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { if items.indices.contains(selected) { paste(items[selected], as: .plain) } }
                .keyboardShortcut(.return, modifiers: .option)
            ForEach(0..<9, id: \.self) { index in
                Button("") { paste(at: index, in: items) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("") { if items.indices.contains(selected) { clipboard.togglePin(items[selected]) } }
                .keyboardShortcut("p", modifiers: .command)
            Button("") { if items.indices.contains(selected) { delete(items[selected], at: selected, in: items) } }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .frame(minWidth: 26, minHeight: 22)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            Text(label).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
        }
        .fixedSize()
    }

    private func move(_ delta: Int, in items: [ClipboardItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        anchor = nil
        selected = min(max(selected + delta, 0), items.count - 1)
        return .handled
    }

    private func jump(to index: Int, in items: [ClipboardItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        anchor = nil
        selected = min(max(index, 0), items.count - 1)
        return .handled
    }

    private func extend(_ delta: Int, in items: [ClipboardItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        if anchor == nil { anchor = selected }
        selected = min(max(selected + delta, 0), items.count - 1)
        return .handled
    }

    private func inRange(_ index: Int) -> Bool {
        guard let anchor else { return false }
        return (min(anchor, selected)...max(anchor, selected)).contains(index)
    }

    /// The rows in the ⇧-selected range, top to bottom (nil: just the one).
    private func range(in items: [ClipboardItem]) -> [ClipboardItem]? {
        guard let anchor, anchor != selected else { return nil }
        return Array(items[min(anchor, selected)...max(anchor, selected)])
    }

    /// Copies the row, closes, and presses ⌘V in the front app straight away.
    private func paste(at index: Int, in items: [ClipboardItem]) {
        guard items.indices.contains(index), done == nil else { return }
        // Several rows: one paste, top row first, joined by newlines.
        if index == selected, let several = range(in: items) {
            done = several.last?.id
            close()
            clipboard.copy(text: several.map(\.text).joined(separator: "\n"))
            if !clipboard.pressPaste(returningTo: frontField) { onNeedsAccessibility() }
            return
        }
        let item = items[index]
        take(item) {
            if !clipboard.pressPaste(returningTo: frontField) { onNeedsAccessibility() }
        }
    }

    private func copy(_ item: ClipboardItem) {
        guard done == nil else { return }
        take(item) {}
    }

    /// Copies and closes at once: a paste must not wait on a tick to be seen.
    private func take(_ item: ClipboardItem, then action: @escaping () -> Void) {
        clipboard.copy(item)
        done = item.id
        close()
        action()
    }

    private func symbol(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "paintpalette"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}
