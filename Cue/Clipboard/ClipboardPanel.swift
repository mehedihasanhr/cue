import AppKit
import SwiftUI

/// The clipboard history alone, keyboard-driven (⌘⇧C by default): type to filter,
/// the chips (or ⌘← ⌘→) to narrow to a kind, ↑↓ to choose, ↩ to paste the entry into
/// the front app (⌘↩ copies only), ⌘1–⌘9 for the first nine, ⎋ to close. A list on
/// the left, pinned entries first; the chosen entry in full on the right.
struct ClipboardPanelView: View {
    static let size = CGSize(width: 780, height: 480)
    /// The list's share of the width; the preview takes the rest.
    private static let listWidth: CGFloat = 330

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

    /// The chips: every entry, or one kind.
    @State private var kind: ClipboardItem.Kind?
    private static let kinds: [(ClipboardItem.Kind, String)] = [(.text, "Text"), (.image, "Images"), (.link, "Links"), (.color, "Colors"), (.files, "Files")]
    /// The kinds there are entries of: the only chips worth showing.
    private var presentKinds: [(ClipboardItem.Kind, String)] {
        let present = Set(clipboard.items.map(\.kind))
        return Self.kinds.filter { present.contains($0.0) }
    }

    /// The matching entries, pinned first.
    private var matches: (pinned: [ClipboardItem], recent: [ClipboardItem]) {
        let terms = search.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let all = clipboard.items.filter { item in
            (kind == nil || item.kind == kind) && terms.allSatisfy { term in
                [item.title, item.text, item.sourceName ?? "", item.name ?? ""].contains { $0.lowercased().contains(term) }
            }
        }
        return (all.filter(\.pinned), all.filter { !$0.pinned })
    }

    /// "Pinned" and "Recent" headings — only when both are there and nothing is being
    /// searched for, so the list stays a plain list.
    private var sectioned: Bool {
        let matches = matches
        return search.isEmpty && kind == nil && !matches.pinned.isEmpty && !matches.recent.isEmpty
    }

