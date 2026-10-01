import AppKit
import BackgroundKit
import CoreMedia
import SwiftUI
import TimelineKit

/// A freeze frame or a title slide: how long it lasts and, for a title, what it says.
///
/// Neither has a speed or an in- and out-point — a hold consumes no footage — so the
/// footage panel's controls would all be controls that do nothing. Length is the one
/// thing both have, and it is first.
struct ClipHoldInspector: View {
    let model: EditorModel
    let clip: Clip
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                if clip.isStill {
                    InspectorRow(title: "Holds the frame at", value: Timecode.short(clip.sourceStart))
                        .help("A still of the recording, silent while it holds. Zooms and notes over it stay where you put them.")
                }
                InspectorRow(title: "Starts", value: Timecode.short(model.timeline.start(ofClipAt: index)))
                InspectorSlider(model: model, "Length", systemImage: "timer",
                                value: length,
                                range: 0.5...max(10, clip.duration.seconds),
                                format: { String(format: "%.1f s", $0) })
                verbs
            }
            .inspectorSection(clip.isTitle ? "Title Slide" : "Freeze Frame",
                              systemImage: clip.isTitle ? "textformat" : "snowflake") {
                Text("Clip \(index + 1) of \(model.timeline.clips.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let card = clip.title {
                TitleCardInspector(model: model, clipID: clip.id, card: card)
            }
        }
    }

    private var length: Binding<Double> {
        Binding {
            model.timeline.clips.first { $0.id == clip.id }?.duration.seconds ?? clip.duration.seconds
        } set: { seconds in
            model.setHold(clip.id, seconds: seconds)
        }
    }

    private var verbs: some View {
        HStack(spacing: 6) {
            Button("Duplicate") { model.duplicateFootage(.clip(clip.id)) }
                .help("A second copy straight after this one")
            Spacer(minLength: 0)
            ClipOrderButtons(model: model, index: index)
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.timeline.clips.count < 2)
            .help(model.timeline.clips.count < 2
                  ? "An edit has to keep one piece"
                  : "Remove this and close the gap")
        }
        .controlSize(.small)
    }
}

/// What a title says, where, and how it looks.
struct TitleCardInspector: View {
    let model: EditorModel
    let clipID: UUID
    let card: TitleCard

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                TitleTextField(model: model, clipID: clipID, placeholder: "Title",
                               path: \.title, undoName: "Title Text")
                TitleTextField(model: model, clipID: clipID, placeholder: "Subtitle (optional)",
                               path: \.subtitle, undoName: "Subtitle Text")
            }
            .inspectorSection("Words", systemImage: "character.cursor.ibeam")

            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorRow("Layout") {
                    InspectorPicker(selection: restyled(\.layout, "Title Layout"),
                                    options: TitleCard.Layout.allCases) { $0.title }
                }
                InspectorRow("Behind") {
                    InspectorPicker(selection: backdrop, options: TitleCard.Backdrop.allCases) { $0.title }
                }
                InspectorRow("Arrives") {
                    InspectorPicker(selection: restyled(\.entrance, "Title Entrance"),
                                    options: TitleCard.Entrance.allCases) { $0.title }
                }
                FontFamilyPicker(family: restyled(\.fontFamily, "Title Font"))
                // The system's type comes in four designs; a chosen family has its own.
                if card.fontFamily.isEmpty {
                    InspectorRow("Type") {
                        InspectorPicker(selection: restyled(\.typeface, "Title Type"),
                                        options: CaptionStyle.Typeface.allCases) { $0.title }
                    }
                }
                InspectorSlider(model: model, "Size", systemImage: "textformat.size",
                                value: restyled(\.size, "Title Size"),
                                range: TitleCard.minimumSize...TitleCard.maximumSize)
                InspectorRow("Words") {
                    InspectorColorWell(title: "Words colour", selection: colour(\.textColor, "Title Colour"))
                }
                if card.backdrop == .panel {
                    InspectorRow("Panel") {
                        InspectorColorWell(title: "Panel colour", selection: colour(\.panelColor, "Panel Colour"))
                    }
                }
            }
            .inspectorSection("Look", systemImage: "paintbrush")
        }
    }

    private func current() -> TitleCard {
        model.timeline.clips.first { $0.id == clipID }?.title ?? card
    }

    private func restyled<Value: Sendable & Equatable>(_ path: WritableKeyPath<TitleCard, Value> & Sendable,
                                                       _ name: String) -> Binding<Value> {
        Binding {
            current()[keyPath: path]
        } set: { value in
            model.restyleTitle(clipID, name) { $0[keyPath: path] = value }
        }
    }

    /// Changing what the words stand on, and keeping them readable while doing it: white
    /// words — the default, for a wallpaper — on the default near-white panel are not
    /// there at all, so they turn dark, and back again.
    private var backdrop: Binding<TitleCard.Backdrop> {
        Binding {
            current().backdrop
        } set: { backdrop in
            model.restyleTitle(clipID, "Title Backdrop") { card in
                let wasPanel = card.backdrop == .panel
                card.backdrop = backdrop
                if backdrop == .panel, !wasPanel, card.textColor == .white {
                    card.textColor = ColorValue(r: 0.1, g: 0.1, b: 0.12)
                } else if backdrop == .background, wasPanel, card.textColor == ColorValue(r: 0.1, g: 0.1, b: 0.12) {
                    card.textColor = .white
                }
            }
        }
    }

    private func colour(_ path: WritableKeyPath<TitleCard, ColorValue> & Sendable, _ name: String) -> Binding<Color> {
        Binding {
            Color(current()[keyPath: path].rgba.nsColor)
        } set: { colour in
            let value = RGBA(NSColor(colour)).colorValue
            model.restyleTitle(clipID, name) { $0[keyPath: path] = value }
        }
    }
}

