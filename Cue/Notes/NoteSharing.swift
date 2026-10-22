import AppKit
import os

/// Where a note can be sent besides its own folder: Obsidian (through its URL
/// scheme), Apple Notes (through Apple events) and Notion (its API). Each is set up
/// in Settings › Notes.
nonisolated enum NoteDestination: String, CaseIterable, Identifiable {
    case obsidian, appleNotes, notion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .obsidian: "Obsidian"
        case .appleNotes: "Apple Notes"
        case .notion: "Notion"
        }
    }

    var symbol: String {
        switch self {
        case .obsidian: "diamond"
        case .appleNotes: "note.text"
        case .notion: "n.square"
        }
    }
}

nonisolated enum NoteSharingError: LocalizedError {
    case notSetUp(NoteDestination)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notSetUp(let destination): "\(destination.title) is not set up — see Settings › Notes"
        case .failed(let message): message
        }
    }
}

/// Sends notes out. Obsidian and Apple Notes are quick; Notion goes over the network.
@MainActor
enum NoteSharing {
    static func send(_ note: Note, to destination: NoteDestination, preferences: AppPreferences) async throws {
        switch destination {
        case .obsidian: try toObsidian(note, vault: preferences.notesObsidianVault)
        case .appleNotes: try toAppleNotes(note, folder: preferences.notesAppleNotesFolder)
        case .notion: try await toNotion(note, token: preferences.notesNotionToken, parent: preferences.notesNotionParent)
        }
    }

    /// Whether a destination has what it needs to be sent to.
    static func isSetUp(_ destination: NoteDestination, preferences: AppPreferences) -> Bool {
        switch destination {
        case .obsidian, .appleNotes: true
        case .notion: !preferences.notesNotionToken.trimmingCharacters(in: .whitespaces).isEmpty && !notionID(preferences.notesNotionParent).isEmpty
        }
    }

    /// The destinations a new note goes to on its own: chosen in Settings and set up.
    static func connected(_ preferences: AppPreferences) -> [NoteDestination] {
        NoteDestination.allCases.filter { preferences.notesSendTo.contains($0.rawValue) && isSetUp($0, preferences: preferences) }
    }

    /// Every destination that is set up, whether or not it is a default.
    static func available(_ preferences: AppPreferences) -> [NoteDestination] {
        NoteDestination.allCases.filter { isSetUp($0, preferences: preferences) }
    }

    /// A note just saved: sent to the destinations chosen for it (the form's
    /// "Save as", defaulting to Settings), each reported on the HUD.
    static func send(_ note: Note, to rawValues: [String], preferences: AppPreferences) {
        for destination in NoteDestination.allCases where rawValues.contains(destination.rawValue) && isSetUp(destination, preferences: preferences) {
            sendWithFeedback(note, to: destination, preferences: preferences)
        }
    }

    /// A note saved without the form (the URL scheme): the defaults.
    static func sendToConnected(_ note: Note, preferences: AppPreferences) {
        send(note, to: connected(preferences).map(\.rawValue), preferences: preferences)
    }

    /// Sends, and says how it went on the HUD.
    static func sendWithFeedback(_ note: Note, to destination: NoteDestination, preferences: AppPreferences) {
        Task { @MainActor in
            do {
                try await send(note, to: destination, preferences: preferences)
                FeedbackHUD.show("Sent to \(destination.title)", symbol: "paperplane.fill", duration: .seconds(1.4), subtitle: note.title)
            } catch {
                FeedbackHUD.show("Not sent to \(destination.title)", symbol: "exclamationmark.triangle.fill", duration: .seconds(3), subtitle: error.localizedDescription)
            }
        }
    }

    // MARK: Obsidian

