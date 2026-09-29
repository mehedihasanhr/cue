import SwiftUI
import TimelineKit

/// The language captions are listened for, and how a new recording's captions look.
struct CaptionSettingsPane: View {
    @Environment(StudioSettings.self) private var settings

    var body: some View {
        @Bindable var newProjects = settings.newProjects

        SettingsPane(.captions) {
            SettingsGroup(footer: "The same choice as the Language menu in the editor's Captions panel. Recognition runs on this Mac; nothing is sent anywhere.") {
                SettingsRow("Language", subtitle: "The language spoken in your recordings.",
                            symbol: "globe", tint: .blue) {
                    Picker("Language", selection: language) {
                        ForEach(CaptionLanguages.all, id: \.self) { Text(CaptionLanguages.title(for: $0)).tag($0) }
                    }
                    .fixedSize()
                }
            }

            SettingsGroup("How new captions look",
                          footer: "For recordings opened for the first time. Colours, margin and everything else are set per project in the editor's Captions panel.") {
                SettingsRow("Position") {
                    Picker("Position", selection: $newProjects.captionPosition) {
                        ForEach(CaptionStyle.Position.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Typeface") {
                    Picker("Typeface", selection: $newProjects.captionTypeface) {
                        ForEach(CaptionStyle.Typeface.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                SettingsRow("Size", subtitle: "Of the finished video's height, so captions keep their weight at any export size.") {
                    SettingsSlider("Caption size", value: $newProjects.captionSize, in: NewProjectDefaults.captionSizes) { value in
                        String(format: "%.1f%%", value * 100)
                    }
                }
                SettingsRow("Backdrop", subtitle: "The plate behind the words, which keeps them readable over a white page.") {
                    SettingsSlider("Caption backdrop", value: $newProjects.captionBackground,
                                   in: NewProjectDefaults.captionBackgrounds, format: SettingsSlider.percent)
                }
                SettingsRow("Arrives") {
                    Picker("Arrives", selection: $newProjects.captionAnimation) {
                        ForEach(CaptionStyle.Animation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsToggleRow("Light up each word as it is said",
                                  subtitle: "Draws the eye to the captions — right for a video watched without sound.",
                                  isOn: $newProjects.captionHighlightsWords)
            }
        }
    }

    /// The stored language, corrected to one the recogniser offers, so the picker never
    /// shows an empty box for a spelling an older build wrote.
    private var language: Binding<String> {
        Binding {
            CaptionLanguages.resolved(settings.captionLanguage)
        } set: {
            settings.captionLanguage = $0
        }
    }
}
