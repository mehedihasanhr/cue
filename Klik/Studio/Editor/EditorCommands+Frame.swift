import SwiftUI
import TimelineKit

/// The Frame menu — looks and the shape — and the Mask menu.
///
/// Every one of these is also on a panel or a tile; they are here so each can be reached
/// by name, whatever has the keyboard and whichever panel is showing. The checked items
/// are `Toggle`s rather than buttons with a tick drawn on, because that is what the menu
/// bar draws as a tick.
extension EditorCommands {
    private var front: EditorModel? { windows.menuTarget?.model }
    private var library: LookLibrary { .shared }

    @ViewBuilder
    var frameAndMasks: some View {
        Menu("Frame") {
            Button("Save Look…") {
                // The name is asked for on the Frame panel, in the row the tiles are
                // in, so the panel comes forward with it.
                front?.choose(.frame)
                library.request = .save
            }
            .disabled(front == nil)
            Button("Import Look…") {
                guard let front else { return }
                do {
                    try library.importLooks()
                } catch {
                    front.report(error)
                }
            }
            .disabled(front == nil)
            Menu("Apply Look") {
                ForEach(library.builtIn, id: \.name) { look in
                    applyItem(look)
                }
                Divider()
                if library.saved.isEmpty {
                    Text("No Saved Looks")
                } else {
                    ForEach(library.saved) { saved in
                        applyItem(saved.look)
                    }
                }
            }
            .disabled(front == nil)
            // The default for new recordings is a setting, so this is enabled whenever
            // there is an editor to have come from.
            Menu("Use for New Recordings") {
                ForEach(library.builtIn, id: \.name) { look in
                    defaultItem(look)
                }
                Divider()
                if library.saved.isEmpty {
                    Text("No Saved Looks")
                } else {
                    ForEach(library.saved) { saved in
                        defaultItem(saved.look)
                    }
                }
            }
            .disabled(front?.settings == nil)
            Menu("Saved Looks") {
                if library.saved.isEmpty {
                    Text("No Saved Looks")
                } else {
                    ForEach(library.saved) { saved in
                        Menu(saved.name) {
                            Button("Rename…") {
                                front?.choose(.frame)
                                library.request = .rename(saved)
                            }
                            Button("Delete") { delete(saved) }
                            Button("Show in Finder") { library.reveal(saved) }
                        }
                    }
                }
            }
            .disabled(front == nil)
            Divider()
            Menu("Shape") {
                ForEach(AspectPreset.menuOrder, id: \.self) { preset in
                    Toggle(preset.displayName, isOn: Binding(
                        get: { front?.timeline.style.aspect == preset },
                        set: { chosen in
                            guard chosen else { return }
                            front?.apply(Commands.Restyle("Shape") { $0.style.aspect = preset })
                        }
                    ))
                }
            }
            .disabled(front == nil)
            Menu("Window Frame") {
                ForEach(WindowChrome.Kind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { front?.windowChrome.kind == kind },
                        set: { chosen in if chosen { front?.setWindowChrome(kind) } }
                    ))
                }
                Divider()
                // Ticked for dark, unticked for light: two states, one item.
                Toggle("Dark Window", isOn: Binding(
                    get: { front?.windowChrome.appearance == .dark },
                    set: { front?.setWindowAppearance($0 ? .dark : .light) }
                ))
                .disabled(front?.windowChrome.isVisible != true || front?.windowChrome.kind.isDevice == true)
            }
            .disabled(front == nil)
            Menu("Perspective") {
                ForEach(FramePerspective.Preset.allCases) { preset in
                    Toggle(preset.title, isOn: Binding(
                        get: { front?.perspective.preset == preset },
                        set: { chosen in if chosen { front?.applyPerspectivePreset(preset) } }
                    ))
                }
                Divider()
                Toggle("Straighten While Zoomed In", isOn: Binding(
                    get: { front?.perspective.straightensWhenZoomed ?? false },
                    set: { front?.setStraightensWhenZoomed($0) }
                ))
            }
            .disabled(front == nil)
            Menu("Colour") {
                ForEach(ColorGrade.Preset.allCases) { preset in
                    Toggle(preset.title, isOn: Binding(
                        get: { front?.colorGrade.preset == preset },
                        set: { chosen in if chosen { front?.applyColorPreset(preset) } }
                    ))
                }
                Divider()
                Button("Load LUT…") { front?.loadLUT() }
                Button("Remove LUT") { front?.removeLUT() }
                    .disabled(front?.colorGrade.lut == nil)
            }
            .disabled(front == nil)
            Menu("Moving Background") {
                ForEach(AnimatedBackground.Kind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { front?.hasMovingBackground == true && front?.timeline.style.background.editableAnimation.kind == kind },
                        set: { chosen in
                            guard chosen, let front else { return }
                            var changed = front.timeline.style.background.editableAnimation
                            changed.kind = kind
                            front.setAnimatedBackground(changed)
                        }
                    ))
                }
                Divider()
                Button("Background Video…") { front?.chooseBackgroundVideo() }
            }
            .disabled(front == nil)
            // Unticking it puts back the default background rather than whatever was there
            // before, which the menu cannot know; ⌘Z is the way back to that.
            Toggle("Transparent Background", isOn: Binding(
                get: { front?.hasTransparentBackground ?? false },
                set: { isOn in
                    if isOn {
                        front?.makeBackgroundTransparent()
                    } else {
                        let background = BackgroundPreset.indigo.background
                        front?.apply(Commands.Restyle("Background") { $0.style.background = background })
                    }
                }
            ))
            .disabled(front == nil)
        }

        Menu("Mask") {
            ForEach(BlurRegion.Style.allCases, id: \.self) { style in
                Button("Add \(style.title) at Playhead") { front?.addMask(style) }
                    .disabled(front == nil)
            }
            Divider()
            // What the selected mask is. Disabled without one, and the panel's heading
            // says what to select.
            Menu("Kind") {
                ForEach(BlurRegion.Style.allCases, id: \.self) { style in
                    Toggle(style.title, isOn: Binding(
                        get: { front?.selectedMask?.style == style },
                        set: { chosen in if chosen { front?.setMaskStyle(style) } }
                    ))
                }
            }
            .disabled(front?.selectedMask == nil)
            Divider()
            // Following the selected mask's content. The panel says why when these are
            // grey; a menu item has nowhere to say it.
            Button("Follow Content") { front?.followSelectedMask() }
                .disabled(front?.canFollowSelectedMask != true)
            Button("Cancel Following") { front?.cancelFollowing() }
                .disabled(front?.following.isRunning != true)
            Button("Stop Following") { front?.stopFollowingSelectedMask() }
                .disabled(front?.selectedMask?.follows != true)
            Button("Split Mask at Playhead") { front?.splitMaskAtPlayhead() }
                .disabled(front?.canSplitMask != true)
            Divider()
            // Reads the whole recording's text and offers what it finds in a sheet. See
            // `SensitiveSheet`.
            Button("Find Sensitive Information…") { front?.findSensitiveInformation() }
                .disabled(front?.canFindSensitiveInformation != true)
        }
    }

    /// One look in the Apply Look menu, ticked while the project is wearing it.
    private func applyItem(_ look: Look) -> some View {
        Toggle(look.name, isOn: Binding(
            get: { front?.isWearing(look) ?? false },
            set: { chosen in if chosen { front?.applyLook(look) } }
        ))
    }

    /// One look in the Use for New Recordings menu, ticked while it is the default.
    /// Unticking it is the only way to say "none".
    private func defaultItem(_ look: Look) -> some View {
        Toggle(look.name, isOn: Binding(
            get: { front?.settings?.isNewRecordingLook(look) ?? false },
            set: { chosen in
                guard let settings = front?.settings else { return }
                if chosen { settings.useForNewRecordings(look) } else { settings.clearNewRecordingLook() }
            }
        ))
    }

    private func delete(_ saved: SavedLook) {
        do {
            try library.delete(saved)
            if case .rename(let naming) = library.request, naming == saved { library.request = nil }
        } catch {
            front?.report(error)
        }
    }
}
