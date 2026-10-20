import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// The transcript, and how it is drawn.
struct CaptionInspector: View {
    let model: EditorModel

    @Environment(StudioSettings.self) private var settings

    /// How long a silence has to be before "Shorten Pauses" takes it in hand.
    @State private var pauseLimit = 1.0
    /// Whether the transcript is shown as text to type into rather than words to pick.
    /// Words, whenever there are timed ones: cutting by what was said is what a
    /// transcript in an editor is for, and correcting a line throws its timings away.
    @State private var editsText = false
    /// The transcript line being typed into, so only it takes the full field box.
    @FocusState private var focusedLine: UUID?

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        // Nothing between the sections: each one brings its own air and its own rule.
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            if model.timeline.captions.isEmpty {
                empty
            } else {
                appearance
                transcript
                InspectorAdvancedGroup("captions", contents: ["Motion", "Tidy up", "Source", "Subtitle file"]) {
                    motion
                    tidy
                    source
                    export
                }
            }
        }
        .font(.system(size: 12))
    }

    // MARK: - Nothing yet

    /// Two ways in, because there are two kinds of recording: one where somebody is
    /// talking, and one where nobody is and the captions are the narration.
    private var empty: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            // One line, because it is the line that decides whether somebody presses the
            // button: where their audio goes.
            InspectorNote("Written on this Mac. The audio is never sent anywhere.")
                .help("Klik can listen to the recording and write down what was said. It happens on this Mac. The audio is never sent anywhere.")

            language

            generate(title: "Generate Captions", variant: .primary)

            addLine
                .help("Or write them yourself, a line at a time, starting where the playhead is.")
        }
        .inspectorSection("Transcript", systemImage: "captions.bubble")
    }

    private var language: some View {
        InspectorRow("Language") {
            InspectorPicker(selection: chosenLanguage,
                            options: CaptionLanguages.all,
                            title: CaptionLanguages.title(for:))
        }
        .help("The language spoken in the recording")
    }

    private var chosenLanguage: Binding<String> {
        Binding {
            CaptionLanguages.resolved(settings.captionLanguage)
        } set: { identifier in
            settings.captionLanguage = identifier
        }
    }

    /// Primary where it is the one thing an empty panel asks for; secondary once there is a
    /// transcript, where listening again is a second thought rather than the point.
    private func generate(title: String, variant: StudioButtonStyle.Variant = .secondary) -> some View {
        Button {
            model.generateCaptions()
        } label: {
            if model.isGeneratingCaptions {
                HStack(spacing: 6) {
                    // Determinate only where the recogniser actually reports a
                    // fraction; a spinner is the honest answer to "no idea yet".
                    if let done = model.captionProgress {
                        ProgressView(value: done).progressViewStyle(.circular).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Listening…")
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(model.isGeneratingCaptions)
        .buttonStyle(.studio(variant, size: .small))
    }

    private var addLine: some View {
        Button {
            model.addCaptionAtPlayhead()
        } label: {
            Label("Add Caption at Playhead", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.studio(.secondary, size: .small))
        .help("A caption to type into, starting at the playhead")
    }

    // MARK: - How they look

    private var appearance: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Show captions", isOn: style.binding(\.captionStyle.isVisible, "Captions"))

            Group {
                InspectorRow("Position") {
                    InspectorPicker(selection: style.binding(\.captionStyle.position, "Caption Position"),
                                    options: CaptionStyle.Position.allCases,
                                    title: \.title)
                }
                FontFamilyPicker(family: style.binding(\.captionStyle.fontFamily, "Caption Font"))
                // The system's type comes in four designs; a chosen family has its own.
                if model.timeline.captionStyle.fontFamily.isEmpty {
                    InspectorRow("Typeface") {
                        InspectorPicker(selection: style.binding(\.captionStyle.typeface, "Caption Typeface"),
                                        options: CaptionStyle.Typeface.allCases,
                                        title: \.title)
                    }
                }
                InspectorSlider(model: model, "Size", systemImage: "textformat.size",
                                value: style.binding(\.captionStyle.fontSize, "Caption Size"),
                                range: 0.02...0.12)
                InspectorSlider(model: model, "Backdrop", systemImage: "rectangle.fill",
                                value: style.binding(\.captionStyle.backgroundOpacity, "Caption Backdrop"),
                                range: 0...1)
                InspectorSlider(model: model, "Margin", systemImage: "arrow.up.and.down",
                                value: style.binding(\.captionStyle.margin, "Caption Margin"),
                                range: 0.01...0.25)
                InspectorRow("Colour") {
                    InspectorColorWell(title: "Caption colour", selection: colour(\.captionStyle.color, "Caption Colour"))
                }
            }
            // The switch itself stays live: it is the way back.
            .disabled(!model.timeline.captionStyle.isVisible)
        }
        .inspectorSection("Appearance", systemImage: "textformat")
    }

    private var motion: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow("Arrives") {
                InspectorPicker(selection: style.binding(\.captionStyle.animation, "Caption Animation"),
                                options: CaptionStyle.Animation.allCases,
                                title: \.title)
            }
            InspectorSwitch("Light up each word as it is said",
                            isOn: style.binding(\.captionStyle.highlightsWords, "Word Highlight"))
            if model.timeline.captionStyle.highlightsWords {
                InspectorRow("Highlight") {
                    InspectorColorWell(title: "Highlight colour",
                                       selection: colour(\.captionStyle.highlightColor, "Highlight Colour"))
                }
            }
        }
        .disabled(!model.timeline.captionStyle.isVisible)
        .inspectorSection("Motion", systemImage: "sparkles")
    }

    private func colour(_ path: WritableKeyPath<Timeline, ColorValue> & Sendable, _ name: String) -> Binding<Color> {
        Binding {
            Color(model.timeline[keyPath: path].rgba.nsColor)
        } set: { colour in
            style.set(path, to: RGBA(NSColor(colour)).colorValue, name)
        }
    }

    // MARK: - What they say

    private var transcript: some View {
        let picksWords = model.hasTimedWords && !editsText
        return VStack(alignment: .leading, spacing: 4) {
            if picksWords {
                TranscriptWords(model: model)
            } else {
                ForEach(model.timeline.captions) { cue in
                    line(cue)
                }
            }
            addLine
                .padding(.top, SidebarSpacing.betweenControls - 4)
        }
        .inspectorSection("Transcript", systemImage: "captions.bubble") {
            HStack(spacing: 10) {
                if model.hasTimedWords {
                    SectionButton(title: editsText ? "Pick Words" : "Edit Text") {
                        editsText.toggle()
                        model.transcriptWords.clear()
                    }
                    .help(editsText
                          ? "Pick words to cut them from the video"
                          : "Type into the lines. A corrected line loses its word timings.")
                }
                SectionButton(title: "Clear") { model.clearCaptions() }
                    .help("Remove every caption")
            }
        }
    }

    /// One line, editable, with the playhead's line marked.
    ///
    /// Clicking a line's time moves the playhead to it and selects it, because the reason
    /// to look at a transcript in an editor is almost always to find the moment it belongs
    /// to — and the next thing wanted is usually to retime or split that line.
    private func line(_ cue: CaptionCue) -> some View {
        let isCurrent = model.captionAtPlayhead?.id == cue.id
        return HStack(alignment: .top, spacing: 8) {
            Button {
                model.scrub(to: cue.start)
            } label: {
                Text(Timecode.short(cue.start))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(StudioPressStyle())
            .frame(width: 48, alignment: .leading)
            .padding(.top, 4)
            .help("Go to this caption")

            // A quiet field: the line reads as text, and takes the kit's box only while
            // it is being typed in.
            TextField("Empty caption", text: text(for: cue), axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 11))
                .focused($focusedLine, equals: cue.id)
                .studioField(isFocused: focusedLine == cue.id, isMultiline: true, isQuiet: true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contextMenu {
            Button("Go to This Line") { model.scrub(to: cue.start) }
            Button("Edit Timing") { model.select(.caption(cue.id)) }
            Divider()
            Button("Remove Line from Video", role: .destructive) { model.removeCaptionFromVideo(cue.id) }
        }
    }

    // MARK: - Tidying the speech

    /// Cutting by what was said: the ums, and the waits.
    private var tidy: some View {
        let fillers = model.fillerRanges.count
        let pauses = model.pauseRanges(longerThan: pauseLimit).count
        let timed = model.hasTimedWords
        return VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Button {
                model.removeFillerWords()
            } label: {
                Text(fillers == 0 ? "No Filler Words" : fillers == 1 ? "Remove 1 Filler Word" : "Remove \(fillers) Filler Words")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.studio(.secondary, size: .small))
            .disabled(fillers == 0)
            .help("Cut out every um, uh and er. Cuts the video there, picture and sound together. Undo puts it all back.")

            InspectorRow("Pauses") {
                InspectorPicker(selection: $pauseLimit, options: [0.5, 1, 1.5, 2, 3]) { limit in
                    limit < 1 ? "Over half a second" : limit == 1 ? "Over a second" : String(format: "Over %g seconds", limit)
                }
            }
            Button {
                model.shortenPauses(longerThan: pauseLimit)
            } label: {
                Text(pauses == 0 ? "No Pauses That Long" : pauses == 1 ? "Shorten 1 Pause" : "Shorten \(pauses) Pauses")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.studio(.secondary, size: .small))
            .disabled(pauses == 0)
            .help("Cut each long silence down to \(String(format: "%g", EditorModel.keptPause)) seconds. Cuts the video there, picture and sound together. A pause in which something is clicked is left alone. Undo puts it all back.")

            // The one line kept: without timed words none of this can work, and the
            // dimmed buttons alone would not say why.
            if !timed {
                InspectorNote("Needs captions made by listening to the recording.")
                    .help("Only captions made by listening to the recording know when each word was said. Generate them to tidy the speech.")
            }
        }
        .controlSize(.small)
        .disabled(!timed)
        .inspectorSection("Tidy Up", systemImage: "wand.and.stars")
    }

    private func text(for cue: CaptionCue) -> Binding<String> {
        Binding {
            model.timeline.captions.first { $0.id == cue.id }?.text ?? ""
        } set: { text in
            model.setCaptionText(cue.id, text)
        }
    }

    // MARK: - Listening again

    private var source: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            language
            generate(title: "Listen Again")
                .help("Listening again replaces these captions, including any you have corrected. Undo brings them back.")
        }
        .inspectorSection("From the Recording", systemImage: "waveform")
    }

    // MARK: - As a file

    private var export: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            HStack(spacing: 8) {
                ForEach(CaptionExport.Format.allCases, id: \.self) { format in
                    Button {
                        model.exportCaptions(as: format)
                    } label: {
                        Text(format.buttonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .help("\(format.purpose). A subtitle file to upload beside the video, for players that draw captions themselves.")
                }
            }
            .buttonStyle(.studio(.secondary, size: .small))
            Button {
                model.isTranslatingCaptions = true
            } label: {
                Label("Translate Captions…", systemImage: "character.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.studio(.secondary, size: .small))
            .help("Put the captions into another language, on this Mac. Undo puts the original back.")
        }
        .inspectorSection("Subtitle File", systemImage: "doc.text")
    }
}

private extension CaptionExport.Format {
    var buttonTitle: String {
        switch self {
        case .srt: "Export SRT…"
        case .vtt: "Export VTT…"
        }
    }

    var purpose: String {
        switch self {
        case .srt: "SubRip, which YouTube, LinkedIn and most video editors read"
        case .vtt: "WebVTT, for video on a web page"
        }
    }
}