    /// `obsidian://new` makes the note in the vault (the last one opened, unless a
    /// vault is named) with the text as its content.
    static func toObsidian(_ note: Note, vault: String) throws {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "new"
        var items = [URLQueryItem(name: "file", value: note.id), URLQueryItem(name: "content", value: note.text)]
        let vault = vault.trimmingCharacters(in: .whitespaces)
        if !vault.isEmpty { items.insert(URLQueryItem(name: "vault", value: vault), at: 0) }
        components.queryItems = items
        guard let url = components.url else { throw NoteSharingError.failed("Could not build the Obsidian link") }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            throw NoteSharingError.failed("Obsidian is not installed")
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Apple Notes

    /// Makes the note in Apple Notes (in `folder` of the default account, made when
    /// missing) with the Markdown rendered as the HTML Notes takes. macOS asks once
    /// for permission to control Notes.
    static func toAppleNotes(_ note: Note, folder: String) throws {
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: appleNotesScript(note, folder: folder)) else { throw NoteSharingError.failed("Could not build the Notes script") }
        apple.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Notes did not take the note"
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            Log.app.error("Apple Notes: \(message, privacy: .public) (\(number))")
            throw NoteSharingError.failed(number == -1743 ? "Allow Cue to control Notes in System Settings › Privacy & Security › Automation" : message)
        }
    }

    /// The script that makes the note; compiled on its own by the diagnostics.
    static func appleNotesScript(_ note: Note, folder: String) -> String {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        let body = NoteMarkdown.html(note.text, title: note.title)
        return """
        tell application "Notes"
            set theBody to \(appleScriptString(body))
            \(folder.isEmpty ? "" : """
            set folderName to \(appleScriptString(folder))
            tell default account
                if not (exists folder folderName) then make new folder with properties {name:folderName}
                make new note at folder folderName with properties {body:theBody}
            end tell
            """)
            \(folder.isEmpty ? "make new note at default account with properties {body:theBody}" : "")
        end tell
        """
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Notion

    /// Makes a page under the parent page (or in the database) with the note's
    /// title and its blocks. The title property is addressed by its id, `title`,
    /// which every page and database has.
    static func toNotion(_ note: Note, token: String, parent: String) async throws {
        let token = token.trimmingCharacters(in: .whitespaces)
        let parent = notionID(parent)
        guard !token.isEmpty, !parent.isEmpty else { throw NoteSharingError.notSetUp(.notion) }
        let kind = try await notionParentKind(parent, token: token)
        var body: [String: Any] = [
            "parent": [kind: parent],
            "properties": ["title": ["title": [["text": ["content": String(note.title.prefix(2000))]]]]],
            "children": Array(NoteMarkdown.notionBlocks(note.text).prefix(100)),
        ]
        if kind == "page_id" { body["icon"] = ["type": "emoji", "emoji": "📝"] }
        _ = try await notion("POST", "pages", token: token, body: body)
    }

    /// Whether the id is a page's or a database's — the parent key differs.
    private static func notionParentKind(_ id: String, token: String) async throws -> String {
        if (try? await notion("GET", "databases/\(id)", token: token, body: nil)) != nil { return "database_id" }
        return "page_id"
    }

    /// Checks the token by asking who it is; returns the integration's name.
    static func notionCheck(token: String) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { throw NoteSharingError.notSetUp(.notion) }
        let answer = try await notion("GET", "users/me", token: token, body: nil)
        return answer["name"] as? String ?? "Notion"
    }

    /// A Notion id from what was pasted: a bare id, a dashed one, or a page URL
    /// (`…/Page-Title-<32 hex>`).
    static func notionID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.replacingOccurrences(of: "-", with: "")
        if hex.count == 32, hex.allSatisfy(\.isHexDigit) { return hex }
        let tail = trimmed.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).map(String.init)
        for part in tail.reversed() {
            let candidate = String(part.suffix(32))
            if candidate.count == 32, candidate.allSatisfy(\.isHexDigit) { return candidate }
        }
        return trimmed
    }

    private static func notion(_ method: String, _ path: String, token: String, body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = json["message"] as? String ?? "Notion answered \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            Log.app.error("Notion \(path, privacy: .public): \(message, privacy: .public)")
            throw NoteSharingError.failed(message)
        }
        return json
    }
}

