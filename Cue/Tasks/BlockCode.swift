import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A code block, as Notion draws one: the language at the top left, the code in a
/// monospaced editor on a tinted ground, and on hover a toolbar at the top right —
/// the language to pick, then for a Mermaid diagram how to show it (code, diagram or
/// both), zoom and download; for every block copy, line wrap and more.
struct CodeBlockView: View {
    let id: UUID
    let language: String
    let code: String
    let model: BlockEditorModel
    @State private var hovering = false
    @State private var mode: DiagramMode = .preview
    @State private var wraps = true
    @State private var diagram = MermaidController()

    enum DiagramMode: String, CaseIterable {
        case code = "Code", preview = "Preview", split = "Split"

        var symbol: String {
            switch self {
            case .code: "chevron.left.forwardslash.chevron.right"
            case .preview: "point.3.connected.trianglepath.dotted"
            case .split: "rectangle.split.1x2"
            }
        }
    }

    /// The languages the menu offers, by what they are called and what is written.
    static let languages: [(title: String, value: String)] = [
        ("Plain text", ""), ("Mermaid", "mermaid"), ("Bash", "bash"), ("C", "c"), ("C++", "cpp"), ("C#", "csharp"),
        ("CSS", "css"), ("Diff", "diff"), ("Go", "go"), ("GraphQL", "graphql"), ("HTML", "html"), ("Java", "java"),
        ("JavaScript", "javascript"), ("JSON", "json"), ("Kotlin", "kotlin"), ("Markdown", "markdown"), ("PHP", "php"),
        ("Python", "python"), ("Ruby", "ruby"), ("Rust", "rust"), ("Shell", "shell"), ("SQL", "sql"), ("Swift", "swift"),
        ("TypeScript", "typescript"), ("XML", "xml"), ("YAML", "yaml"),
    ]

    /// A diagram whether its language is spelt `mermaid` or very nearly (`marmeid`,
    /// `mermiad`): a slip of the keys should not leave a chart as raw text.
    static func isMermaid(_ language: String) -> Bool {
        let language = language.lowercased().trimmingCharacters(in: .whitespaces)
        guard language.count >= 5 else { return false }
        return language == "mermaid" || editDistance(language, "mermaid") <= 2
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }

    private var isMermaid: Bool { Self.isMermaid(language) }

