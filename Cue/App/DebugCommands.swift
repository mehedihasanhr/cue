#if DEBUG
import AppKit
import os
import WebKit

/// `cue://debug/…` — drives the task dashboard and its editor from a script, so their
/// behaviour can be checked on screen without a person at the keyboard. Debug builds
/// only; a release build has none of it.
///
///     cue://debug/open?index=0&page=1       a task in the dashboard (as a page, or the peek)
///     cue://debug/delete?title=Test          a task a test made, by its exact title
///     cue://debug/focus?block=2&at=end      the caret into a block
///     cue://debug/type?text=Hello           typed into whatever has the caret, key by key
///     cue://debug/key?name=return           return, up, down, left, right, backspace, esc, tab
///     cue://debug/hover?block=1             a block's margin handles shown
///     cue://debug/menu?block=1              a block's actions menu opened
///     cue://debug/size?width=1400&height=1000   the key window resized
///     cue://debug/markdown                  the editor's Markdown written to ~/Pictures/Cue Debug/markdown.md
///     cue://debug/snapshot?name=a           the Tasks window drawn to ~/Pictures/Cue Debug/a.png
@MainActor
enum DebugCommands {
    static func handles(_ url: URL) -> Bool { url.scheme == "cue" && url.host == "debug" }

    static func run(_ url: URL, tasks: TaskStore, createTask: (TaskSeed) -> Void = { _ in }, openTask: (TaskItem, Bool) -> Void) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let model = BlockEditorModel.current
        func block(_ key: String = "block") -> DocBlock? {
            guard let model, let index = Int(query[key] ?? ""), model.blocks.indices.contains(index) else { return nil }
            return model.blocks[index]
        }
        // The Tasks window whether or not it is key (a sleeping display has no key window).
        // `window=panel`: the floating task form instead.
        let window = query["window"] == "panel"
            ? NSApp.windows.first { $0 is QuickTaskPanel && $0.isVisible }
            : NSApp.windows.first { $0.title == "Cue Tasks" && $0.isVisible } ?? NSApp.keyWindow
        let responder = window?.firstResponder