/// A note's Markdown as what the destinations take: HTML for Apple Notes, blocks
/// for Notion. Inline marks are kept where the destination understands them.
nonisolated enum NoteMarkdown {
    // MARK: HTML

    static func html(_ markdown: String, title: String) -> String {
        var out = "<div>"
        var first = true
        for block in MarkdownBlock.parse(markdown) {
            switch block {
            case .heading(let level, let text):
                // Notes takes the first line as the note's name: the title stays a heading.
                out += "<h\(first ? 1 : level)>\(inline(text))</h\(first ? 1 : level)>"
            case .paragraph(let text):
                out += first ? "<h1>\(inline(text))</h1>" : "<p>\(inline(text))</p>"
            case .bullets(let items):
                out += "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
            case .numbered(let items):
                out += "<ol>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
            case .checklist(let items):
                out += "<ul>" + items.map { "<li>\($0.done ? "☑" : "☐") \(inline($0.text))</li>" }.joined() + "</ul>"
            case .quote(let text):
                out += "<blockquote>\(inline(text))</blockquote>"
            case .code(let text):
                out += "<pre>\(escape(text))</pre>"
            case .image(let alt, _):
                out += "<p><i>\(escape(alt.isEmpty ? "Image" : alt))</i></p>"
            case .attachment(let name, _):
                out += "<p><i>\(escape(name))</i></p>"
            case .table(let header, let rows):
                out += "<table><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                    + rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
            }
            first = false
        }
        if first { out += "<h1>\(escape(title))</h1>" }
        return out + "</div>"
    }

    /// `**bold**`, `*italic*`, `` `code` `` and links as tags; the rest escaped.
    static func inline(_ text: String) -> String {
        var html = escape(text)
        html = html.replacing(#/\[([^\]]+)\]\(([^)\s]+)\)/#) { match in "<a href=\"\(match.2)\">\(match.1)</a>" }
        html = html.replacing(#/`([^`]+)`/#) { match in "<code>\(match.1)</code>" }
        html = html.replacing(#/(\*\*|__)(.+?)\1/#) { match in "<b>\(match.2)</b>" }
        html = html.replacing(#/~~(.+?)~~/#) { match in "<s>\(match.1)</s>" }
        html = html.replacing(#/(^|[^\w*_])[*_]([^*_\s](?:.*?[^*_\s])?)[*_](?=$|[^\w*_])/#) { match in "\(match.1)<i>\(match.2)</i>" }
        return html
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Notion

    /// Blocks for the Notion API: headings, paragraphs, lists, to-dos, quotes and
    /// code; rich text with bold, italic, strikethrough, code and links.
    static func notionBlocks(_ markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var first = true
        for block in MarkdownBlock.parse(markdown) {
            defer { first = false }
            switch block {
            case .heading(let level, let text):
                // The title is the page's name; it is not repeated as a heading.
                if first { continue }
                blocks.append(notionBlock("heading_\(min(3, max(1, level)))", ["rich_text": richText(text)]))
            case .paragraph(let text):
                if first { continue }
                blocks.append(notionBlock("paragraph", ["rich_text": richText(text)]))
            case .bullets(let items):
                blocks += items.map { notionBlock("bulleted_list_item", ["rich_text": richText($0)]) }
            case .numbered(let items):
                blocks += items.map { notionBlock("numbered_list_item", ["rich_text": richText($0)]) }
            case .checklist(let items):
                blocks += items.map { notionBlock("to_do", ["rich_text": richText($0.text), "checked": $0.done]) }
            case .quote(let text):
                blocks.append(notionBlock("quote", ["rich_text": richText(text)]))
            case .code(let text):
                blocks.append(notionBlock("code", ["rich_text": [plainText(text)], "language": "plain text"]))
            case .image(let alt, _):
                blocks.append(notionBlock("paragraph", ["rich_text": [plainText(alt.isEmpty ? "Image" : alt, italic: true)]]))
            case .attachment(let name, _):
                blocks.append(notionBlock("paragraph", ["rich_text": [plainText(name, italic: true)]]))
            case .table(let header, let rows):
                // Notion's table block: a table_width and one table_row child per row, the header first.
                let width = max(header.count, rows.map(\.count).max() ?? 0)
                let cells: ([String]) -> [[[String: Any]]] = { row in (0..<width).map { richText($0 < row.count ? row[$0] : "") } }
                let children = ([header] + rows).map { notionBlock("table_row", ["cells": cells($0)]) }
                blocks.append(notionBlock("table", ["table_width": width, "has_column_header": true, "has_row_header": false, "children": children]))
            }
        }
        return blocks
    }

    private static func notionBlock(_ type: String, _ content: [String: Any]) -> [String: Any] {
        ["object": "block", "type": type, type: content]
    }

    private static func plainText(_ text: String, italic: Bool = false) -> [String: Any] {
        var run: [String: Any] = ["type": "text", "text": ["content": String(text.prefix(2000))]]
        if italic { run["annotations"] = ["italic": true] }
        return run
    }

    /// One run per inline mark: bold, italic, strikethrough, code, links.
    static func richText(_ text: String) -> [[String: Any]] {
        var runs: [[String: Any]] = []
        var rest = Substring(text)
        // Italics need a non-word character before the mark; it is kept as plain text.
        let pattern = #/(\*\*|__)(.+?)\1|~~(.+?)~~|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)|(^|[^\w*_])[*_]([^*_\s](?:.*?[^*_\s])?)[*_](?=$|[^\w*_])/#
        while let match = rest.firstMatch(of: pattern) {
            var before = String(rest[..<match.range.lowerBound])
            if let prefix = match.7 { before += prefix }
            if !before.isEmpty { runs.append(plainText(before)) }
            var run: [String: Any] = ["type": "text"]
            var annotations: [String: Any] = [:]
            if let bold = match.2 { run["text"] = ["content": String(bold)]; annotations["bold"] = true }
            else if let struck = match.3 { run["text"] = ["content": String(struck)]; annotations["strikethrough"] = true }
            else if let code = match.4 { run["text"] = ["content": String(code)]; annotations["code"] = true }
            else if let label = match.5, let link = match.6 { run["text"] = ["content": String(label), "link": ["url": String(link)]] }
            else if let italic = match.8 { run["text"] = ["content": String(italic)]; annotations["italic"] = true }
            if !annotations.isEmpty { run["annotations"] = annotations }
            runs.append(run)
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { runs.append(plainText(String(rest))) }
        return runs.isEmpty ? [plainText("")] : runs
    }
}