/// A line of a title, written straight onto the slide.
///
/// Live, so the preview shows the words as they are typed, but one step on the undo stack
/// for the whole of the typing rather than one per letter: the first keystroke opens an
/// interaction and leaving the field closes it, which is how a slider drag is coalesced.
struct TitleTextField: View {
    let model: EditorModel
    let clipID: UUID
    let placeholder: String
    let path: WritableKeyPath<TitleCard, String> & Sendable
    let undoName: String

    @FocusState private var isFocused: Bool
    /// Whether this field opened the interaction the typing is going into. Only then does
    /// it close one: leaving the field as a drag on the timeline begins must not end the
    /// drag's interaction, or every step of that drag lands on the undo stack.
    @State private var isTyping = false

    var body: some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .focused($isFocused)
            .onSubmit { finishTyping() }
            .onChange(of: isFocused) { _, focused in
                if !focused { finishTyping() }
            }
            .onDisappear { finishTyping() }
            .accessibilityLabel(placeholder)
    }

    private func finishTyping() {
        guard isTyping else { return }
        isTyping = false
        model.finishInteraction()
    }

    private var text: Binding<String> {
        Binding {
            model.timeline.clips.first { $0.id == clipID }?.title?[keyPath: path] ?? ""
        } set: { value in
            if !isTyping, !model.document.isInteracting {
                model.document.beginInteraction(undoName)
                isTyping = true
            }
            model.restyleTitle(clipID, undoName) { $0[keyPath: path] = value }
        }
    }
}

/// Earlier and later, for a clip of any kind.
struct ClipOrderButtons: View {
    let model: EditorModel
    let index: Int

    var body: some View {
        HStack(spacing: 2) {
            Button { model.moveClip(from: index, to: index - 1) } label: {
                Image(systemName: "arrow.left")
            }
            .disabled(index == 0)
            .help(index == 0 ? "This is the first clip" : "Move this clip earlier (⌥⌘←)")
            .accessibilityLabel("Move Clip Earlier")
            Button { model.moveClip(from: index, to: index + 1) } label: {
                Image(systemName: "arrow.right")
            }
            .disabled(index >= model.timeline.clips.count - 1)
            .help(index >= model.timeline.clips.count - 1 ? "This is the last clip" : "Move this clip later (⌥⌘→)")
            .accessibilityLabel("Move Clip Later")
        }
    }
}

/// How a clip arrives from the one before it.
struct ClipTransitionInspector: View {
    let model: EditorModel
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow("Style") {
                InspectorPicker(selection: style,
                                options: [nil] + ClipTransition.Style.allCases.map { Optional($0) }) {
                    $0?.title ?? "Cut"
                }
            }
            if clip.transition != nil {
                InspectorSlider(model: model, "Length", systemImage: "timer",
                                value: length,
                                range: ClipTransition.minimumDuration.seconds...ClipTransition.maximumDuration.seconds,
                                format: { String(format: "%.1f s", $0) })
                if let index = model.timeline.clips.firstIndex(where: { $0.id == clip.id }),
                   let used = model.timeline.transition(into: index)?.duration,
                   let asked = clip.transition?.duration, used < asked {
                    InspectorNote("Shortened to \(String(format: "%.1f s", used.seconds)) to fit.")
                        .help("Shortened to \(String(format: "%.1f s", used.seconds)) — half of it falls in each clip, and the shorter clip has no more room.")
                }
            }
        }
        .inspectorSection("Transition In", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
    }

    private var style: Binding<ClipTransition.Style?> {
        Binding {
            model.timeline.clips.first { $0.id == clip.id }?.transition?.style
        } set: { style in
            model.setTransitionStyle(clip.id, style)
        }
    }

    private var length: Binding<Double> {
        Binding {
            model.timeline.clips.first { $0.id == clip.id }?.transition?.duration.seconds
                ?? ClipTransition.defaultDuration.seconds
        } set: { seconds in
            guard let transition = model.timeline.clips.first(where: { $0.id == clip.id })?.transition else { return }
            model.setTransition(clip.id, ClipTransition(transition.style,
                                                        duration: CMTime(seconds: seconds, preferredTimescale: 600)))
        }
    }
}