    private var languageTitle: String {
        if isMermaid { return "Mermaid" }
        return Self.languages.first { $0.value == language.lowercased() }?.title ?? (language.isEmpty ? "Plain text" : language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isMermaid, mode != .code {
                MermaidView(code: code, controller: diagram, onZoom: zoom)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.bottom, mode == .split ? 4 : 12)
            }
            if !isMermaid || mode != .preview {
                codeArea
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
        .background(Self.ground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
    }

    /// Notion's code ground: a warm off-white, or a lifted grey in the dark.
    static let ground = NotionStyle.dynamic(light: NotionStyle.rgb(247, 246, 243), dark: NotionStyle.rgb(37, 37, 37))

    @ViewBuilder
    private var codeArea: some View {
        if wraps {
            CodeTextRepresentable(id: id, code: code, model: model, wraps: true)
        } else {
            ScrollView(.horizontal) {
                CodeTextRepresentable(id: id, code: code, model: model, wraps: false)
            }
            .thinScrollers()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(language.isEmpty ? "plain text" : language)
                .font(.system(size: 13))
                .foregroundStyle(NotionStyle.secondary)
            Spacer()
            toolbar
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    /// The floating toolbar: a white pill of controls, divided after the language.
    private var toolbar: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Self.languages, id: \.value) { entry in
                    Button {
                        model.update(id, .code(language: entry.value, code: code))
                    } label: {
                        if entry.title == languageTitle { Label(entry.title, systemImage: "checkmark") } else { Text(entry.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(languageTitle).font(.system(size: 12))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(NotionStyle.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Language")

            Rectangle().fill(NotionStyle.divider).frame(width: 1, height: 16).padding(.horizontal, 2)

            if isMermaid {
                Menu {
                    ForEach(DiagramMode.allCases, id: \.self) { option in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { mode = option }
                        } label: {
                            Label(option.rawValue, systemImage: option == mode ? "checkmark" : option.symbol)
                        }
                    }
                } label: {
                    toolIcon("rectangle.split.1x2", active: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show the code, the diagram, or both")
                tool("plus.magnifyingglass", help: "Zoom — view the diagram full size") { zoom() }
                    .disabled(mode == .code)
                tool("arrow.down.to.line", help: "Download the diagram (SVG or PNG)") { download() }
                    .disabled(mode == .code)
            }
            tool("doc.on.doc", help: "Copy code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2))
            }
            tool("arrow.turn.down.left", help: wraps ? "Don't wrap lines" : "Wrap lines", active: wraps) { wraps.toggle() }
            Menu {
                Button { model.duplicate(id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.markdown(of: id), forType: .string)
                } label: { Label("Copy as Markdown", systemImage: "doc.on.clipboard") }
                Divider()
                Button(role: .destructive) { model.delete(id) } label: { Label("Delete", systemImage: "trash") }
            } label: {
                toolIcon("ellipsis", active: false)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(3)
        .background(NotionStyle.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NotionStyle.divider))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    private func toolIcon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(NotionStyle.secondary)
            .frame(width: 26, height: 26)
            .background(active ? NotionStyle.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }

    private func tool(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolIcon(symbol, active: active) }
            .buttonStyle(NotionHoverStyle())
            .help(help)
            .accessibilityLabel(help)
    }

    /// The diagram, drawn large, in the image viewer over the window.
    private func zoom() {
        diagram.snapshot(scale: 3) { image in
            guard let image, let png = image.pngData else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cue-diagram-\(id.uuidString).png")
            guard (try? png.write(to: url, options: .atomic)) != nil else { return }
            model.services.openImage(url)
        }
    }

    /// Saves the diagram: SVG (as drawn, to scale) or PNG, by the name given.
    private func download() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg, .png]
        panel.nameFieldStringValue = "diagram.svg"
        panel.isExtensionHidden = false
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                if url.pathExtension.lowercased() == "png" {
                    diagram.snapshot(scale: 3) { image in
                        if let png = image?.pngData { try? png.write(to: url, options: .atomic) }
                    }
                } else {
                    diagram.svg { svg in
                        if let svg { try? svg.write(to: url, atomically: true, encoding: .utf8) }
                    }
                }
            }
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
    }
}

/// Reaches the diagram's web view: a picture of it, or the SVG it drew.
@MainActor
final class MermaidController {
    weak var webView: WKWebView?

    /// The drawing at `scale` times its size on screen.
    func snapshot(scale: CGFloat, _ done: @escaping @MainActor (NSImage?) -> Void) {
        guard let webView else { return done(nil) }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width * scale))
        webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated { done(image) }
        }
    }

    func svg(_ done: @escaping @MainActor (String?) -> Void) {
        guard let webView else { return done(nil) }
        webView.evaluateJavaScript("(document.querySelector('svg') || {}).outerHTML || null") { result, _ in
            let svg = result as? String
            MainActor.assumeIsolated { done(svg) }
        }
    }
}

/// The code itself: plain monospaced text that grows with its lines; ⇥ indents.
final class CodeTextView: NSTextView {
    var blockID = UUID()
    weak var model: BlockEditorModel?
    var lastCode = ""

    /// Lines wrap at the block's width, or run on (the block then scrolls sideways).
    var wraps = true {
        didSet {
            guard wraps != oldValue, let textContainer else { return }
            textContainer.widthTracksTextView = wraps
            textContainer.containerSize = NSSize(width: wraps ? bounds.width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            isHorizontallyResizable = !wraps
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = max(used.height, 18)
        return NSSize(width: wraps ? NSView.noIntrinsicMetric : ceil(used.width) + 8, height: ceil(height) + textContainerInset.height * 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        guard string != lastCode, let model, let index = model.index(of: blockID), case .code(let language, _) = model.blocks[index].kind else { return }
        lastCode = string
        model.update(blockID, .code(language: language, code: string))
    }

    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }

    override func cancelOperation(_ sender: Any?) { window?.makeFirstResponder(nil) }

    /// ↑ on the first line or ↓ on the last leaves the code, as in any other block.
    override func moveUp(_ sender: Any?) {
        let before = (string as NSString).substring(to: selectedRange().location)
        if !before.contains("\n"), model?.arrow(from: blockID, up: true) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        let after = (string as NSString).substring(from: NSMaxRange(selectedRange()))
        if !after.contains("\n"), model?.arrow(from: blockID, up: false) == true { return }
        super.moveDown(sender)
    }
}

struct CodeTextRepresentable: NSViewRepresentable {
    let id: UUID
    let code: String
    let model: BlockEditorModel
    var wraps = true

    func makeNSView(context: Context) -> CodeTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = CodeTextView(frame: .zero, textContainer: container)
        view.blockID = id
        view.model = model
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.string = code
        view.lastCode = code
        view.wraps = wraps
        model.register(view, for: id)
        return view
    }

    func updateNSView(_ view: CodeTextView, context: Context) {
        view.model = model
        view.wraps = wraps
        if code != view.lastCode {
            view.string = code
            view.lastCode = code
            view.invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - Mermaid

/// A Mermaid diagram, drawn by mermaid.js in a web view as tall as the drawing, in
/// the page's light or dark. Redrawn a moment after the code stops changing.
struct MermaidView: View {
    let code: String
    var controller: MermaidController?
    /// A click on the drawing: it opens full size. Hovering shows the zoom-in cursor.
    var onZoom: (() -> Void)?
    @State private var height: CGFloat = 120
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MermaidWebView(code: code, dark: colorScheme == .dark, zoomable: onZoom != nil, height: $height, controller: controller, onZoom: onZoom)
            .frame(height: height)
            .help(onZoom == nil ? "" : "Click to view full size")
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let code: String
    let dark: Bool
    var zoomable = false
    @Binding var height: CGFloat
    var controller: MermaidController?
    var onZoom: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassThroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "size")
        configuration.userContentController.add(context.coordinator, name: "zoom")
        context.coordinator.onZoom = onZoom
        context.coordinator.zoomable = zoomable
        let view = PassThroughWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        controller?.webView = view
        context.coordinator.render(code: code, dark: dark, in: view)
        return view
    }

    func updateNSView(_ view: PassThroughWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.onZoom = onZoom
        context.coordinator.zoomable = zoomable
        context.coordinator.render(code: code, dark: dark, in: view)
    }

    static func dismantleNSView(_ view: PassThroughWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "zoom")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var onZoom: (() -> Void)?
        var zoomable = false
        private var rendered: (code: String, dark: Bool)?
        private var pending: DispatchWorkItem?

        init(height: Binding<CGFloat>) { self.height = height }

        func render(code: String, dark: Bool, in view: WKWebView) {
            guard rendered?.code != code || rendered?.dark != dark else { return }
            let first = rendered == nil
            rendered = (code, dark)
            pending?.cancel()
            let zoomable = zoomable
            let work = DispatchWorkItem { [weak view] in view?.loadHTMLString(Self.page(code: code, dark: dark, zoomable: zoomable), baseURL: nil) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.5), execute: work)
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                if message.name == "zoom" { onZoom?(); return }
                guard let value = message.body as? Double else { return }
                height.wrappedValue = max(CGFloat(value), 40)
            }
        }

        static func page(code: String, dark: Bool, zoomable: Bool = false) -> String {
            let escaped = code
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let ink = dark ? "rgba(255,255,255,0.6)" : "rgba(55,53,47,0.6)"
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <style>
              html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
              \(zoomable ? "svg { cursor: zoom-in; }" : "")
              body { display: flex; justify-content: center; font: 13px -apple-system, sans-serif; color: \(ink); }
              .mermaid { margin: 0; }
              .note { padding: 12px; white-space: pre-wrap; font: 12px ui-monospace, monospace; }
            </style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
            </head><body>
            <pre class="mermaid">\(escaped)</pre>
            <script>
              const report = () => window.webkit.messageHandlers.size.postMessage(document.body.scrollHeight + 8);
              \(zoomable ? "document.addEventListener('click', e => { if (e.target.closest('svg')) window.webkit.messageHandlers.zoom.postMessage(1); });" : "")
              const fail = (text) => { document.body.innerHTML = '<div class="note"></div>'; document.querySelector('.note').textContent = text; report(); };
              if (typeof mermaid === 'undefined') {
                fail('The diagram needs the internet to be drawn the first time.\\n\\n' + \(Self.jsString(code)));
              } else {
                mermaid.initialize({ startOnLoad: false, theme: '\(dark ? "dark" : "neutral")', securityLevel: 'strict', fontFamily: '-apple-system, sans-serif' });
                mermaid.run().then(report).catch(e => fail((e && e.message) || String(e)));
              }
            </script></body></html>
            """
        }

        private static func jsString(_ text: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
            let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(array.dropFirst().dropLast())
        }
    }
}

/// A web view that lets the page scroll past it: the wheel goes on to the page.
final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
