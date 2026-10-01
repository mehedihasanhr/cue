import RecordKit
import SwiftUI

/// The row of tool tabs across the top of the inspector.
///
/// It used to be a rail down the far left of the window, with the panel it drove beside
/// it and the picture between the panel and everything else. Now the panel is on the
/// right, the way an inspector is in Final Cut, Xcode or Keynote, and the tools are the
/// tabs on top of it: the thing you choose and the controls it opens are one column, and
/// the picture is not split from the timeline by a strip of icons it has nothing to do
/// with.
///
/// The selection still lives on `EditorModel` rather than here, because entering crop
/// mode changes the rendered frame: that is behaviour, not chrome.
///
/// The tabs share the width evenly rather than each taking a fixed square. Nine fixed
/// squares left-aligned in a column that can be dragged wider leave a ragged gap at the
/// right end, which reads as a tenth tab that failed to load; spread across the column
/// they are one control, the same width as the panel underneath them.
struct ToolTabs: View {
    let model: EditorModel
    @Environment(StudioSettings.self) private var settings
    @Namespace private var chip

    /// How tall the row is. The same band as the panel's heading under it, so the two
    /// rows of chrome at the top of the column are one rhythm rather than two.
    static let height: CGFloat = SidebarMetrics.headerHeight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.rail) { tool in
                tab(tool)
            }
        }
        .padding(.horizontal, SidebarMetrics.contentInset - 4)
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor tools")
    }

    private func tab(_ tool: EditorTool) -> some View {
        let isSelected = model.tool == tool

        return Button {
            model.choose(tool)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .symbolVariant(isSelected ? .fill : .none)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .foregroundStyle(tool.isAvailable
                    ? (isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    : AnyShapeStyle(.tertiary))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                            .matchedGeometryEffect(id: "tool", in: chip)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!tool.isAvailable)
        // The shortcut itself is the menu bar's — View lists the nine tools — so it
        // answers whatever has the keyboard, and is not registered twice.
        .animation(StudioMotion.selection, value: model.tool)
        // The shortcut is on the tip because the tabs are where somebody looks for it:
        // the menu bar has the same commands, and nobody finds them there twice. The
        // shortcut as it is set now, which Settings can change, or none.
        .help(tool.unavailableReason
              ?? settings.editorShortcuts[tool.command].map { "\(tool.title) (\($0.displayString))" }
              ?? tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.unavailableReason ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
