import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The description as Notion edits a page: a column of blocks, each with a + and a
/// handle in the margin under the pointer — + adds a line below with the block menu,
/// the handle drags the block elsewhere or opens what can be done to it — and `/` in
/// any line for the menu of blocks. `markdown` is read once and written on every edit.
struct BlockEditorView: View {
    @Binding var markdown: String
    let services: BlockServices
    /// Bumped to put the caret at the start of the first line.
    var focusRequest = 0
    @State private var model = BlockEditorModel()

    /// The margin the handles hang in, left of the text.
    static let gutter: CGFloat = 46

    var body: some View {
        // Lazy: a block is built when it scrolls into view, so a long description with
        // tables and diagrams opens at once rather than building all of it first.
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(model.blocks) { block in
                BlockRow(block: block, model: model)
                    .zIndex(model.slash?.blockID == block.id || model.menuID == block.id ? 10 : 0)
            }
            // Under the last block: a click there goes on writing.
            Color.clear
                .frame(height: 120)
                .contentShape(Rectangle())
                .onTapGesture { model.focusEnd() }
        }
        .padding(.leading, -Self.gutter)
        .onAppear {
            model.services = services
            model.load(markdown)
            model.onChange = { [binding = $markdown] in binding.wrappedValue = $0 }
            #if DEBUG
            BlockEditorModel.current = model
            #endif
        }
        .onChange(of: focusRequest) { _, _ in
            if let first = model.blocks.first(where: \.isText) { model.focus(first.id, .start) } else { model.focusEnd() }
        }
        .onChange(of: markdown) { _, new in
            // Changed elsewhere (the island, a sync): shown afresh.
            if new != model.markdown { model.load(new) }
        }
    }
}

/// One block with its margin: the handles, the drop line while a block is dragged
/// over it, and the slash menu when it is open in this block.
private struct BlockRow: View {
    let block: DocBlock
    let model: BlockEditorModel
    @State private var height: CGFloat = 30

    private var showsHandles: Bool {
        model.draggingID == nil && (model.hoveredID == block.id || model.menuID == block.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            BlockHandles(block: block, model: model)
                .frame(width: BlockEditorView.gutter, alignment: .trailing)
                .padding(.top, handleOffset)
                .opacity(showsHandles ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: showsHandles)
            BlockContent(block: block, model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { height = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, value in height = value }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { model.hoveredID = block.id } else if model.hoveredID == block.id { model.hoveredID = nil }
        }
        .onDrop(of: [.plainText], delegate: BlockDropDelegate(target: block.id, height: height, model: model))
        .overlay(alignment: model.dropTarget?.below == true ? .bottom : .top) {
            if model.dropTarget?.id == block.id {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(NotionStyle.accent.opacity(0.6))
                    .frame(height: 3)
                    .padding(.leading, BlockEditorView.gutter)
                    .offset(y: model.dropTarget?.below == true ? 2 : -2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if model.slash?.blockID == block.id {
                SlashMenu(model: model)
                    .offset(x: BlockEditorView.gutter - 4, y: height + 2)
            }
        }
    }

    /// The handles sit level with the block's first line.
    private var handleOffset: CGFloat {
        // The block's space above it plus half its first line, less half the handles' height.
        switch BlockChoice.of(block) {
        case .heading1: 22
        case .heading2: 16
        case .heading3: 11
        case .table: 14
        case .code, .mermaid: 11
        case .image: 6
        default: 2
        }
    }
}

/// + and ⋮⋮ in a block's margin.
private struct BlockHandles: View {
    let block: DocBlock
    let model: BlockEditorModel

    var body: some View {
        HStack(spacing: 0) {
            handle("plus", help: "Click to add a block below") { model.addBelow(block.id) }
            DragDots()
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
                .background(model.menuID == block.id ? NotionStyle.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 4))
                .onTapGesture { model.menuID = block.id }
                .onDrag {
                    model.draggingID = block.id
                    model.menuID = nil
                    // Let go anywhere (not only on a block), and the handles come back.
                    DragEnd.whenReleased { [model] in
                        model.draggingID = nil
                        model.dropTarget = nil
                    }
                    return NSItemProvider(object: "cue-block:\(block.id.uuidString)" as NSString)
                } preview: {
                    Text(preview)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 6))
                }
                .help("Drag to move · Click for actions")
                .popover(isPresented: Binding(get: { model.menuID == block.id }, set: { if !$0, model.menuID == block.id { model.menuID = nil } }),
                         arrowEdge: .leading) {
                    BlockActionsMenu(block: block, model: model)
                }
        }
        .padding(.trailing, 4)
    }

