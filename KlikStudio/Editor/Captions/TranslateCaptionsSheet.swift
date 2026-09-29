import SwiftUI
import TimelineKit
import Translation

/// The captions, put into another language by the Mac's own translation.
///
/// On the Mac rather than through a service, for the reason the captions are made on it:
/// a recording of somebody's screen is nobody else's business. The first translation into
/// a language may ask to download it — that is the system's own sheet, and it is the only
/// way a language arrives.
@available(macOS 15.0, *)
struct TranslateCaptionsSheet: View {
    @Bindable var model: EditorModel

    private enum Phase: Equatable {
        case choosing
        case translating
        case failed(String)
    }

    @State private var languages: [Locale.Language] = []
    @State private var target = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var phase = Phase.choosing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Picker("Translate into", selection: $target) {
                    if languages.isEmpty { Text("Finding languages…").tag("") }
                    ForEach(languages, id: \.minimalIdentifier) { language in
                        Text(Self.name(of: language)).tag(language.minimalIdentifier)
                    }
                }
                .disabled(languages.isEmpty || phase == .translating)
                Text("Each caption keeps its timing. Word-by-word highlighting and removing filler words need the words as they were spoken, so they stop working until you undo the translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch phase {
                case .choosing:
                    EmptyView()
                case .translating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Translating \(model.timeline.captions.count) captions…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.isTranslatingCaptions = false }
                    .keyboardShortcut(.cancelAction)
                Button("Translate") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.isEmpty || phase == .translating || model.timeline.captions.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420)
        .task {
            let supported = await Self.supportedLanguages()
            languages = supported
                .filter { !$0.minimalIdentifier.isEmpty }
                .reduce(into: [Locale.Language]()) { unique, language in
                    if !unique.contains(where: { $0.minimalIdentifier == language.minimalIdentifier }) {
                        unique.append(language)
                    }
                }
                .sorted { Self.name(of: $0).localizedCompare(Self.name(of: $1)) == .orderedAscending }
            if target.isEmpty, let first = languages.first { target = first.minimalIdentifier }
        }
        // Run off the main actor, where the session is handed over and used: it is not
        // something that can cross actors. Only the captions' words go in and only the
        // translations come back.
        .translationTask(configuration) { @concurrent [model] session in
            let cues = await MainActor.run { model.timeline.captions.map { Cue(id: $0.id, text: $0.text) } }
            do {
                let texts = try await Self.translate(cues, with: session)
                await MainActor.run {
                    model.applyCaptionTranslation(texts)
                    model.isTranslatingCaptions = false
                }
            } catch {
                let message = "The captions couldn't be translated: \(error.localizedDescription)"
                await MainActor.run { phase = .failed(message) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Translate Captions").font(.headline)
                Text("On this Mac — nothing is sent anywhere")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func start() {
        guard let language = languages.first(where: { $0.minimalIdentifier == target }) else { return }
        phase = .translating
        // A new configuration each time, so pressing Translate again after a failure runs
        // again rather than being an unchanged value SwiftUI has already acted on.
        if configuration?.target == language {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: nil, target: language)
        }
    }

    private struct Cue: Sendable {
        let id: UUID
        let text: String
    }

    @concurrent nonisolated private static func translate(_ cues: [Cue],
                                                          with session: TranslationSession) async throws -> [UUID: String] {
        guard !cues.isEmpty else { return [:] }
        let requests = cues.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        var texts: [UUID: String] = [:]
        for response in try await session.translations(from: requests) {
            guard let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)) else { continue }
            texts[id] = response.targetText
        }
        return texts
    }

    /// Asked off the main actor, where the availability object is made and used: it is
    /// not something that can be handed across.
    @concurrent nonisolated private static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    private static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}

/// What the sheet says on a Mac without translation.
struct TranslationUnavailableSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Translate Captions").font(.headline)
            Text("Translating captions needs macOS 15 or later.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("OK", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