        switch url.path {
        case "/open":
            let index = Int(query["index"] ?? "0") ?? 0
            guard tasks.tasks.indices.contains(index) else { return }
            let start = Date()
            openTask(tasks.tasks[index], query["page"] == "1")
            // How long the main thread is held: the next turns of the run loop after the
            // open (layout and drawing included), written for a script to read.
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000).write(to: folder.appendingPathComponent("open-time.txt"), atomically: true, encoding: .utf8)
                }
            }
        case "/stall":
            // The longest the main thread goes without a turn over the next 1.5 s: what a
            // person would see as a hitch. Written to ~/Pictures/Cue Debug/stall.txt.
            var last = Date(), worst: TimeInterval = 0
            let end = Date().addingTimeInterval(1.5)
            Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { timer in
                let now = Date()
                worst = max(worst, now.timeIntervalSince(last))
                last = now
                guard now > end else { return }
                timer.invalidate()
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
                try? String(format: "%.0f ms", worst * 1000).write(to: folder.appendingPathComponent("stall.txt"), atomically: true, encoding: .utf8)
            }
        case "/delete":
            // A task made by a test, by its exact title.
            guard let title = query["title"] else { return }
            for task in tasks.tasks where task.title == title { tasks.delete(task) }
        case "/focus":
            guard let model, let block = block() else { return }
            model.focus(block.id, query["at"] == "start" ? .start : .end)
        case "/type":
            guard let view = responder as? NSTextView else { return }
            for character in query["text"] ?? "" {
                view.insertText(String(character), replacementRange: view.selectedRange())
            }
        case "/key":
            guard let view = responder as? NSResponder else { return }
            let selector: Selector? = switch query["name"] {
            case "return": #selector(NSResponder.insertNewline(_:))
            case "up": #selector(NSResponder.moveUp(_:))
            case "down": #selector(NSResponder.moveDown(_:))
            case "left": #selector(NSResponder.moveLeft(_:))
            case "right": #selector(NSResponder.moveRight(_:))
            case "backspace": #selector(NSResponder.deleteBackward(_:))
            case "esc": #selector(NSResponder.cancelOperation(_:))
            case "tab": #selector(NSResponder.insertTab(_:))
            default: nil
            }
            if let selector { view.doCommand(by: selector) }
        case "/drag-preview":
            let index = Int(query["index"] ?? "0") ?? 0
            guard tasks.tasks.indices.contains(index),
                  let image = debugDragPreview(store: tasks, task: tasks.tasks[index], look: query["look"] == "row" ? .row : .card),
                  let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: folder.appendingPathComponent("\(query["name"] ?? "drag").png"))
        case "/table":
            // How the next table drawn opens: hovered at a cell, a menu open, a cell edited.
            func cell(_ key: String) -> TableBlockView.Cell? {
                let parts = (query[key] ?? "").split(separator: ",").compactMap { Int($0) }
                return parts.count == 2 ? TableBlockView.Cell(row: parts[0], column: parts[1]) : nil
            }
            let menu: TableBlockView.OpenMenu? = switch query["menu"] {
            case "row": cell("hover").map { .row($0.row) }
            case "column": cell("hover").map { .column($0.column) }
            case "cell": cell("edit").map { .cell($0) }
            default: nil
            }
            TableBlockView.debugState = query.isEmpty ? nil : (cell("hover"), menu, cell("edit"))
        case "/keyevent":
            // A key press as the keyboard makes it, through the app's own routing
            // (key window, then the main menu): `chars=v&cmd=1` is ⌘V.
            guard let window, let characters = query["chars"] else { return }
            let flags: NSEvent.ModifierFlags = query["cmd"] == "1" ? .command : []
            let codes: [String: UInt16] = ["v": 9, "c": 8, "x": 7, "a": 0, "z": 6]
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: codes[characters] ?? 0) else { continue }
                NSApp.sendEvent(event)
            }
        case "/seed-task":
            // What "Create Task" in the editor (or "Create as Task…" on a card) does, with a test picture.
            let image = NSImage(size: NSSize(width: 360, height: 180), flipped: false) { rect in
                NSColor.systemIndigo.setFill(); rect.fill()
                NSString("EDITED CAPTURE").draw(at: NSPoint(x: 70, y: 80), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.white])
                return true
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = ImageEncoding.png(cg) else { return }
            createTask(.image(png))
        case "/clipboard-text":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(query["text"] ?? "", forType: .string)
        case "/clipboard-image":
            // A capture's way onto the clipboard: a promised PNG of a test picture.
            let image = NSImage(size: NSSize(width: 240, height: 120), flipped: false) { rect in
                NSColor.systemTeal.setFill(); rect.fill()
                NSString("TEST CAPTURE").draw(at: NSPoint(x: 40, y: 50), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white])
                return true
            }
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { Clipboard.copy(cg) }
        case "/panel-text":
            // What the floating task form holds, written out.
            func editors(in view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? [] + view.subviews.flatMap(editors) }
            guard let content = window?.contentView else { return }
            let text = editors(in: content).map { ($0 as? RichTextView)?.markdown ?? $0.string }.joined(separator: "\n---\n")
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? text.write(to: folder.appendingPathComponent("panel-text.txt"), atomically: true, encoding: .utf8)
        case "/icon-catalog":
            // What the icon picker has to offer, read inside the sandbox as the picker reads it.
            IconCatalog.shared.load()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let catalog = IconCatalog.shared
                let report = """
                loaded: \(catalog.loaded)
                symbols: \(catalog.symbols.count)
                emoji: \(catalog.emoji.count)
                search "calendar": \(catalog.symbols.filter { $0.contains("calendar") }.prefix(6).joined(separator: ", "))
                search emoji "rocket": \(catalog.emoji.filter { $0.name.contains("rocket") }.map(\.character).joined())
                search emoji "heart": \(catalog.emoji.filter { $0.name.contains("heart") }.prefix(12).map(\.character).joined())
                """
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? report.write(to: folder.appendingPathComponent("icons.txt"), atomically: true, encoding: .utf8)
            }
        case "/hover":
            model?.hoveredID = block()?.id
        case "/menu":
            model?.menuID = block()?.id
        case "/size":
            guard let window, let width = Double(query["width"] ?? ""), let height = Double(query["height"] ?? "") else { return }
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size = CGSize(width: width, height: height)
            window.setFrame(frame, display: true)
        case "/scroll":
            // The tallest scroll view in the window (the page), scrolled to `y`.
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
            }
            guard let content = window?.contentView, let y = Double(query["y"] ?? "") else { return }
            let page = scrollViews(in: content).filter { ($0.documentView?.frame.height ?? 0) > $0.frame.height }
                .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
            page?.contentView.scroll(to: NSPoint(x: 0, y: y))
            page.map { $0.reflectScrolledClipView($0.contentView) }
        case "/snapshot":
            // The window drawn into a picture by Cue itself: works with the display asleep.
            guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(query["name"] ?? "snapshot").png"))
        case "/snapshot-web":
            // A web view's own drawing (the window snapshot leaves web content blank).
            func webViews(in view: NSView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? [] + view.subviews.flatMap(webViews)
            }
            guard let content = window?.contentView, let web = webViews(in: content).first else { return }
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
            let name = query["name"] ?? "web"
            web.takeSnapshot(with: nil) { image, _ in
                guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: folder.appendingPathComponent("\(name).png"))
            }
        case "/markdown":
            guard let model else { return }
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cue Debug", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? model.markdown.write(to: folder.appendingPathComponent("markdown.md"), atomically: true, encoding: .utf8)
        default:
            Log.app.notice("Unknown debug command: \(url.absoluteString, privacy: .public)")
        }
    }
}
#endif