    private var preview: String {
        switch block.kind {
        case .text(let line): TaskText.title(of: line).isEmpty ? "Text" : TaskText.title(of: line)
        case .code(let language, _): language.isEmpty ? "Code" : language.capitalized
        case .divider: "Divider"
        case .image: "Image"
        case .file(let name, _): name
        case .table: "Table"
        }
    }

    private func handle(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Light, and as tall as the grip beside it (12.5 pt), the pair one weight.
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(NotionStyle.tertiary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
        .help(help)
    }
}

/// Where a dragged block would land: the drop line follows the pointer over the top or
/// bottom half of each block.
private struct BlockDropDelegate: DropDelegate {
    let target: UUID
    let height: CGFloat
    let model: BlockEditorModel

    func validateDrop(info: DropInfo) -> Bool {
        model.draggingID != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.draggingID != nil else { return nil }
        let target = BlockEditorModel.DropTarget(id: target, below: info.location.y > height / 2)
        if model.dropTarget != target { model.dropTarget = target }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropTarget?.id == target { model.dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            model.dropTarget = nil
            model.draggingID = nil
        }
        guard let dragging = model.draggingID, let landing = model.dropTarget else { return false }
        withAnimation(.easeOut(duration: 0.18)) { model.move(dragging, to: landing) }
        return true
    }
}

// MARK: - Block content

private struct BlockContent: View {
    let block: DocBlock
    let model: BlockEditorModel

    var body: some View {
        switch block.kind {
        case .text(let line):
            BlockTextRepresentable(id: block.id, line: line, listStart: model.listNumber(of: block.id), model: model)
                .padding(verticalPadding(for: line))
        case .code(let language, let code):
            CodeBlockView(id: block.id, language: language, code: code, model: model)
                .padding(.vertical, 6)
        case .divider:
            Hairline()
                .padding(.vertical, 14)
                .contentShape(Rectangle().inset(by: -8))
        case .image(let alt, let source):
            ImageBlockView(id: block.id, alt: alt, source: source, model: model)
                .padding(.vertical, 6)
        case .file(let name, let source):
            FileBlockView(name: name, source: source, services: model.services)
                .padding(.vertical, 3)
        case .table(let table):
            TableBlockView(id: block.id, table: table, model: model)
                .padding(.vertical, 8)
        }
    }

    /// Room above a heading, as on a Notion page.
    private func verticalPadding(for line: String) -> EdgeInsets {
        switch EditorBlock.from(mark: TaskText.splitMark(line).mark) {
        case .heading1: EdgeInsets(top: 18, leading: 0, bottom: 2, trailing: 0)
        case .heading2: EdgeInsets(top: 14, leading: 0, bottom: 2, trailing: 0)
        case .heading3: EdgeInsets(top: 10, leading: 0, bottom: 1, trailing: 0)
        default: EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0)
        }
    }
}

/// An image in a note or a task: as wide as it was dragged to be, else its own width
/// up to the column's. A click opens it in the viewer; the handle on its right edge
/// drags it narrower or wider, and a double-click on that handle puts it back.
///
/// The width is kept in the Markdown the way Obsidian keeps it — `![alt|420](src)` —
/// so a note resized here is the same width in Obsidian, and a note written there
/// arrives at the width it was given.
private struct ImageBlockView: View {
    let id: UUID
    let alt: String
    let source: String
    let model: BlockEditorModel
    @State private var hovering = false
    /// The width while the handle is being dragged, before it is written down.
    @State private var dragging: CGFloat?

