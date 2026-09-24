import SwiftUI

/// The strip of tools down the left edge of the editor.
///
/// Selecting one decides what the inspector shows, and — for a canvas tool like crop —
/// what the preview is drawing. The selection lives on `EditorModel` rather than here,
/// because entering crop mode changes the rendered frame: that is behaviour, not chrome.
struct ToolRail: View {
    let model: EditorModel
    @Namespace private var chip

    var body: some View {
        VStack(spacing: 6) {
            ForEach(EditorTool.rail) { tool in
                tile(tool)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor tools")
    }

    private func tile(_ tool: EditorTool) -> some View {
        let isSelected = model.tool == tool

        return Button {
            model.tool = tool
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .foregroundStyle(tool.isAvailable
                    ? (isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    : AnyShapeStyle(.tertiary))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                            .matchedGeometryEffect(id: "tool", in: chip)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!tool.isAvailable)
        .keyboardShortcut(tool.shortcut, modifiers: .command)
        .animation(StudioMotion.selection, value: model.tool)
        .help(tool.unavailableReason ?? tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.unavailableReason ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
