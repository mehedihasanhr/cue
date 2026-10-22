import RenderKit
import SwiftUI

/// A row for choosing a family of type by name: the system's own, a few good ones, then
/// every family on this Mac.
///
/// A family the project names that this Mac does not have — a project made on another Mac —
/// stays chosen, since the next Mac to open it may have it, and the row says in words that
/// the system's type is being drawn instead. Changing nothing is not the same as losing it.
struct FontFamilyPicker: View {
    @Binding var family: String
    /// What the system's own type is called here: "System", or the caption's typeface.
    var systemTitle = "System"

    private var isMissing: Bool { !family.isEmpty && !FontFamilies.isInstalled(family) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorRow("Font") {
                // The kit's pop-up, like every other in the panel. The families on this Mac
                // were a submenu of the system's pull-down; the kit's list has no submenus,
                // so they are the last group under a heading of their own, and the list
                // scrolls. The field takes the chosen name's width, not the longest of
                // several hundred.
                StudioMenuPicker(selection: $family, sections: sections, sizesToLongest: false)
                    .help("The family the words are set in")
            }
            if isMissing {
                InspectorNote("Not on this Mac, so the system font is drawn instead.")
                    .help("\(family) isn't on this Mac, so the system font is drawn instead. A Mac that has it will draw it.")
            }
        }
    }

    private var sections: [StudioMenuSection<String>] {
        var sections = [
            StudioMenuSection(items: [StudioMenuItem("", title: systemTitle)]),
            StudioMenuSection(items: FontFamilies.curatedInstalled.map { StudioMenuItem($0, title: $0) })
        ]
        if isMissing {
            sections.append(StudioMenuSection(items: [StudioMenuItem(family, title: "\(family) (not on this Mac)")]))
        }
        sections.append(StudioMenuSection("All Fonts", items: InstalledFamilies.all.map { StudioMenuItem($0, title: $0) }))
        return sections
    }
}

/// The families on this Mac, asked for once: the list is several hundred names long and
/// every inspector redraw would otherwise ask the font manager again.
@MainActor
private enum InstalledFamilies {
    static let all = FontFamilies.installed
}
