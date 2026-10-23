import AppKit
import SwiftUI

/// A small floating window of notes to read from while recording.
///
/// Kept out of every recording two ways. The one that matters is the filter: a display or
/// area recording leaves out every window this app owns (`ShareableContentStore.filter`
/// excludes Cue Studio by bundle identifier), and a window recording is of that window
/// alone. The second is `sharingType = .none`, which asks the window server to leave it out
/// of other apps' captures too — a screen shared in a call, say — so the notes stay the
/// speaker's.
@MainActor
final class SpeakerNotesPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let preferences: RecorderPreferences

    init(preferences: RecorderPreferences) {
        self.preferences = preferences
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if visible {
            let panel = self.panel ?? makePanel()
            self.panel = panel
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.title = "Speaker Notes"
        panel.contentView = NSHostingView(rootView: SpeakerNotesView(preferences: preferences))
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Readable over a full-screen app and on every Space, like the bar.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.minSize = NSSize(width: 240, height: 140)
        panel.setFrameAutosaveName("SpeakerNotes")
        if !panel.setFrameUsingName("SpeakerNotes") {
            // Top right of the screen the pointer is on: away from the bar at the bottom,
            // and near where a camera usually is, so reading it looks like looking up.
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - 24))
            }
        }
        panel.delegate = self
        return panel
    }

    /// Closing the window is turning the notes off, so the menus' tick agrees with it.
    func windowWillClose(_ notification: Notification) {
        preferences.showsSpeakerNotes = false
    }
}

private struct SpeakerNotesView: View {
    @Bindable var preferences: RecorderPreferences

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Only you can see these. They are never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    preferences.notesFontSize = max(RecorderPreferences.notesFontSizes.lowerBound, preferences.notesFontSize - 2)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Smaller text")
                .disabled(preferences.notesFontSize <= RecorderPreferences.notesFontSizes.lowerBound)
                Button {
                    preferences.notesFontSize = min(RecorderPreferences.notesFontSizes.upperBound, preferences.notesFontSize + 2)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Larger text")
                .disabled(preferences.notesFontSize >= RecorderPreferences.notesFontSizes.upperBound)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $preferences.speakerNotes)
                    .font(.system(size: preferences.notesFontSize))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if preferences.speakerNotes.isEmpty {
                    Text("Type or paste what you want to say.")
                        .font(.system(size: preferences.notesFontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 240, minHeight: 140)
        .background(.background)
    }
}
