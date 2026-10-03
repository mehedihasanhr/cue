import CoreMedia
import RecordKit
import SwiftUI
import TimelineKit

/// The editor's menu bar.
///
/// Shortcuts used to live as `.keyboardShortcut` on buttons, where nothing lists them
/// and nothing says what they will do — and where ⌘Z simply did not exist, because there
/// was no button to hang it on. Real menu items fix all of that.
///
/// Which editor they act on comes from `EditorWindows` rather than from `@FocusedValue`.
/// The focused-value route reads the front *scene*, and the editor is no longer a scene —
/// it is an `NSWindow` this app owns, which knows when it becomes main and says so. That
/// is a fact rather than an inference, and it is the same object the recorder bar asks
/// whether any editor is open.
///
/// Every shortcut comes from `shortcuts` rather than being written here, so Settings can
/// change it: `EditorCommand.defaultShortcut` holds the keys these items always had, and
/// the comments below still say why each was chosen. Reading it inside `body` is what makes
/// a change reach the menu bar at once — SwiftUI rebuilds the menus when what they read
/// changes, exactly as it does for an item's title or enabled state.
struct EditorCommands: SwiftUI.Commands {
    let windows: EditorWindows
    let shortcuts: EditorShortcutPreferences

    private var editor: EditorModel? { windows.front?.model }

    /// In the order of the tool rail, so a command is found where its tool is: the
    /// frame and its masks, then what happens over time, then playback.
    ///
    /// The editor's own menu only while there is an editor. With just the recorder bar
    /// up — or nothing at all, mid-take — a menu bar of Frame, Mask, Zoom and seven more,
    /// every item dimmed, was a wall of things that could not be done.
    var body: some SwiftUI.Commands {
        file
        edit
        if editor != nil {
            view
            // One menu for the editor, a submenu per tool, rather than eight across the
            // menu bar: the bar stays the app's own, and every item keeps its shortcut and
            // its place in the Command Menu, which walks into submenus.
            CommandMenu("Editor") {
                frameAndMasks
                zoom
                audio
                captions
                keyboard
                camera
                playback
            }
        }
    }

    // MARK: - File

    @CommandsBuilder
    private var file: some SwiftUI.Commands {
        CommandGroup(replacing: .saveItem) {
            // In the menu bar as well as on the toolbar, which is where ⌘S is looked for —
            // and where it works whatever has the keyboard. On the button alone it was a
            // shortcut that stopped answering whenever the toolbar was not in the key
            // window's view.
            Button("Save") { editor?.save() }
                .editorShortcut(.save, shortcuts)
                .disabled(editor?.isDirty != true && editor?.isUnsaved != true)
            Button("Save As…") { windows.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Divider()
            Button("Export…") {
                windows.front?.exportsSelection = false
                windows.front?.isExporting = true
            }
            .editorShortcut(.export, shortcuts)
            .disabled(editor == nil)
            // The same sheet, opened on the selected stretch. Only when there is one:
            // exporting "the selection" of an edit with nothing selected has no meaning
            // the sheet could offer.
            Button("Export Selection…") {
                windows.front?.exportsSelection = true
                windows.front?.isExporting = true
            }
            .editorShortcut(.exportSelection, shortcuts)
            .disabled(editor?.selectedRange == nil)
            .help(editor?.selectedRange == nil
                  ? "Mark a stretch of the timeline first — I and O set its start and end at the playhead."
                  : "Export only the selected stretch of the timeline.")
            Divider()
            Button("Save Frame As…") { editor?.saveFrameAs() }
                .editorShortcut(.saveFrame, shortcuts)
                .disabled(editor == nil)
            Divider()
            mediaItems
            Divider()
            chapterItems
        }
    }

    // MARK: - Edit

    @CommandsBuilder
    private var edit: some SwiftUI.Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(editor?.document.undoName.map { "Undo \($0)" } ?? "Undo") { editor?.undo() }
                .editorShortcut(.undo, shortcuts)
                .disabled(editor?.document.canUndo != true)
            Button(editor?.document.redoName.map { "Redo \($0)" } ?? "Redo") { editor?.redo() }
                .editorShortcut(.redo, shortcuts)
                .disabled(editor?.document.canRedo != true)
        }

