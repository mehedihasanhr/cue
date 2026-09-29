import SwiftUI

/// Chooses the language Capture Text reads.
///
/// A button that opens a searchable list, rather than a `Picker`: Vision alone offers
/// 33 languages and the Tesseract packs add more, which is well past what a pop-up
/// menu can show comfortably. The shape is `MenuBarIconPicker`'s — the same pill, the
/// same chevron, the same popover — so it sits with the rest of Settings.
///
/// Every row says who would read it and what that costs, because the alternative is
/// the reader discovering afterwards that their screenshot went to a web service or
/// that a language they picked cannot actually be read.
struct SettingsLanguagePicker: View {
    @Binding var tags: [String]
    /// What each engine could do with a given language, supplied by the pane.
    let availability: (OCREngineID, OCRLanguage) -> OCREngineAvailability

    @State private var open = false
    @State private var query = ""

    private var selected: OCRLanguage? { tags.first.flatMap(OCRLanguageCatalog.language(for:)) }

    private var matches: [OCRLanguage] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return OCRLanguageCatalog.all }
        return OCRLanguageCatalog.all.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.nativeName.lowercased().contains(needle)
                || $0.tag.lowercased().contains(needle)
        }
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selected?.displayName ?? "Detect automatically")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .frame(height: 28)
            .background(SettingsPalette.pill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsPalette.edge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose the language Capture Text reads")
        .accessibilityLabel("Recognition language")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                search
                Divider()
                list
            }
            .frame(width: 330, height: 390)
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search languages", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.isEmpty {
                    row(title: "Detect automatically",
                        detail: "What Klik has always done — Apple Vision picks the language.",
                        badge: nil, badgeTint: .secondary, enabled: true,
                        selected: tags.isEmpty) {
                        tags = []
                        open = false
                    }
                    Divider().padding(.vertical, 4)
                }
                ForEach(matches) { language in
                    let state = best(for: language)
                    row(title: language.displayName,
                        detail: "\(language.nativeName) · \(language.tag)",
                        badge: state.badge, badgeTint: state.tint, enabled: state.enabled,
                        selected: tags.first == language.tag) {
                        tags = [language.tag]
                        open = false
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func row(title: String, detail: String, badge: String?, badgeTint: Color,
                     enabled: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SettingsPalette.pill, in: Capsule())
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SettingsPalette.selectedRow : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// The best an engine could do with this language, and how to say it in a word.
    private func best(for language: OCRLanguage) -> (badge: String?, tint: Color, enabled: Bool) {
        // Vision needs no badge: it is the default and it costs nothing.
        if availability(.vision, language).isReady { return (nil, .secondary, true) }

        switch availability(.tesseract, language) {
        case .ready:
            return ("On device", .secondary, true)
        case .needsDownload(let bytes):
            let size = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            return (size.map { "\($0) download" } ?? "Download", .secondary, true)
        case .downloading:
            return ("Downloading…", .secondary, true)
        case .failed:
            return ("Download failed", .orange, true)
        case .needsSetup, .unsupported:
            break
        }

        switch availability(.cloud, language) {
        case .ready: return ("Cloud", .orange, true)
        case .needsSetup: return ("Needs a key", .orange, false)
        default: return ("Not supported", .secondary, false)
        }
    }
}
