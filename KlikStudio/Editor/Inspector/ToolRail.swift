import AppKit
import RecordKit
import SwiftUI

/// The column down the window's left edge: the app's mark, the tools, and the few things
/// that are about the app rather than the edit.
///
/// The full height of the window, beside the canvas and the timeline both, so it reads as
/// the spine of the editor rather than as part of the settings. A tool chosen here opens
/// its settings in the inspector at the other side; the rail itself only says which.
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
    static let groups: [(name: String, tools: [EditorTool])] = [
        ("Picture", [.frame, .crop]),
        ("Overlays", [.blur, .annotate]),
        ("Recorded", [.cursor, .webcam]),
        ("Words & sound", [.captions, .audio, .keyboard]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            mark
                .padding(.top, 10)
                .padding(.bottom, 12)

            rule

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

            rule
                .padding(.bottom, 10)
            VStack(spacing: 2) {
                utility("folder", "Show this recording in the Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.packageURL])
                }
                utility("command", "Command Menu") {
                    CommandMenuController.shared.toggle()
                }
                utility("gearshape", "Settings") {
                    StudioAppDelegate.openSettings()
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(StudioTheme.Surface.panel)
        .animation(StudioMotion.selection, value: model.tool)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor tools")
    }

    /// The app's own mark, at the head of the rail.
    private var mark: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 18, height: 1)
    }

    private func utility(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        StudioIconTab(systemImage: symbol,
                      title: title,
                      help: title,
                      isSelected: false,
                      namespace: highlight,
                      action: action)
    }

    /// The shortcut is on the tip because the rail is where somebody looks for it: the menu
    /// bar has the same commands (View lists the nine tools, and answers whatever has the
    /// keyboard, so the shortcut is not registered twice here), and nobody finds them there
    /// twice. The shortcut as it is set now, which Settings can change, or none.
    private func help(for tool: EditorTool, in group: String) -> String {
        tool.unavailableReason
            ?? settings.editorShortcuts[tool.command].map { "\(group): \(tool.title) (\($0.displayString))" }
            ?? "\(group): \(tool.title)"
    }
}
