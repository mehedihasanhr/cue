import AppKit
import SwiftUI

/// A note on the island: its title and the start of its text. A click opens it
/// to edit; the menu copies, sends it on, shows the file or deletes it.
struct NoteCard: View {
    let note: Note
    let store: NoteStore
    var clipboard: ClipboardHistory? = nil
    var onEdit: () -> Void = {}
    @Environment(AppPreferences.self) private var preferences
    @State private var hovering = false

    var body: some View {
        CardChrome(hovering: $hovering, label: "Note \(note.title)", onTap: onEdit) {
            VStack(alignment: .leading, spacing: 5) {
                Text(note.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !note.summary.isEmpty {
                    Text(note.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .overlay(alignment: .bottom) {
                CardCaption(title: "Note", date: note.updatedAt) { EmptyView() }
            }
        } actionRow: {
            CopyAction(perform: copy)
            CardAction(symbol: "pencil", help: "Edit", perform: onEdit)
            CardAction(symbol: "trash", help: "Delete", tint: .red) { store.delete(note) }
        } menu: {
            Button("Edit…", action: onEdit)
            Button("Copy as Markdown", action: copy)
            if let clipboard, clipboard.canPaste {
                Button("Paste") {
                    copy()
                    clipboard.pressPaste()
                }
            }
            Divider()
            ForEach(NoteDestination.allCases) { destination in
                Button("Send to \(destination.title)") { NoteSharing.sendWithFeedback(note, to: destination, preferences: preferences) }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: note)]) }
            Button("Delete", role: .destructive) { store.delete(note) }
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(note.text, forType: .string)
        FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: note.title)
    }
}
