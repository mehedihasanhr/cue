import AppKit
import RecordKit
import SwiftUI

/// The column of tool tabs, on the inside edge of the settings at the right of the window.
///
/// Beside the settings rather than at the other end of the window, so a tab and what it
/// opened are side by side. It stays when the settings are hidden: a tab is then the way
/// to bring them back. The things about the app rather than the edit — the Finder, the
/// command menu, settings — are in the title bar.
///
/// The selection still lives on `EditorModel` rather than here, because entering crop mode
/// changes the rendered frame: that is behaviour, not chrome.
struct EditorRail: View {
    let model: EditorModel
    @Environment(StudioSettings.self) private var settings
    @Namespace private var highlight

    static let width: CGFloat = SidebarMetrics.railWidth

    /// The tools in the order of their shortcuts, cut into what they work on: the
    /// picture's frame, things drawn over it, what was recorded with it, and the words and
    /// sound that go with it.
    static let groups: [(name: String, tools: [VideoEditorTool])] = [
        ("Picture", [.frame, .crop]),
        ("Overlays", [.blur, .annotate]),
        ("Recorded", [.cursor, .webcam]),
        ("Words & sound", [.captions, .audio, .keyboard]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Scrolls only if it must. Nine tabs are taller than the rail at the window's
            // smallest, and a rail whose last tool is clipped off is a tool that does not
            // exist.
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { rule }
                        VStack(spacing: 2) {
                            ForEach(group.tools) { tool in
                                StudioIconTab(systemImage: tool.symbol,
                                              title: tool.title,
                                              help: help(for: tool, in: group.name),
                                              isSelected: model.tool == tool,
                                              isAvailable: tool.isAvailable,
                                              namespace: highlight) {
                                    model.choose(tool)
                                }
                                .accessibilityHint(tool.unavailableReason ?? "")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(group.name)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // On the window's ground rather than a panel of its own: the tabs are the edge of
        // the settings card beside them, not a third column.
        .background(StudioTheme.Surface.seam)
        .animation(StudioMotion.selection, value: model.tool)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor tools")
    }

    private var rule: some View {
        Rectangle()
            .fill(StudioTheme.Surface.hairline)
            .frame(width: 18, height: 1)
    }

    /// The shortcut is on the tip because the rail is where somebody looks for it: the menu
    /// bar has the same commands (View lists the nine tools, and answers whatever has the
    /// keyboard, so the shortcut is not registered twice here), and nobody finds them there
    /// twice. The shortcut as it is set now, which Settings can change, or none.
    private func help(for tool: VideoEditorTool, in group: String) -> String {
        tool.unavailableReason
            ?? settings.editorShortcuts[tool.command].map { "\(group): \(tool.title) (\($0.displayString))" }
            ?? "\(group): \(tool.title)"
    }
}