    /// The rows on screen, top to bottom: what the keys and ⌘1–⌘9 count through.
    private var items: [ClipboardItem] {
        let matches = matches
        guard sectioned else { return matches.pinned + matches.recent }
        return (folded.contains(.pinned) ? [] : matches.pinned) + (folded.contains(.recent) ? [] : matches.recent)
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            searchBar(items)
            chips
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 0) {
                list(items)
                    .frame(width: Self.listWidth)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                Group {
                    if items.indices.contains(selected) {
                        ClipboardPreview(item: items[selected], clipboard: clipboard)
                            .id(items[selected].id)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            footer
        }
        // A darker ground under the glass: the rows must read over a bright desktop.
        .background(Color.black.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background { shortcuts(items) }
        .foregroundStyle(.white)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: kind) { _, _ in selected = 0; anchor = nil }
    }

    private func searchBar(_ items: [ClipboardItem]) -> some View {
        HStack(spacing: 10) {
            Icon("magnifyingglass", size: 17, weight: .medium).foregroundStyle(.white.opacity(0.5))
            TextField("Search clipboard", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .onSubmit { paste(at: selected, in: items) }
                .onKeyPress(.downArrow) { move(1, in: items) }
                .onKeyPress(.upArrow) { move(-1, in: items) }
                .onKeyPress(.downArrow, phases: .down) { press in press.modifiers.contains(.shift) ? extend(1, in: items) : .ignored }
                .onKeyPress(.upArrow, phases: .down) { press in press.modifiers.contains(.shift) ? extend(-1, in: items) : .ignored }
                .onKeyPress(.leftArrow, phases: .down) { press in press.modifiers.contains(.command) ? stepKind(-1) : .ignored }
                .onKeyPress(.rightArrow, phases: .down) { press in press.modifiers.contains(.command) ? stepKind(1) : .ignored }
                .onKeyPress(.home) { jump(to: 0, in: items) }
                .onKeyPress(.end) { jump(to: items.count - 1, in: items) }
                .onKeyPress(.pageUp) { move(-8, in: items) }
                .onKeyPress(.pageDown) { move(8, in: items) }
                .onChange(of: search) { _, _ in selected = 0; anchor = nil }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Icon("xmark.circle.fill", size: 15).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Clear the search (⎋ closes the panel)")
                .accessibilityLabel("Clear the search")
            }
            Text(search.isEmpty && kind == nil ? "\(items.count)" : "\(items.count) of \(clipboard.items.count)")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
                .accessibilityLabel(search.isEmpty ? "\(items.count) entries" : "\(items.count) matches")
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
    }

    /// All, then a chip per kind there is: one click (or ⌘← ⌘→) narrows the list.
    private var chips: some View {
        HStack(spacing: 4) {
            chip("All", selected: kind == nil) { kind = nil }
            ForEach(presentKinds, id: \.0) { value, title in
                chip(title, selected: kind == value) { kind = value }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.white.opacity(selected ? 0.12 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepKind(_ delta: Int) -> KeyPress.Result {
        let order: [ClipboardItem.Kind?] = [nil] + presentKinds.map(\.0)
        let index = order.firstIndex(of: kind) ?? 0
        kind = order[min(max(index + delta, 0), order.count - 1)]
        return .handled
    }

    @ViewBuilder
    private func list(_ items: [ClipboardItem]) -> some View {
        if items.isEmpty && !sectioned {
            VStack(spacing: 6) {
                Icon(clipboard.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass", size: 22).foregroundStyle(.white.opacity(0.3))
                Text(clipboard.items.isEmpty ? "Nothing copied yet" : "No matches")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(clipboard.items.isEmpty ? "Copy anything and it lands here." : "Try fewer words, another kind, or ⎋ to close.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ScrollViewReader { proxy in
                FadingScrollView(depth: 18) {
                    LazyVStack(spacing: 1) {
                        let pinnedCount = items.prefix(while: \.pinned).count
                        if sectioned { heading(.pinned) }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if sectioned, index == pinnedCount { heading(.recent) }
                            row(item, index: index, selected: index == selected || inRange(index))
                                .id(item.id)
                        }
                        if sectioned, pinnedCount == items.count { heading(.recent) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: selected) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id, anchor: nil)
                }
            }
        }
    }

    /// Only what is used most; ⌘1–⌘9, ⌥↩ (plain), ⇧↑↓ (several) and ⌘⌫ work unlisted.
    private var footer: some View {
        HStack(spacing: 16) {
            hint("↩", clipboard.canPaste ? "Paste" : "Copy")
            hint("⌘↩", "Copy")
            hint("⌘P", "Pin")
            Spacer(minLength: 0)
            hint("⌘1–9", "Jump")
        }
        .padding(.horizontal, 18)
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keys: up and down choose, return \(clipboard.canPaste ? "pastes" : "copies"), command return copies, command 1 to 9 pick a row, command P pins, command delete removes, escape closes")
    }

    /// A row: a small tile, the entry on one line and where it came from under it.
    /// The chosen row lifts on a soft fill and shows ↩ and its menu; the rest stay quiet.
    private func row(_ item: ClipboardItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            tile(item)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.88))
                    .lineLimit(1)
                Text("\(item.sourceName ?? item.kind.rawValue.capitalized) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Icon("pin.fill", size: 11).foregroundStyle(.white.opacity(0.45))
            }
            if done == item.id {
                Icon("checkmark", size: 12, weight: .bold).foregroundStyle(.green)
            } else if selected {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Menu {
                    actions(item, index: index)
                } label: {
                    Icon("ellipsis", size: 13, weight: .bold).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(.white.opacity(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    /// A section's heading, small and quiet; a click folds the section's rows away.
    private func heading(_ section: Section) -> some View {
        Button {
            anchor = nil
            selected = 0
            withAnimation(.snappy(duration: 0.2)) {
                if folded.contains(section) { folded.remove(section) } else { folded.insert(section) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(section.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.38))
                Icon("chevron.down", size: 9, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(folded.contains(section) ? -90 : 0))
                Spacer()
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
            Button("Edit") {
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

    /// The row's tile: the picture, the colour, the app it came from, or a symbol for
    /// what it is.
    @ViewBuilder
    private func tile(_ item: ClipboardItem) -> some View {
        if item.kind == .color, let color = PickedColor(hex: item.text) {
            color.swiftUIColor
        } else if item.kind == .image, let image = clipboard.thumbnail(for: item) {
            Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
        } else if item.kind == .text, let icon = clipboard.sourceIcon(for: item) {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: symbol(for: item)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Deletes the row and keeps the selection where it was on screen.
    private func delete(_ item: ClipboardItem, at index: Int, in items: [ClipboardItem]) {
        clipboard.delete(item)
        anchor = nil
        selected = min(index, items.count - 2 >= 0 ? items.count - 2 : 0)
    }

    /// "Paste as" for a text row: the transforms that would change it. The panel
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
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
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

/// The chosen entry in full, beside the list: the picture, the text (code coloured),
/// the colour, the link or the files, and under it where it came from, when, and
/// how big it is.
private struct ClipboardPreview: View {
    let item: ClipboardItem
    let clipboard: ClipboardHistory

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            details
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .task(id: item.id) {
            guard item.kind == .image else { return }
            image = clipboard.thumbnail(for: item)
            // The thumbnail at once; the full picture once it's read.
            if let data = clipboard.imageData(for: item), let full = NSImage(data: data) { image = full }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            } else {
                Icon("photo", size: 28).foregroundStyle(.white.opacity(0.3))
            }
        case .color:
            if let color = PickedColor(hex: item.text) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(color.swiftUIColor)
                        .frame(width: 150, height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                        .shadow(color: color.swiftUIColor.opacity(0.4), radius: 18, y: 6)
                    Text(item.text.uppercased())
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                }
            } else {
                text(item.text)
            }
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                if let host = URL(string: item.text)?.host() {
                    Label { Text(host).font(.system(size: 13, weight: .semibold)) } icon: { Icon("link", size: 14) }
                        .foregroundStyle(.white.opacity(0.9))
                }
                text(item.text)
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.text.split(separator: "\n").map(String.init), id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text:
            text(item.text)
        }
    }

    /// The text from the top, scrolling when long; code in its colours.
    private func text(_ string: String) -> some View {
        ScrollView {
            Group {
                if let language = CodeSnippet.detect(string) {
                    Text(Self.highlighted(string, as: language))
                } else {
                    Text(string).font(.system(size: 13))
                }
            }
            .textSelection(.enabled)
            .foregroundStyle(.white.opacity(0.9))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func highlighted(_ text: String, as language: CodeSnippet.Language) -> AttributedString {
        var code = CodeSnippet.highlighted(text, as: language, limit: 4000)
        code.font = .system(size: 12, design: .monospaced)
        return code
    }

    private var details: some View {
        VStack(spacing: 6) {
            detail("Source") {
                HStack(spacing: 5) {
                    if let icon = clipboard.sourceIcon(for: item) { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                    Text(item.sourceName ?? "Unknown")
                }
            }
            detail("Copied") { Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)) }
            switch item.kind {
            case .image: detail("Size") { Text("\(item.pixelWidth) × \(item.pixelHeight)") }
            case .files: detail("Files") { Text("\(item.text.split(separator: "\n").count)") }
            case .text, .link: detail("Length") { Text("\(item.text.count) characters") }
            case .color: EmptyView()
            }
        }
        .font(.system(size: 11))
    }

    private func detail(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.4))
            Spacer()
            value().foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
    }
}
