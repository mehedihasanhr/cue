import AppKit
import BackgroundKit
import SwiftUI
import TimelineKit

/// The transcript, and how it is drawn.
struct CaptionInspector: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.timeline.captions.isEmpty {
                empty
            } else {
                appearance
                transcript
            }
        }
        .font(.system(size: 12))
    }

    // MARK: - Nothing yet

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Captions", systemImage: "captions.bubble")
                .font(.system(size: 13, weight: .semibold))
            Text("Klik Studio can listen to the recording and write down what was said. It happens on this Mac — the audio is never sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                } else {
                    Text("Generate Captions")
                }
            }
            .disabled(model.isGeneratingCaptions)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - How they look

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show captions", isOn: style.binding(\.captionStyle.isVisible, "Captions"))

            Picker("Position", selection: style.binding(\.captionStyle.position, "Caption Position")) {
                ForEach(CaptionStyle.Position.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            InspectorSlider(model: model, "Size", systemImage: "textformat.size",
                            value: style.binding(\.captionStyle.fontSize, "Caption Size"),
                            range: 0.02...0.12)
            InspectorSlider(model: model, "Backdrop", systemImage: "rectangle.fill",
                            value: style.binding(\.captionStyle.backgroundOpacity, "Caption Backdrop"),
                            range: 0...1)
            InspectorSlider(model: model, "Margin", systemImage: "arrow.up.and.down",
                            value: style.binding(\.captionStyle.margin, "Caption Margin"),
                            range: 0.01...0.25)

            ColorPicker("Colour", selection: colour, supportsOpacity: false)
        }
        .disabled(!model.timeline.captionStyle.isVisible)
        .inspectorSection("Appearance", systemImage: "textformat")
    }

    private var colour: Binding<Color> {
        Binding {
            Color(model.timeline.captionStyle.color.rgba.nsColor)
        } set: { colour in
            style.set(\.captionStyle.color, to: RGBA(NSColor(colour)).colorValue, "Caption Colour")
        }
    }

    // MARK: - What they say

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.timeline.captions) { cue in
                line(cue)
            }

            HStack {
                Button("Regenerate") { model.generateCaptions() }
                    .disabled(model.isGeneratingCaptions)
                Button("Clear", role: .destructive) { model.clearCaptions() }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .inspectorSection("Transcript", systemImage: "captions.bubble")
    }

    /// One line, editable, with the playhead's line marked.
    ///
    /// Clicking a line moves the playhead to it, because the reason to look at a
    /// transcript in an editor is almost always to find the moment it belongs to.
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
            .buttonStyle(.plain)
            .frame(width: 48, alignment: .leading)

            TextField("", text: text(for: cue), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 11))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func text(for cue: CaptionCue) -> Binding<String> {
        Binding {
            model.timeline.captions.first { $0.id == cue.id }?.text ?? ""
        } set: { text in
            model.setCaptionText(cue.id, text)
        }
    }
}