    /// Narrower than this and there is nothing to see.
    private static let smallest: CGFloat = 80
    /// The column an image may fill at most.
    private static let widest: CGFloat = 720

    private var services: BlockServices { model.services }
    private var text: String { ImageSize.split(alt).text }
    private var storedWidth: CGFloat? { ImageSize.split(alt).width }

    var body: some View {
        if let url = services.imageURL(source), let image = ImageCache.image(at: url) {
            let natural = min(image.size.width, Self.widest)
            let width = dragging ?? storedWidth ?? natural
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if hovering, dragging == nil {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .trailing) { handle(natural: natural, width: width) }
                .onHover { hovering = $0 }
                .onTapGesture { services.openImage(url) }
                .help("Click to view full size; drag the bar on the right to resize")
                .accessibilityLabel(text.isEmpty ? "Image" : text)
                .accessibilityValue("\(Int(width)) points wide")
                .accessibilityAddTraits(.isButton)
                // The handle is a thin target; the frame changing under the pointer
                // must not make it flicker, so the row keeps its hover while dragging.
                .animation(dragging == nil ? .easeOut(duration: 0.12) : nil, value: width)
        } else if let remote = URL(string: source), remote.scheme?.hasPrefix("http") == true {
            AsyncImage(url: remote) { image in
                image.resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 4))
            } placeholder: {
                ProgressView().controlSize(.small).frame(height: 60)
            }
            .frame(maxWidth: storedWidth ?? Self.widest, alignment: .leading)
        } else {
            Label(text.isEmpty ? "Image not found" : text, systemImage: "photo")
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.tertiary)
        }
    }

    /// The grab bar down the image's right edge: a pill that shows while the pointer
    /// is on the image, and stays while it is being dragged.
    private func handle(natural: CGFloat, width: CGFloat) -> some View {
        let showing = hovering || dragging != nil
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white.opacity(0.9))
            .frame(width: 4, height: 38)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .opacity(showing ? 1 : 0)
            .padding(.trailing, 6)
            .contentShape(Rectangle().inset(by: -10))
            .onHover { over in
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let from = dragging ?? width
                        if dragging == nil { dragging = from }
                        dragging = min(max(from + value.translation.width, Self.smallest), Self.widest)
                    }
                    .onEnded { _ in
                        defer { dragging = nil }
                        guard let final = dragging else { return }
                        // Back to its own width rather than a number that happens to
                        // match it: dragged to the full width, the size is dropped.
                        let width = abs(final - natural) < 6 ? nil : final.rounded()
                        model.update(id, .image(alt: ImageSize.join(text: text, width: width), source: source))
                    }
            )
            .onTapGesture(count: 2) {
                model.update(id, .image(alt: text, source: source))
            }
            .help("Drag to resize, double-click for its own size")
    }
}

/// An image's width inside its alt text, as Obsidian writes it: `alt|420`.
enum ImageSize {
    /// The alt text and the width in it, if any.
    static func split(_ alt: String) -> (text: String, width: CGFloat?) {
        guard let bar = alt.lastIndex(of: "|") else { return (alt, nil) }
        let tail = alt[alt.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        // Obsidian also writes `alt|400x300`; only the width is ours to keep.
        let number = tail.prefix { $0.isNumber }
        guard !number.isEmpty, number.count == tail.count || tail.dropFirst(number.count).first == "x",
              let width = Double(number), width > 0 else { return (alt, nil) }
        return (String(alt[..<bar]), CGFloat(width))
    }

    /// The alt text with a width put back on, or without one when it is nil.
    static func join(text: String, width: CGFloat?) -> String {
        guard let width else { return text }
        return "\(text)|\(Int(width))"
    }
}

private struct FileBlockView: View {
    let name: String
    let source: String
    let services: BlockServices

    var body: some View {
        Button {
            if let url = services.attachmentURL(source) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                if let url = services.attachmentURL(source) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "doc").frame(width: 20)
                }
                Text(name).font(.system(size: 15)).underline(color: NotionStyle.tertiary)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
        .help("Open \(name)")
    }
}

