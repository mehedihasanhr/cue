import AppKit

/// `klik://` URLs, so Raycast, Alfred, Shortcuts, scripts and the `klik` command
/// line tool can drive Klik:
///
///     klik://capture/area | full | scrolling | text
///     klik://color/pick
///     klik://task/new?title=…&notes=…&priority=urgent|high|medium|low&project=…
///     klik://snippet/add?keyword=;sig&text=…&name=…
///     klik://clipboard/copy?text=…
///     klik://palette · klik://clipboard · klik://panel · klik://clock · klik://settings
enum URLCommand: Equatable {
    case captureArea, captureWindow, captureFullScreen, captureScrolling, captureText, pickColor
    case newTask(title: String?, notes: String, priority: TaskPriority, project: String?)
    case addSnippet(keyword: String, name: String, text: String)
    /// A note from `text` (nil: the quick note form).
    case newNote(text: String?)
    case copy(String)
    case palette, clipboard, panel, clock, settings

    /// nil for a URL Klik does not understand.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "klik" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).map { $0.lowercased() }
        switch path {
        case ["capture", "area"], ["capture"]: self = .captureArea
        case ["capture", "window"]: self = .captureWindow
        case ["capture", "full"], ["capture", "screen"], ["capture", "fullscreen"]: self = .captureFullScreen
        case ["capture", "scrolling"], ["capture", "scroll"]: self = .captureScrolling
        case ["capture", "text"], ["ocr"]: self = .captureText
        case ["color", "pick"], ["color"], ["pick"]: self = .pickColor
        case ["task", "new"], ["task"], ["task", "add"]:
            self = .newTask(title: query["title"].flatMap { $0.isEmpty ? nil : $0 }, notes: query["notes"] ?? "",
                            priority: query["priority"].flatMap { TaskPriority(rawValue: $0.lowercased()) } ?? .medium,
                            project: query["project"].flatMap { $0.isEmpty ? nil : $0 })
        case ["snippet", "add"], ["snippet", "new"], ["snippet"]:
            guard let keyword = query["keyword"], !keyword.isEmpty, let text = query["text"], !text.isEmpty else { return nil }
            self = .addSnippet(keyword: keyword, name: query["name"] ?? "", text: text)
        case ["note", "new"], ["note"], ["note", "add"]:
            self = .newNote(text: query["text"].flatMap { $0.isEmpty ? nil : $0 })
        case ["clipboard", "copy"], ["copy"]:
            guard let text = query["text"] else { return nil }
            self = .copy(text)
        case ["palette"], ["commands"]: self = .palette
        case ["clipboard"], ["clipboard", "list"]: self = .clipboard
        case ["panel"], ["library"]: self = .panel
        case ["clock"], ["prayer"]: self = .clock
        case ["settings"], ["preferences"]: self = .settings
        default: return nil
        }
    }
}
