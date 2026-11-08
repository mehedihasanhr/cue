import AppKit
import os

/// The cards picked with ⌘-click in the island panel, in the order they were picked
/// (by `IslandItem.id`, so a pick survives switching tabs). An object rather than
/// view state so the panel, its cards and — in a debug build — the `cue://debug`
/// URLs all work on one list.
@MainActor
@Observable
final class IslandPicks {
    var ids: [String] = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    /// Its place (from 1) among the picks, for the card's badge; nil when not picked.
    func index(of item: IslandItem) -> Int? {
        ids.firstIndex(of: item.id).map { $0 + 1 }
    }

    func toggle(_ item: IslandItem) {
        if let index = ids.firstIndex(of: item.id) {
            ids.remove(at: index)
        } else {
            ids.append(item.id)
        }
    }

    func clear() { ids = [] }

    #if DEBUG
    /// The picks of the panel on screen, and what it can be told to do with them —
    /// set by the panel, read by `cue://debug/pick`, `/picks` and `/copy-picks`.
    static weak var current: IslandPicks?
    /// Picks the cards at these places (from 0) in the list the open tab shows.
    static var debugPick: (([Int]) -> Void)?
    /// Copies the picks, as the bar's button does.
    static var debugCopy: (() -> Void)?
    /// What is picked and what a copy would carry, for a test to read.
    static var debugReport: (() -> String)?
    #endif
}

/// Copying several picked cards at once. Whatever is a file on disk goes on the
/// pasteboard as a file, so a paste lands as attachments; the rest joins as lines of
/// text, which rides along beside the files for the apps that take only text.
@MainActor
enum PickedCopy {
    /// Everything a pick can resolve to, and how a color should be written.
    struct Sources {
        let library: CaptureLibrary
        let clipboard: ClipboardHistory
        let assets: AssetStore
        let colors: ColorStore
        let snippets: SnippetStore
        let notes: NoteStore
        let colorFormat: ColorFormat
    }

    struct Report {
        var files: [URL] = []
        var lines: [String] = []
        /// The text put on the pasteboard beside the files.
        var text: String {
            (lines + (files.isEmpty ? [] : files.map(\.path))).joined(separator: "\n")
        }
        var isEmpty: Bool { files.isEmpty && lines.isEmpty }
    }

    /// Everything on hand, whatever tab or filter is open, so a pick made on one tab
    /// still resolves from another.
    static func everything(_ sources: Sources) -> [IslandItem] {
        IslandSearch.everything(library: sources.library, clipboard: sources.clipboard, assets: sources.assets,
                                colors: sources.colors, snippets: sources.snippets, notes: sources.notes)
    }

    /// The picks that still exist, in the order they were picked.
    static func items(for ids: [String], _ sources: Sources) -> [IslandItem] {
        let byID = Dictionary(everything(sources).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// What the items would put on the pasteboard, without putting it there.
    static func report(for items: [IslandItem], _ sources: Sources) -> Report {
        var report = Report()
        for item in items {
            switch item {
            case .capture(let capture):
                if let url = sources.library.fileURL(for: capture) { report.files.append(url) } else { report.lines.append(capture.title) }
            case .asset(let asset):
                report.files.append(sources.assets.fileURL(for: asset))
            case .clipboard(let entry):
                switch entry.kind {
                case .files:
                    report.files += entry.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                case .image:
                    if let data = sources.clipboard.imageData(for: entry), let url = temporaryFile(for: entry, data: data) {
                        report.files.append(url)
                    }
                case .text, .link, .color:
                    report.lines.append(entry.text)
                }
            case .color(let entry):
                report.lines.append(sources.colorFormat.string(for: entry.color))
            case .note(let note):
                report.lines.append(note.text)
            case .snippet(let snippet):
                report.lines.append(SnippetTemplate.expand(snippet.text, values: [:], clipboard: NSPasteboard.general.string(forType: .string)))
            case .task(let task):
                report.lines.append(task.text)
            case .answer(let answer):
                report.lines.append(answer.value)
            }
        }
        return report
    }

    /// Puts the items on the pasteboard; returns what went on it, or nil when there
    /// was nothing to copy.
    @discardableResult
    static func copy(_ items: [IslandItem], _ sources: Sources) -> Report? {
        guard !items.isEmpty else { return nil }
        let report = report(for: items, sources)
        guard !report.isEmpty else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !report.files.isEmpty { pasteboard.writeObjects(report.files as [NSURL]) }
        if !report.text.isEmpty { pasteboard.setString(report.text, forType: .string) }
        // A snippet counts as used once it is copied, as copying one card does.
        for item in items {
            if case .snippet(let snippet) = item { sources.snippets.recordUse(snippet) }
        }
        Log.app.info("Copied \(items.count, privacy: .public) picked item(s): \(report.files.count, privacy: .public) file(s)")
        FeedbackHUD.show("\(items.count) copied", symbol: "checkmark.circle.fill", duration: .seconds(1.4),
                         subtitle: report.files.isEmpty ? nil : (report.files.count == 1 ? "1 file" : "\(report.files.count) files"))
        return report
    }

    /// A picked clipboard image on disk, so it can be copied as a file like the rest.
    private static func temporaryFile(for item: ClipboardItem, data: Data) -> URL? {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cue-copies", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(item.id.uuidString).png")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.app.error("Picked clipboard image could not be written: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
