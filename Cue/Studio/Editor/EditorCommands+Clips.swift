import RecordKit
import SwiftUI
import TimelineKit

/// The Edit menu's clip items: freeze frames, title slides, moving a clip, and the
/// transition into it.
///
/// In a file of their own so the Edit menu reads as a list of groups, and beside Split at
/// Playhead in it, because they are all things done to the footage lane.
extension EditorCommands {
    private var clipEditor: EditorModel? { windows.menuTarget?.model }

    @ViewBuilder
    var clipItems: some View {
        // ⌥⌘F: F for freeze. ⌘F is Find everywhere else on the Mac, and nothing here
        // searches, but taking it would be one more surprise than this needs.
        Button("Freeze Frame at Playhead") { clipEditor?.freezeFrameAtPlayhead() }
            .editorShortcut(.freezeFrame, shortcuts)
            .disabled(clipEditor?.canFreezeFrame != true)
            .help(clipEditor?.freezeFrameReason
                  ?? "Hold the frame under the playhead for two seconds, silently.")
        Menu("Add Title Slide") {
            ForEach(EditorModel.TitlePlace.allCases) { place in
                Button(place.menuTitle) { clipEditor?.addTitle(at: place) }
            }
        }
        .disabled(clipEditor == nil)
        // ⌥⌘← and ⌥⌘→, the arrows the clip goes along. Plain ⌥ and the arrows are the
        // playhead's, to the previous and next cut.
        Button("Apply Speed to All Clips") { clipEditor?.applySpeedToAll() }
            .disabled(!(clipEditor?.canApplySpeedToAll ?? false))
        Button("Move Clip Earlier") { clipEditor?.moveSelectedClip(by: -1) }
            .editorShortcut(.moveClipEarlier, shortcuts)
            .disabled(clipEditor?.canMoveSelectedClip(by: -1) != true)
            .help(clipEditor?.selectedClip == nil
                  ? "Select a clip on the timeline first."
                  : "Swap this clip with the one before it. What is placed on it goes with it.")
        Button("Move Clip Later") { clipEditor?.moveSelectedClip(by: 1) }
            .editorShortcut(.moveClipLater, shortcuts)
            .disabled(clipEditor?.canMoveSelectedClip(by: 1) != true)
            .help(clipEditor?.selectedClip == nil
                  ? "Select a clip on the timeline first."
                  : "Swap this clip with the one after it. What is placed on it goes with it.")
        Menu("Transition into Clip") {
            transitionChoices
        }
        .disabled(clipEditor?.selectedClipCanHaveTransition != true)
        .help(clipEditor?.selectedClip == nil
              ? "Select a clip on the timeline first."
              : "How the selected clip arrives from the one before it.")
    }

    /// One item per kind of cut, with the one in force ticked.
    @ViewBuilder
    private var transitionChoices: some View {
        let current = clipEditor?.selectedClip?.clip.transition?.style
        Toggle("None", isOn: Binding(
            get: { current == nil },
            set: { _ in
                guard let clip = clipEditor?.selectedClip?.clip else { return }
                clipEditor?.setTransitionStyle(clip.id, nil)
            }
        ))
        ForEach(ClipTransition.Style.allCases, id: \.self) { style in
            Toggle(style.title, isOn: Binding(
                get: { current == style },
                set: { _ in
                    guard let clip = clipEditor?.selectedClip?.clip else { return }
                    clipEditor?.setTransitionStyle(clip.id, style)
                }
            ))
        }
    }
}
