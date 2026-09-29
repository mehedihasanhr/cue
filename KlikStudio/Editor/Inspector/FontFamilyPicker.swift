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

    @State private var isHovering = false

    private var isMissing: Bool { !family.isEmpty && !FontFamilies.isInstalled(family) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorField(title: "Font") {
                Menu {
                    choice("", title: systemTitle)
                    Divider()
                    ForEach(FontFamilies.curatedInstalled, id: \.self) { name in
                        choice(name, title: name)
                    }
                    if isMissing {
                        Divider()
                        choice(family, title: "\(family) (not on this Mac)")
                    }
                    Divider()
                    Menu("All Fonts") {
                        ForEach(InstalledFamilies.all, id: \.self) { name in
                            choice(name, title: name)
                        }
                    }
                } label: {
                    Text(family.isEmpty ? systemTitle : family)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .fixedSize()
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.11 : 0.06))
                }
                .onHover { isHovering = $0 }
                .animation(StudioMotion.hover, value: isHovering)
                .accessibilityValue(Text(family.isEmpty ? systemTitle : family))
                .help("The family the words are set in")
            }
            if isMissing {
                Label("\(family) isn't on this Mac, so the system font is drawn instead. A Mac that has it will draw it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choice(_ name: String, title: String) -> some View {
        Button {
            family = name
        } label: {
            if name == family {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// The families on this Mac, asked for once: the list is several hundred names long and
/// every inspector redraw would otherwise ask the font manager again.
@MainActor
private enum InstalledFamilies {
    static let all = FontFamilies.installed
}
