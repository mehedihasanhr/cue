import RecordKit
import SwiftUI
import TimelineKit

/// The shortcuts as a whole: how they are drawn, and the list of them.
struct KeyboardInspector: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            if model.timeline.keyCues.isEmpty {
                empty
            } else {
                appearance
                list
            }
        }
        .font(.system(size: 12))
    }

    // MARK: - Nothing yet

    /// Why the lane is empty, which depends on what the recorder was told — and then
    /// the two ways to get something on it.
    private var empty: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Text(reason)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.keyCapture == nil {
                SettingsLink {
                    Text("Open Settings…")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("The switch is under Recording")
            } else if model.keyCapture == .notPermitted {
                Button {
                    AccessibilityAccess.openSystemSettings()
                } label: {
                    Text("Open System Settings")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            } else if model.hasRecordedKeys {
                Button {
                    model.restoreRecordedKeys()
                } label: {
                    Label("Restore Recorded Shortcuts", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Put back the shortcuts the recorder saw")
            }

            Text("Or add one by hand, starting where the playhead is.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            addOne
        }
        .inspectorSection("Shortcuts", systemImage: "keyboard")
    }

    private var reason: String {
        switch model.keyCapture {
        case .some(.recorded):
            "No shortcuts were pressed during this recording — or they have all been removed."
        case .some(.notPermitted):
            "Shortcuts were switched on for this recording, but Klik Studio didn't have Accessibility access, so none were recorded. Turn Klik Studio on under Privacy & Security › Accessibility and they will be recorded next time."
        case .some:
            "This recording's keyboard data is in a form this version doesn't read."
        case .none:
            "Shortcuts weren't recorded for this take. To have them next time, turn on “Record keyboard shortcuts” under Settings › Recording. Only shortcuts are kept — typed text never is."
        }
    }

    private var addOne: some View {
        Button {
            model.addKeyCueAtPlayhead()
        } label: {
            Label("Add Shortcut at Playhead", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .help("A shortcut to type into, starting at the playhead (⌥⌘K)")
    }

    // MARK: - How they look

    private var appearance: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Show keys in the video", isOn: style.binding(\.keyStyle.isVisible, "Keys"))

            Group {
                InspectorField(title: "Position") {
                    InspectorPicker(selection: style.binding(\.keyStyle.position, "Key Position"),
                                    options: KeyStyle.Position.allCases,
                                    title: \.title)
                }
                InspectorField(title: "Look") {
                    InspectorPicker(selection: style.binding(\.keyStyle.look, "Key Look"),
                                    options: KeyStyle.Look.allCases,
                                    title: \.title)
                }
                InspectorSlider(model: model, "Size", systemImage: "textformat.size",
                                value: style.binding(\.keyStyle.size, "Key Size"),
                                range: KeyStyle.sizeRange)
                Toggle("Show Return, arrows and the like pressed alone",
                       isOn: style.binding(\.keyStyle.showsNamedKeysAlone, "Lone Keys"))
                Text("Off, every line break and every step through a list would put a key on screen. Shortcuts with ⌘, ⌃ or ⌥ are always shown.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The switch itself stays live: it is the way back.
            .disabled(!model.timeline.keyStyle.isVisible)
        }
        .inspectorSection("Appearance", systemImage: "keyboard")
    }

    // MARK: - Which ones

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.timeline.keyCues) { cue in
                row(cue)
            }
            addOne
                .padding(.top, 4)
            if model.hasRecordedKeys {
                Button("Restore Recorded Shortcuts") { model.restoreRecordedKeys() }
                    .controlSize(.small)
                    .help("Put the lane back to what the recorder saw, replacing what is there. Undo brings the edit back.")
            }
        }
        .inspectorSection("Shortcuts", systemImage: "list.bullet") {
            SectionButton(title: "Clear") { model.removeAllKeyCues() }
                .help("Remove every shortcut")
        }
    }

    /// One press, with the playhead's marked. Clicking its time goes there and selects
    /// it, which is how a press gets retimed or corrected.
    private func row(_ cue: KeyCue) -> some View {
        let isCurrent = model.keyCueAtPlayhead?.id == cue.id
        let isShown = model.timeline.isShown(cue)
        return HStack(spacing: 8) {
            Button {
                model.scrub(to: cue.start)
                model.select(.keyCue(cue.id))
            } label: {
                Text(Timecode.short(cue.start))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .frame(width: 48, alignment: .leading)
            .help("Go to this shortcut")

            Text(cue.isEmpty ? "Empty shortcut" : cue.title)
                .font(.system(size: 11, weight: .medium))
                .opacity(isShown ? 1 : 0.5)
            Spacer(minLength: 0)
            if !isShown {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(cue.isHidden ? "Hidden" : "Not drawn — see the Appearance section")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
