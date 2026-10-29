import SwiftUI

/// A microphone beside a text field: press to talk, press again and what was said is typed
/// where the caret is. Red and pulsing with the voice while it listens, a spinner while the
/// words are worked out.
///
/// macOS's own Dictation (Fn twice) works in the same fields too; this is the button for
/// people who did not know that, and the way to use a Whisper model instead.
struct DictationButton: View {
    /// Puts the dictated text into the field.
    let insert: (String) -> Void
    var size: CGFloat = 13

    @State private var id = UUID()
    private var service: DictationService { .shared }

    var body: some View {
        let listening = service.isListening(id)
        let transcribing = service.isTranscribing(id)
        Button(action: toggle) {
            ZStack {
                if listening {
                    Circle()
                        .fill(Color.red.opacity(0.18 + 0.4 * service.level))
                        .scaleEffect(1 + 0.25 * service.level)
                        .animation(.easeOut(duration: 0.08), value: service.level)
                }
                if transcribing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic")
                        .font(.system(size: listening ? size - 3 : size, weight: .medium))
                        .foregroundStyle(listening ? Color.red : Color.secondary)
                }
            }
            .frame(width: size + 13, height: size + 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(transcribing || (service.state != .idle && service.owner != id))
        .help(listening ? "Stop and type what you said" : "Dictate (or press Fn twice)")
        .accessibilityLabel(listening ? "Stop dictating" : "Dictate")
        // A window closed mid-dictation does not leave the microphone on.
        .onDisappear { if service.owner == id, service.state == .listening { service.cancel() } }
    }

    private func toggle() {
        Task { @MainActor in
            if service.isListening(id) {
                if let text = await service.finish(for: id) { insert(text) }
            } else {
                await service.start(for: id)
            }
        }
    }
}