        CommandGroup(after: .pasteboard) {
            // Named for what they act on, and placed *after* the system's Cut/Copy/Paste
            // rather than replacing them — both deliberate, and for the same reason.
            //
            // The editor has real text fields in it: a caption's words, an annotation's
            // label. ⌘C in one of those must copy text, and replacing the pasteboard group
            // would have taken that away. Sitting after it means AppKit offers the
            // responder chain the shortcut first, so a focused text field wins; with no
            // text responder the system's items are disabled and ours are reached instead.
            //
            // Every one of them is qualified, because the system's group is still above
            // them and one Edit menu must not list the same word twice. "Delete" and
            // "Select All" used to, each directly under the system's own.
            Button("Cut Selection") { editor?.cutSelection() }
                .editorShortcut(.cutSelection, shortcuts)
                .disabled(editor?.canCopySelection != true)
            Button("Copy Selection") { editor?.copySelection() }
                .editorShortcut(.copySelection, shortcuts)
                .disabled(editor?.canCopySelection != true)
            // The frame at the playhead, as the export would draw it. ⇧⌘C beside ⌘C;
            // ⌥⌘C is Add Caption's.
            Button("Copy Frame") { editor?.copyFrame() }
                .editorShortcut(.copyFrame, shortcuts)
                .disabled(editor == nil)
            Button("Paste at Playhead") { editor?.pasteAtPlayhead() }
                .editorShortcut(.paste, shortcuts)
                .disabled(editor?.canPasteRegion != true)
            Button("Duplicate") { editor?.duplicateSelection() }
                .editorShortcut(.duplicate, shortcuts)
                .disabled(editor?.canCopySelection != true)
            Button("Delete Selection") { editor?.deleteSelection() }
                .editorShortcut(.deleteSelection, shortcuts)
                .disabled(editor?.canDeleteSelection != true)
            Button("Select Whole Timeline") { editor?.selectAll() }
                .editorShortcut(.selectAll, shortcuts)
                .disabled(editor == nil)
            // A stretch marked from the playhead, with the keys every editor uses for it.
            // Plain letters, like Space and the arrows: a letter typed into a caption never
            // reaches a menu item, because the field is asked first — see `TypingGuard`.
            Button("Mark Selection Start") {
                guard !TypingGuard.consumed(shortcuts[.markStart]) else { return }
                editor?.markSelectionStart()
            }
            .editorShortcut(.markStart, shortcuts)
            .disabled(editor == nil)
            Button("Mark Selection End") {
                guard !TypingGuard.consumed(shortcuts[.markEnd]) else { return }
                editor?.markSelectionEnd()
            }
            .editorShortcut(.markEnd, shortcuts)
            .disabled(editor == nil)
            Divider()
            Button("Split at Playhead") { editor?.splitAtPlayhead() }
                .editorShortcut(.splitAtPlayhead, shortcuts)
                .disabled(editor == nil)
            markerSplit
            clipItems
            // Acts on the selected range when there is one and on a few seconds at the
            // playhead when there is not, which is why it is not disabled without a
            // selection — see `EditorModel.hidePointerOverSelection`.
            // No shortcut: ⌘⇧H is the note editor's Heading elsewhere in this app, and a
            // key that means two things depending on which window is front is worse than
            // one that means nothing.
            Button("Hide Pointer over Selection") { editor?.hidePointerOverSelection() }
                .disabled(editor == nil)
            Button("Spotlight Pointer over Selection") { editor?.spotlightPointerOverSelection() }
                .disabled(editor == nil)
            Button("Magnify Pointer over Selection") { editor?.magnifyPointerOverSelection() }
                .disabled(editor == nil)
            // The waiting in a recording — still stretches and typing — offered for
            // speeding up, one line at a time, in a sheet. See `PacingSheet`.
            Button("Speed Up Waiting…") { editor?.reviewPacing() }
                .editorShortcut(.speedUpWaiting, shortcuts)
                .disabled(editor?.canReviewPacing != true)
            Divider()
            // Every kind the inspector's + offers, reachable without the Annotate tool
            // being open — adding one opens it.
            Menu("Add Annotation") {
                ForEach(EditorModel.NewAnnotation.allCases) { kind in
                    Button(kind.menuTitle) { editor?.addAnnotation(kind) }
                }
                Divider()
                Button("Picture…") { editor?.addPicture(asLogo: false) }
                Button("Logo…") { editor?.addPicture(asLogo: true) }
            }
            .disabled(editor == nil)
        }
    }

    // MARK: - Zoom

    /// A menu of its own. These were eleven items in the middle of Edit, between Paste and
    /// Add Sound, which made Edit thirty lines long and the zoom commands something to be
    /// found rather than looked up.
    @ViewBuilder
    private var zoom: some View {
        Menu("Zoom") {
            Button("Add Zoom at Playhead") { editor?.addZoomAtPlayhead() }
                .editorShortcut(.addZoom, shortcuts)
                .disabled(editor == nil)
            Button("Auto-Zoom from Clicks and Focus") { editor?.suggestZooms() }
                .editorShortcut(.autoZoom, shortcuts)
                .disabled(editor == nil)
            Button("Remove All Zooms") { editor?.removeAllZooms() }
                .editorShortcut(.removeAllZooms, shortcuts)
                .disabled(editor?.hasRemovableZooms != true)
            Divider()
            // The second-pass verbs. They act on the selected zoom, or — with nothing
            // selected — on the one under the playhead, which is why they are enabled by
            // `activeZoom` rather than by the selection: somebody scrubbing to the moment a
            // push-in should become two has their hands on the playhead.
            //
            // ⌥⌘B beside Split at Playhead's ⌘B, because it is the same cut aimed at a
            // different lane. Merge and the rest take no key: they are not things done often
            // enough to be worth a shortcut somebody has to remember, and they are all in the
            // zoom inspector where the hand already is.
            Button("Split Zoom at Playhead") { editor?.splitZoomAtPlayhead() }
                .editorShortcut(.splitZoom, shortcuts)
                .disabled(editor?.canSplitZoom != true)
            Button("Merge Zoom with Next") { editor?.mergeZoomWithNext() }
                .editorShortcut(.mergeZoom, shortcuts)
                .disabled(editor?.zoomToMergeInto == nil)
            // Lengthens the zoom to touch the next, so the two glide. The reason it is off
            // is in the tooltip here and beside the button in the inspector.
            Button("Extend to Next Zoom") { editor?.extendZoomToNext() }
                .editorShortcut(.extendZoom, shortcuts)
                .disabled(editor?.canExtendZoomToNext != true)
                .help(editor?.extendToNextZoomReason
                      ?? "Make this zoom end exactly where the next one begins, so the camera glides from one to the other.")
            Divider()
            // Acts on every selected zoom, so a run of suggestions can be auditioned in one
            // press. ⌘⇧E because ⌘E is taken and this is the same idea as hiding a layer.
            Button(editor?.isActiveZoomEnabled == false ? "Turn Zoom On" : "Turn Zoom Off") {
                editor?.setZoomsEnabled()
            }
            .editorShortcut(.toggleZoom, shortcuts)
            .disabled(editor?.activeZoom == nil)
            Button(editor?.activeZoom?.isLocked == true ? "Unlock Zoom" : "Lock Zoom") {
                editor?.toggleZoomLock()
            }
            .editorShortcut(.lockZoom, shortcuts)
            .disabled(editor?.activeZoom == nil)
            // A cut instead of a movement, and back. One item that flips, like Lock above.
            Button(editor?.isActiveZoomInstant == true ? "Make Zoom Smooth" : "Make Zoom Instant") {
                editor?.toggleZoomInstant()
            }
            .editorShortcut(.instantZoom, shortcuts)
            .disabled(editor?.activeZoom == nil)
            Divider()
            Button("Frame Zoom on the Picture") { editor?.frameSelectedZoom() }
                .editorShortcut(.frameZoom, shortcuts)
                .disabled(editor?.activeZoom == nil)
            Button("Preview Zoom Result") { editor?.previewZoomResult() }
                .editorShortcut(.previewZoom, shortcuts)
                .disabled(editor?.activeZoom == nil)
            Button("Reset Zoom") { editor?.resetZoom() }
                .editorShortcut(.resetZoom, shortcuts)
                .disabled(editor?.activeZoom == nil)
            Divider()
            // For the whole project, so a ticked item rather than one that flips its name.
            Toggle("Glide Between Zooms That Are Close Together", isOn: Binding(
                get: { editor?.glidesBetweenZooms ?? false },
                set: { editor?.setGlidesBetweenZooms($0) }
            ))
            .disabled(editor == nil)
            Toggle("Motion Blur", isOn: Binding(
                get: { editor?.blursCameraMotion ?? false },
                set: { editor?.setZoomMotionBlur($0) }
            ))
            .disabled(editor == nil)
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audio: some View {
        Menu("Audio") {
            Button("Add Sound…") { editor?.addSound() }
                .editorShortcut(.addSound, shortcuts)
                .disabled(editor == nil)
            // ⇧⌘V, beside Add Sound…: the two are the same idea — sound laid over the
            // recording — and one of them is a file you already have while the other is
            // one you are about to make.
            Button(editor?.isRecordingVoiceover == true
                   ? "Stop Recording Voiceover" : "Record Voiceover…") { editor?.toggleVoiceover() }
                .editorShortcut(.voiceover, shortcuts)
                .disabled(editor == nil)
            Divider()
            Button(editor?.timeline.sound.isMuted == true
                   ? "Unmute the Recording" : "Mute the Recording") { editor?.toggleRecordedSound() }
                .editorShortcut(.muteRecording, shortcuts)
                .disabled(editor == nil)
            // One item that flips rather than two that can be pressed at the wrong time,
            // which is how Mute above reads too. Re-attaching asks first when it would
            // throw an edit away — see `EditorModel.requestSoundReattach`.
            Button(editor?.isSoundDetached == true ? "Re-attach Audio" : "Detach Audio") {
                guard let editor else { return }
                editor.isSoundDetached ? editor.requestSoundReattach() : editor.detachSound()
            }
            .editorShortcut(.detachAudio, shortcuts)
            .disabled(editor == nil)
            voiceFinish
        }
    }

    // MARK: - Captions

    /// The caption that the line commands act on: the one that is selected, or failing
    /// that the one on screen at the playhead — which is the one being looked at.
    private var caption: CaptionCue? {
        guard let editor else { return nil }
        if case .caption(let id) = editor.selection,
           let chosen = editor.timeline.captions.first(where: { $0.id == id }) {
            return chosen
        }
        return editor.captionAtPlayhead
    }

    @ViewBuilder
    private var captions: some View {
        Menu("Captions") {
            Button(editor?.timeline.captions.isEmpty == false ? "Listen Again" : "Generate Captions") {
                editor?.generateCaptions()
            }
            .editorShortcut(.generateCaptions, shortcuts)
            .disabled(editor == nil || editor?.isGeneratingCaptions == true)
            Button("Add Caption at Playhead") { editor?.addCaptionAtPlayhead() }
                .editorShortcut(.addCaption, shortcuts)
                .disabled(editor == nil)
            Divider()
            Button("Split Caption at Playhead") {
                if let caption { editor?.splitCaptionAtPlayhead(caption.id) }
            }
            .editorShortcut(.splitCaption, shortcuts)
            .disabled(caption.map { editor?.canSplitCaption($0) != true } ?? true)
            Button("Join Caption to Next") {
                if let caption { editor?.mergeCaptionWithNext(caption.id) }
            }
            .editorShortcut(.joinCaption, shortcuts)
            .disabled(caption.map { editor?.captionAfter($0.id) == nil } ?? true)
            Divider()
            Button("Remove Filler Words") { editor?.removeFillerWords() }
                .editorShortcut(.removeFillers, shortcuts)
                .disabled(editor?.fillerRanges.isEmpty != false)
            Button("Shorten Pauses Over a Second") { editor?.shortenPauses(longerThan: 1) }
                .disabled(editor?.pauseRanges(longerThan: 1).isEmpty != false)
            // The words picked in the transcript; Delete does the same while they are.
            Button("Cut Picked Words from Video") { editor?.cutPickedWords() }
                .disabled(editor?.canCutWords != true)
            Divider()
            Button(editor?.timeline.captionStyle.isVisible == false ? "Show Captions" : "Hide Captions") {
                editor?.toggleCaptions()
            }
            .editorShortcut(.toggleCaptions, shortcuts)
            .disabled(editor?.timeline.captions.isEmpty != false)
            Button("Translate Captions…") { editor?.isTranslatingCaptions = true }
                .disabled(editor?.timeline.captions.isEmpty != false)
            Divider()
            subtitleImportItem
            ForEach(CaptionExport.Format.allCases, id: \.self) { format in
                Button("Export as \(format.title)…") { editor?.exportCaptions(as: format) }
                    .disabled(editor?.timeline.captions.isEmpty != false)
            }
            Divider()
            Button("Remove All Captions") { editor?.clearCaptions() }
                .disabled(editor?.timeline.captions.isEmpty != false)
        }
    }

    // MARK: - Playback

    @ViewBuilder
    private var playback: some View {
        Menu("Playback") {
            Button(editor?.isPlaying == true ? "Pause" : "Play") { editor?.togglePlayback() }
                .editorShortcut(.playPause, shortcuts)
                .disabled(editor == nil)
            // J, K, L. Plain letters, as Space is: a letter typed into a caption or a label
            // never reaches these, because the field is asked before the menu — and should
            // one ever get here anyway, `TypingGuard` hands it back to the field.
            Button("Play Backward") {
                guard !TypingGuard.consumed(shortcuts[.playBackward]) else { return }
                editor?.shuttle(.backward)
            }
            .editorShortcut(.playBackward, shortcuts)
            .disabled(editor == nil || editor?.isRecordingVoiceover == true)
            Button("Stop") {
                guard !TypingGuard.consumed(shortcuts[.stopShuttle]) else { return }
                editor?.shuttle(.stop)
            }
            .editorShortcut(.stopShuttle, shortcuts)
            .disabled(editor == nil)
            Button("Play Forward") {
                guard !TypingGuard.consumed(shortcuts[.playForward]) else { return }
                editor?.shuttle(.forward)
            }
            .editorShortcut(.playForward, shortcuts)
            .disabled(editor == nil || editor?.isRecordingVoiceover == true)
            Divider()
            Button("Previous Frame") { editor?.stepFrame(forward: false) }
                .editorShortcut(.previousFrame, shortcuts)
                .disabled(editor == nil)
            Button("Next Frame") { editor?.stepFrame(forward: true) }
                .editorShortcut(.nextFrame, shortcuts)
                .disabled(editor == nil)
            Button("Back a Second") { editor?.step(-1) }
                .editorShortcut(.backSecond, shortcuts)
                .disabled(editor == nil)
            Button("Forward a Second") { editor?.step(1) }
                .editorShortcut(.forwardSecond, shortcuts)
                .disabled(editor == nil)
            Button("Previous Cut") { editor?.stepToBoundary(forward: false) }
                .editorShortcut(.previousCut, shortcuts)
                .disabled(editor == nil)
            Button("Next Cut") { editor?.stepToBoundary(forward: true) }
                .editorShortcut(.nextCut, shortcuts)
                .disabled(editor == nil)
            markerNavigation
            Divider()
            Button("Go to Start") { editor?.scrub(to: .zero) }
                .editorShortcut(.goToStart, shortcuts)
                .disabled(editor == nil)
            Button("Go to End") { editor?.scrub(to: editor?.duration ?? .zero) }
                .editorShortcut(.goToEnd, shortcuts)
                .disabled(editor == nil)
        }
    }

    // MARK: - View

    @CommandsBuilder
    private var view: some SwiftUI.Commands {
        CommandGroup(after: .sidebar) {
            // The inspector's switch, the same one as at the right end of the title bar.
            // A fixed ⌥⌘I rather than a rebindable command: it is the key Keynote, Pages
            // and Numbers give Show Inspector, and no editor command has it by default.
            Button(windows.front?.showsInspector == false ? "Show Inspector" : "Hide Inspector") {
                windows.front?.showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(windows.front == nil)
            // The edit with the screen to itself. Fixed, like the inspector's: ⇧⌘F is
            // what QuickTime and Final Cut use for full-screen playback.
            Button(windows.front?.isPresenting == true ? "Exit Full Screen Preview" : "Full Screen Preview") {
                guard let front = windows.front else { return }
                front.present(!front.isPresenting)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(editor == nil)
            Divider()
            // The nine tools, which the tabs' tips have always said were in the menu bar.
            // The shortcut lives here and not on the tabs, so it answers whatever has the
            // keyboard. Choosing one brings a hidden inspector back — see
            // `EditorModel.toolRequests` — because asking for a tool is asking to see it.
            ForEach(EditorTool.allCases) { tool in
                Button(tool.title) { editor?.choose(tool) }
                    .editorShortcut(tool.command, shortcuts)
                    .disabled(editor == nil || !tool.isAvailable)
            }
            Divider()
            Button("Zoom Timeline In") {
                guard let editor else { return }
                editor.viewport.zoom(by: 2, anchoring: editor.playhead, duration: editor.duration)
            }
            .editorShortcut(.zoomTimelineIn, shortcuts)
            .disabled(editor == nil)
            Button("Zoom Timeline Out") {
                guard let editor else { return }
                editor.viewport.zoom(by: 0.5, anchoring: editor.playhead, duration: editor.duration)
            }
            .editorShortcut(.zoomTimelineOut, shortcuts)
            .disabled(editor == nil)
            Button("Fit Timeline") {
                guard let editor else { return }
                editor.viewport.fit(editor.duration)
            }
            .editorShortcut(.fitTimeline, shortcuts)
            .disabled(editor == nil)
            Divider()
            // Guides over the preview for vertical video, never exported. See
            // `SafeZoneOverlay`, which also says when the frame is not 9 : 16.
            Toggle("Show Safe Zones", isOn: Binding(
                get: { SafeZonePreference.shared.isShown },
                set: { SafeZonePreference.shared.isShown = $0 }
            ))
            Picker("Safe Zones For", selection: Binding(
                get: { SafeZonePreference.shared.platform },
                set: {
                    SafeZonePreference.shared.platform = $0
                    SafeZonePreference.shared.isShown = true
                }
            )) {
                ForEach(SafeZonePlatform.allCases) { platform in
                    Text(platform.title).tag(platform)
                }
            }
        }
    }
}
