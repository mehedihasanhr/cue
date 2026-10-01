import RecordKit
import SwiftUI

/// The column of tool tabs down the left edge of the inspector.
///
/// Between the picture and the settings it opens: the tools are the spine of the panel,
/// and the controls hang off them. As a row of tabs across the top of the panel the nine
/// glyphs were squeezed into whatever width the column had and sat above the heading that
/// named them, so the eye read tools, then name, then controls, top to bottom across three
/// bands. Down the side, a tool and the panel it opened are side by side, and the panel
/// gets its whole height back for controls.
///
/// The selection still lives on `EditorModel` rather than here, because entering crop mode
/// changes the rendered frame: that is behaviour, not chrome.
struct ToolRail: View {
    let model: EditorModel
    @Environment(StudioSettings.self) private var settings
    @Namespace private var highlight

    static let width: CGFloat = SidebarMetrics.railWidth

    var body: some View {
        // Scrolls only if it must. Nine tabs are taller than the picture's band at the
        // window's smallest, and a rail whose last tool is clipped off is a tool that does
        // not exist.
        ScrollView(.vertical) {
            VStack(spacing: StudioTheme.Spacing.tight) {
                ForEach(EditorTool.rail) { tool in
                    StudioIconTab(systemImage: tool.symbol,
                                  title: tool.title,
                                  help: help(for: tool),
                                  isSelected: model.tool == tool,
                                  isAvailable: tool.isAvailable,
                                  namespace: highlight) {
                        model.choose(tool)
                    }
                    .accessibilityHint(tool.unavailableReason ?? "")
                }
            }
            // The first tab's centre on the heading's centre beside it, so the chosen tool
            // and the name of what it opened read as one line across the column.
            .padding(.top, (SidebarMetrics.headerHeight - StudioIconTab.size) / 2)
            .padding(.bottom, StudioTheme.Spacing.regular)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(StudioMotion.selection, value: model.tool)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor tools")
    }

    /// The shortcut is on the tip because the rail is where somebody looks for it: the menu
    /// bar has the same commands (View lists the nine tools, and answers whatever has the
    /// keyboard, so the shortcut is not registered twice here), and nobody finds them there
    /// twice. The shortcut as it is set now, which Settings can change, or none.
    private func help(for tool: EditorTool) -> String {
        tool.unavailableReason
            ?? settings.editorShortcuts[tool.command].map { "\(tool.title) (\($0.displayString))" }
            ?? tool.title
    }
}
