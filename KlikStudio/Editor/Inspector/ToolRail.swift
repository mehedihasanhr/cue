import SwiftUI

/// The strip of tools down the left edge of the editor.
///
/// Selecting one decides what the panel beside it shows, and — for a canvas tool like
/// crop — what the preview is drawing. The selection lives on `EditorModel` rather than
/// here, because entering crop mode changes the rendered frame: that is behaviour, not
/// chrome.
///
/// The tools are grouped rather than listed, because eight identical glyphs in a line
/// is a list you have to read from the top every time. The groups are the four questions
/// this editor answers — what the frame looks like, what is hidden or called out on it,
/// what moves across it, and what you hear. A gap marks them rather than a rule: four
/// hairlines down a 52-point strip is more lines than icons, and the eye reads the
/// grouping from the space just as well.
struct ToolRail: View {
    let model: EditorModel
    @Namespace private var chip

    private static let groups: [[EditorTool]] = [
        [.frame, .crop],
        [.blur, .annotate],
        [.cursor, .webcam],
        [.captions, .audio],
        // What was pressed. Its own group: it is neither said nor heard, it is shown.
        [.keyboard],
    ]

    var body: some View {
        // Scrolling rather than clipping: the rail stands beside the preview only, and a
        // timeline that has grown a lane for blurs, annotations and imported sound can
        // take enough height on a small display to leave the last tool with nowhere to
        // be. It never scrolls at a usable window size — it simply refuses to lose Audio.
        VStack(spacing: 0) {
            // The sidebar's top band. The panel beside it puts its heading here; this
            // end of it carries the mark, so the column starts with the app rather than
            // with the first tool.
            mark
            rail
        }
        .frame(width: SidebarMetrics.railWidth)
        .studioSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor tools")
    }

    /// The Klik mark, from the host app's asset catalog — the same file, referenced
    /// rather than copied, so the add-on cannot end up wearing an older logo than the app
    /// it belongs to. Template artwork, so it takes the sidebar's own grey.
    private var mark: some View {
        Image("KlikMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .frame(height: SidebarMetrics.headerHeight)
            .accessibilityLabel("Klik Studio")
    }

    private var rail: some View {
        ScrollView(.vertical) {
            VStack(spacing: 14) {
                ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 4) {
                        ForEach(group) { tool in
                            tile(tool)
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func tile(_ tool: EditorTool) -> some View {
        let isSelected = model.tool == tool

        return Button {
            model.choose(tool)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                .symbolVariant(isSelected ? .fill : .none)
                .frame(width: 34, height: 30)
                .foregroundStyle(tool.isAvailable
                    ? (isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    : AnyShapeStyle(.tertiary))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                            .matchedGeometryEffect(id: "tool", in: chip)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!tool.isAvailable)
        // The shortcut itself is the menu bar's — View lists the eight tools — so it
        // answers whatever has the keyboard, and is not registered twice.
        .animation(StudioMotion.selection, value: model.tool)
        // The shortcut is on the tip because the rail is where somebody looks for it:
        // the menu bar has the same eight commands, and nobody finds them there twice.
        .help(tool.unavailableReason ?? "\(tool.title) (⌘\(tool.shortcut.character))")
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.unavailableReason ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
