import AppKit
import SwiftUI

/// The clipboard history alone, as a keyboard-driven list (⌘⇧C by default): type to
/// filter, ↑↓ to choose, ↩ to paste the entry into the front app (⌘↩ copies only),
/// ⌘1–⌘9 for the first nine, ⎋ to close. Pinned entries come first.
struct ClipboardPanelView: View {
    static let size = CGSize(width: 440, height: 480)

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

    private var items: [ClipboardItem] {
        let terms = search.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let all = clipboard.items.filter { item in
            terms.allSatisfy { term in
                [item.title, item.text, item.sourceName ?? "", item.name ?? ""].contains { $0.lowercased().contains(term) }
            }
        }
        return all.filter(\.pinned) + all.filter { !$0.pinned }
    }

    var body: some View {
        let items = items
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                TextField("Search the clipboard", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
                    .accessibilityLabel(search.isEmpty ? "\(items.count) entries" : "\(items.count) matches")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.white.opacity(0.08), in: Capsule(style: .continuous))

            if items.isEmpty {
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
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if let title = heading(before: index, in: items) {
                                    Text(title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .padding(.horizontal, 8)
                                        .padding(.top, index == 0 ? 2 : 8)
                                        .padding(.bottom, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                row(item, index: index, selected: index == selected || inRange(index))
                                    .id(item.id)
                            }
                        }
                    }
                    .onChange(of: selected) { _, index in
                        guard items.indices.contains(index) else { return }
                        proxy.scrollTo(items[index].id, anchor: nil)
                    }
                }
            }

            // What fits in the width; ⌥↩ (plain) and ⇧↑↓ (several) work unlisted.
            HStack(spacing: 10) {
                hint("↑↓", "choose")
                hint("↩", clipboard.canPaste ? "paste" : "copy")
                hint("⌘↩", "copy")
                hint("⌘P", "pin")
                Spacer(minLength: 0)
                hint("⎋", "close")
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Keys: up and down choose, return \(clipboard.canPaste ? "pastes" : "copies"), command return copies, command 1 to 9 pick a row, command P pins, command delete removes, escape closes")
        }
        .padding(14)
        .background { shortcuts(items) }
        .foregroundStyle(.white)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private func row(_ item: ClipboardItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if item.kind == .color, let color = PickedColor(hex: item.text) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.swiftUIColor)
                } else if item.kind == .image, let image = clipboard.thumbnail(for: item) {
                    Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                } else {
                    Image(systemName: symbol(for: item)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 44, height: 30)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if item.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                    if let icon = clipboard.sourceIcon(for: item) {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text("\(item.sourceName ?? item.kind.rawValue.capitalized) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if done == item.id {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 0.85 : 0.45))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Color.brand.opacity(0.8) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { paste(at: index, in: items) }
        .onHover { if $0 { self.selected = index } }
        .contextMenu {
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

    /// "Pinned" over the pinned rows and "Recent" over the rest — only when both are
    /// there and nothing is being searched for, so the list stays a plain list.
    private func heading(before index: Int, in items: [ClipboardItem]) -> String? {
        guard search.isEmpty, items.contains(where: \.pinned), items.contains(where: { !$0.pinned }) else { return nil }
        if index == 0 { return items[0].pinned ? "Pinned" : "Recent" }
        guard items[index - 1].pinned, !items[index].pinned else { return nil }
        return "Recent"
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            close()
            clipboard.copy(text: result)
            if !clipboard.pressPaste(returningTo: frontField) { onNeedsAccessibility() }
        }
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
        HStack(spacing: 4) {
            KeyCap(key)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
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

    /// Copies the row, shows its tick for a beat, closes, and presses ⌘V in the front
    /// app. No status: the tick is the confirmation.
    private func paste(at index: Int, in items: [ClipboardItem]) {
        guard items.indices.contains(index), done == nil else { return }
        // Several rows: one paste, top row first, joined by newlines.
        if index == selected, let several = range(in: items) {
            done = several.last?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                close()
                clipboard.copy(text: several.map(\.text).joined(separator: "\n"))
                if !clipboard.pressPaste(returningTo: frontField) { onNeedsAccessibility() }
            }
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

    private func take(_ item: ClipboardItem, then action: @escaping () -> Void) {
        clipboard.copy(item)
        done = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            close()
            action()
        }
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
