import DictationKit
import FoundationModels
import SwiftUI

/// Settings › Dictation: which recogniser the microphone buttons use, the language, and
/// the Whisper models: download, update, use, remove.
struct DictationSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @State private var confirmsRemoveAll = false
    private var service: DictationService { .shared }

    /// The languages offered by name; any other is reached through Automatic.
    static let languages: [(code: String, name: String)] = [
        ("", "Automatic"), ("en", "English"), ("bn", "Bangla"), ("hi", "Hindi"), ("ur", "Urdu"),
        ("ar", "Arabic"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("pt", "Portuguese"),
        ("it", "Italian"), ("tr", "Turkish"), ("ru", "Russian"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
    ]

    private var voiceTypingFooter: String {
        preferences.voiceTypingKey == .fn
            ? "If tapping Fn opens the emoji picker or macOS Dictation, set System Settings › Keyboard › Press 🌐 key to Do Nothing."
            : "Hold the key on its own; with another key it is the usual shortcut and Cue stays out of it."
    }

    private static var hasAppleIntelligence: Bool {
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability != .unavailable(.deviceNotEligible) }
        return false
    }

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPane(.dictation) {
            SettingsGroup("Dictation", footer: "The microphone button in task and note forms. macOS's own Dictation works in every text field too: press Fn twice.") {
                SettingsRow("Engine", subtitle: "macOS: built in, free, nothing to download. Whisper: a model you download below, often better with accents and mixed languages.") {
                    Picker("Engine", selection: $preferences.dictationEngine) {
                        ForEach(AppPreferences.DictationEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Language", subtitle: "Automatic: your Mac's language for macOS, whatever is spoken for Whisper.") {
                    Picker("Language", selection: $preferences.dictationLanguage) {
                        ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .fixedSize()
                }
                if preferences.dictationEngine == .whisper, service.chosenWhisperModel == nil {
                    SettingsRow("No Whisper model downloaded", subtitle: "Until one is, dictation uses macOS.", symbol: "exclamationmark.triangle", tint: .orange) {
                        EmptyView()
                    }
                }
            }

            SettingsGroup("Voice typing", footer: voiceTypingFooter) {
                SettingsRow("Talk into any app", subtitle: "Hold the key, speak, and let go: what you said is typed where the caret is. Tap the key to talk hands-free until you pause. Esc stops.") {
                    Toggle("Talk into any app", isOn: $preferences.voiceTypingEnabled).toggleStyle(.switch)
                }
                SettingsRow("Hold to talk", subtitle: "A key on its own, or a shortcut you record: Shortcut, then press the keys.") {
                    HStack(spacing: 10) {
                        Picker("Hold to talk", selection: $preferences.voiceTypingKey) {
                            ForEach(AppPreferences.VoiceTypingKey.allCases, id: \.self) { key in
                                if key == .shortcut { Divider() }
                                Text(key.title).tag(key)
                            }
                        }
                        .fixedSize()
                        if preferences.voiceTypingKey == .shortcut {
                            ShortcutRecorderView(hotkey: preferences.voiceTypingShortcut,
                                                 onChange: { preferences.voiceTypingShortcut = $0 },
                                                 onRecordingChanged: { _ in })
                        }
                    }
                }
                .disabled(!preferences.voiceTypingEnabled)
                SettingsRow("Hey Cue", subtitle: "Say \"Hey Cue\" to start talking, no key needed. Keeps the microphone on while Cue runs (macOS shows its orange dot), but the recogniser only wakes when someone talks, and the microphone closes while the Mac is locked or asleep. Heard on this Mac only.") {
                    Toggle("Hey Cue", isOn: $preferences.voiceTypingWakeWord).toggleStyle(.switch)
                }
                .disabled(!preferences.voiceTypingEnabled)
                SettingsRow("Auto-format", subtitle: "Takes out \"um\" and \"uh\", adds punctuation and capitals, and turns \"new line\" and \"new paragraph\" into breaks.") {
                    Toggle("Auto-format", isOn: $preferences.dictationAutoFormat).toggleStyle(.switch)
                }
                if Self.hasAppleIntelligence {
                    SettingsRow("Tidy with Apple Intelligence", subtitle: "Also fixes false starts and turns lists you say into bullet points, on this Mac. Falls back to the simple tidy when it can't.") {
                        Toggle("Tidy with Apple Intelligence", isOn: $preferences.dictationSmartFormat).toggleStyle(.switch)
                    }
                    .disabled(!preferences.dictationAutoFormat)
                }
                if preferences.voiceTypingEnabled, !PermissionManager.hasAccessibilityAccess {
                    SettingsRow("Allow Accessibility", subtitle: "Cue needs it to notice the key in other apps and to paste for you. Add Cue in System Settings › Privacy & Security › Accessibility.",
                                symbol: "exclamationmark.triangle", tint: .orange) {
                        Button("Open Settings") {
                            PermissionManager.requestAccessibilityAccess()
                            PermissionManager.revealAppInFinder()
                        }
                    }
                }
            }
            .onChange(of: preferences.voiceTypingEnabled) { VoiceTyping.shared.update() }
            .onChange(of: preferences.voiceTypingKey) { VoiceTyping.shared.update() }
            .onChange(of: preferences.voiceTypingShortcut) { VoiceTyping.shared.update() }
            .onChange(of: preferences.voiceTypingWakeWord) { VoiceTyping.shared.update() }

            SettingsGroup("Whisper models", footer: "Downloaded from Hugging Face and run on this Mac; nothing you say leaves it. Remove deletes a model and everything of it. Update downloads the new version beside the old one, and deletes the old one once the new one works.") {
                ForEach(WhisperModel.all) { model in
                    WhisperModelRow(model: model)
                }
                SettingsRow("Space used: \(service.totalBytes == 0 ? "None" : ByteCountFormatter.string(fromByteCount: service.totalBytes, countStyle: .file))") {
                    HStack(spacing: 8) {
                        Button(service.checkingForUpdates ? "Checking" : "Check for Updates") {
                            Task { await service.checkForUpdates() }
                        }
                        .disabled(service.checkingForUpdates || service.totalBytes == 0)
                        Button("Remove All", role: .destructive) { confirmsRemoveAll = true }
                            .disabled(service.totalBytes == 0 && service.downloads.isEmpty)
                    }
                }
            }
        }
        .task { await service.loadDownloadSizes() }
        .confirmationDialog("Remove every Whisper model?", isPresented: $confirmsRemoveAll) {
            Button("Remove All", role: .destructive) { Task { await service.removeAll() } }
        } message: {
            Text("Their files are deleted from this Mac. Dictation goes back to macOS until you download one again.")
        }
    }
}

/// One model: its size, and Download, or Use, Update and Remove; a bar while it downloads.
private struct WhisperModelRow: View {
    let model: WhisperModel
    @Environment(AppPreferences.self) private var preferences
    private var service: DictationService { .shared }

    var body: some View {
        let installation = service.installation(of: model)
        let inUse = installation != nil && preferences.dictationWhisperModel == model.id
        SettingsRow(title(installation: installation, inUse: inUse), subtitle: model.detail,
                    symbol: inUse ? "checkmark.circle.fill" : "waveform", tint: inUse ? .green : .gray) {
            HStack(spacing: 8) {
                if let error = service.modelErrors[model.id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                        .accessibilityLabel(error)
                }
                if let fraction = service.downloads[model.id] {
                    ProgressView(value: fraction)
                        .frame(width: 110)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(SettingsFont.sub)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    Button("Cancel") { service.cancelDownload(model) }
                } else if installation != nil {
                    if service.updates.contains(model.id) {
                        Button("Update") { service.download(model) }
                    }
                    if !inUse {
                        Button("Use") {
                            preferences.dictationWhisperModel = model.id
                            preferences.dictationEngine = .whisper
                        }
                    }
                    Button("Remove", role: .destructive) { Task { await service.remove(model) } }
                } else {
                    Button("Download") { service.download(model) }
                }
            }
        }
    }

    /// Its real size: what it takes on disk once downloaded, what the download weighs (as
    /// Hugging Face reports it) before. The catalog's figure only until the repository answers.
    private func title(installation: WhisperModelStore.Installation?, inUse: Bool) -> String {
        let bytes = installation?.bytes ?? service.downloadSizes[model.id] ?? model.approximateBytes
        let size = Self.format(bytes)
        let state = service.updates.contains(model.id) ? " · Update available" : (inUse ? " · In use" : "")
        return "\(model.title) · \(size)\(state)"
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
