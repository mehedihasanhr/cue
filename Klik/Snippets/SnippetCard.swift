import AppKit
import SwiftUI

/// A snippet on the island: its keyword as a badge, the name, and the template (or
/// the file it pastes). A click copies the expansion; the menu edits or deletes.
struct SnippetCard: View {
    let snippet: Snippet
    let store: SnippetStore
    let assets: AssetStore
    var clipboard: ClipboardHistory? = nil
    var onEdit: () -> Void = {}
    @State private var hovering = false

    private var asset: AssetItem? {
        snippet.assetID.flatMap { id in assets.items.first { $0.id == id } }
    }

    var body: some View {
        CardChrome(hovering: $hovering, label: "Snippet \(snippet.keyword)\(snippet.name.isEmpty ? "" : ", \(snippet.name)")", onTap: copy) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(snippet.keyword)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .lineLimit(1)
                    if !snippet.name.isEmpty {
                        Text(snippet.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                }
                if let asset {
                    HStack(spacing: 8) {
                        Group {
                            if let thumbnail = assets.thumbnail(for: asset) {
                                Image(nsImage: thumbnail).resizable().scaledToFill()
                            } else {
                                Image(systemName: "doc").font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .frame(width: 56, height: 40)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(asset.fileName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                    }
                } else {
                    Text(snippet.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(4)
                }
                let blanks = snippet.placeholders
                if !blanks.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(blanks, id: \.self) { blank in
                            Text(blank)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .overlay(alignment: .bottom) {
                CardCaption(title: snippet.uses == 1 ? "Used once" : "Used \(snippet.uses) times", date: snippet.createdAt) {
                    if !snippet.placeholders.isEmpty { Badge(text: "\(snippet.placeholders.count) blank\(snippet.placeholders.count == 1 ? "" : "s")") }
                }
            }
        } actionRow: {
            CopyAction(perform: copy)
            CardAction(symbol: "pencil", help: "Edit", perform: onEdit)
            CardAction(symbol: "trash", help: "Remove", tint: .red) { store.delete(snippet) }
        } menu: {
            Button("Copy", action: copy)
            if let clipboard, clipboard.canPaste {
                Button("Paste") {
                    copy()
                    clipboard.pressPaste()
                }
            }
            Button("Edit…", action: onEdit)
            Divider()
            Button("Delete", role: .destructive) { store.delete(snippet) }
        }
    }

    private func copy() {
        Self.copy(snippet, store: store, assets: assets)
    }

    /// The keyword on a brand-coloured tile, for dragging the expansion out.
    static func dragImage(for snippet: Snippet) -> NSImage {
        let text = snippet.keyword as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let size = text.size(withAttributes: [.font: font])
        let padded = NSSize(width: size.width + 20, height: 28)
        return NSImage(size: padded, flipped: false) { rect in
            NSColor(Color.brand).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            text.draw(at: NSPoint(x: 10, y: (padded.height - size.height) / 2), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            return true
        }
    }

    /// Copies the expansion (blanks left empty, the built-ins filled) or the asset.
    static func copy(_ snippet: Snippet, store: SnippetStore, assets: AssetStore) {
        if let id = snippet.assetID, let asset = assets.items.first(where: { $0.id == id }) {
            assets.copy(asset)
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: asset.fileName, image: assets.thumbnail(for: asset))
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(SnippetTemplate.expand(snippet.text, values: [:], clipboard: nil), forType: .string)
            FeedbackHUD.show("Copied", symbol: "checkmark.circle.fill", duration: .seconds(1.2), subtitle: snippet.title)
        }
        store.recordUse(snippet)
    }
}