// MARK: - Menus

/// The floating block menu `/` opens: blocks by section, narrowed by what is typed
/// after the `/`, the highlighted one chosen with ↩ (or a click); ⎋ closes it.
private struct SlashMenu: View {
    let model: BlockEditorModel

    var body: some View {
        let choices = model.slashChoices
        let highlighted = model.slash?.highlighted ?? 0
        VStack(alignment: .leading, spacing: 0) {
            if choices.isEmpty {
                Text("No results")
                    .font(.system(size: 13))
                    .foregroundStyle(NotionStyle.tertiary)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(BlockChoice.Section.allCases, id: \.self) { section in
                                let items = choices.filter { $0.section == section }
                                if !items.isEmpty {
                                    Text(section.rawValue)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(NotionStyle.tertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                    ForEach(items) { choice in
                                        row(choice, highlighted: choices.firstIndex(of: choice) == highlighted)
                                            .id(choice)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.bottom, 6)
                    }
                    .thinScrollers()
                    .frame(maxHeight: 320)
                    .onChange(of: highlighted) { _, value in
                        if choices.indices.contains(value) { proxy.scrollTo(choices[value], anchor: .center) }
                    }
                }
            }
            Hairline()
            Button {
                model.slashKey(.cancel)
            } label: {
                HStack {
                    Text("Close menu").font(.system(size: 13))
                    Spacer()
                    Text("esc").font(.system(size: 12)).foregroundStyle(NotionStyle.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(NotionStyle.divider))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .foregroundStyle(NotionStyle.text)
    }

    private func row(_ choice: BlockChoice, highlighted: Bool) -> some View {
        Button {
            model.chooseSlash(choice)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(NotionStyle.secondary)
                    .frame(width: 26, height: 26)
                    .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NotionStyle.divider))
                Text(choice.title).font(.system(size: 14))
                Spacer()
                if let shortcut = choice.shortcut {
                    Text(shortcut).font(.system(size: 12, design: .monospaced)).foregroundStyle(NotionStyle.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(highlighted ? NotionStyle.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in
            guard over, var state = model.slash, let index = model.slashChoices.firstIndex(of: choice), state.highlighted != index else { return }
            state.highlighted = index
            model.slash = state
        }
    }
}

/// What the handle's click offers: Turn into, then Duplicate, Move up / down, Copy as
/// Markdown and Delete.
private struct BlockActionsMenu: View {
    let block: DocBlock
    let model: BlockEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if turnable {
                Text("Turn into")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotionStyle.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(turnChoices) { choice in
                    item(choice.title, symbol: choice.symbol, checked: BlockChoice.of(block) == choice) {
                        model.turn(block.id, into: choice)
                    }
                }
                Divider().padding(.vertical, 4)
            }
            item("Duplicate", symbol: "plus.square.on.square") { model.duplicate(block.id) }
            item("Move up", symbol: "arrow.up") { model.move(block.id, by: -1) }
            item("Move down", symbol: "arrow.down") { model.move(block.id, by: 1) }
            item("Copy as Markdown", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.markdown(of: block.id), forType: .string)
            }
            Divider().padding(.vertical, 4)
            item("Delete", symbol: "trash", tint: .red) { model.delete(block.id) }
        }
        .padding(6)
        .frame(width: 230)
    }

    private var turnable: Bool {
        switch block.kind {
        case .text, .code: true
        default: false
        }
    }

    private var turnChoices: [BlockChoice] {
        [.text, .heading1, .heading2, .heading3, .bullet, .numbered, .todo, .quote, .code, .mermaid]
    }

    private func item(_ title: String, symbol: String, checked: Bool = false, tint: Color = NotionStyle.text, action: @escaping () -> Void) -> some View {
        Button {
            model.menuID = nil
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(tint == NotionStyle.text ? NotionStyle.secondary : tint)
                Text(title).font(.system(size: 14)).foregroundStyle(tint)
                Spacer()
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(NotionStyle.secondary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotionHoverStyle())
    }
}
