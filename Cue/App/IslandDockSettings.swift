import SwiftUI

/// Settings › Island › Floating buttons: which round buttons sit under the open
/// island and in what order (`IslandDockItem`).
///
/// The chosen buttons are a list that can be dragged into order or moved with the
/// buttons beside each row; the ones left over wait under "Add a button", grouped by
/// what they are. The strip above shows the row as the island will draw it.
struct IslandDockSettings: View {
    @Environment(AppPreferences.self) private var preferences

    private var chosen: [IslandDockItem] { preferences.islandDock }
    private var rest: [IslandDockItem] { preferences.islandDockChoices.filter { !chosen.contains($0) } }

    var body: some View {
        @Bindable var preferences = preferences
        SettingsGroup("Floating buttons",
                      footer: "Drag a row onto another to reorder. A button whose feature is off in Settings is left out of the row.") {
            SettingsRow("Show the floating buttons", subtitle: "Round buttons under the open island.") {
                Toggle("Floating buttons", isOn: $preferences.islandHoverButtons).toggleStyle(.switch)
            }
            SettingsCell(vertical: 14) {
                IslandDockPreview(items: chosen)
            }
            ForEach(Array(chosen.enumerated()), id: \.element) { index, item in
                IslandDockSettingsRow(item: item, index: index, count: chosen.count,
                                      move: { move($0, to: $1) },
                                      drop: { drop($0, before: index) },
                                      remove: chosen.count > 1 ? { save(chosen.filter { $0 != item }) } : nil)
            }
            SettingsCell(vertical: 10) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(IslandDockItem.Group.allCases) { group in
                            let items = rest.filter { $0.group == group }
                            if !items.isEmpty {
                                Section(group.rawValue) {
                                    ForEach(items) { item in
                                        Button { save(chosen + [item]) } label: {
                                            Label(item.title, systemImage: item.settingsSymbol)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Add a button", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(rest.isEmpty)
                    Spacer(minLength: 12)
                    Button("Standard row") { preferences.islandDockItems = "" }
                        .controlSize(.small)
                        .disabled(preferences.islandDockItems.isEmpty)
                        .help("Every section of the panel, then Tasks, Record and Settings.")
                }
            }
        }
        .disabled(!preferences.dynamicIslandEnabled)
    }

    private func save(_ items: [IslandDockItem]) {
        // Nothing chosen means the standard row (`islandDock`), so the island is never
        // left with an empty strip under it; the rows themselves keep one button.
        preferences.islandDockItems = items.isEmpty ? "" : IslandDockItem.encode(items)
    }

    /// Moves the button at `source` one place along, left (`-1`) or right (`+1`).
    private func move(_ source: Int, to step: Int) {
        var items = chosen
        let destination = source + step
        guard items.indices.contains(source), items.indices.contains(destination) else { return }
        items.swapAt(source, destination)
        save(items)
    }

    /// A dragged button dropped on the row at `index` takes that place.
    private func drop(_ item: IslandDockItem, before index: Int) {
        var items = chosen
        guard let from = items.firstIndex(of: item), from != index else { return }
        items.remove(at: from)
        items.insert(item, at: min(index, items.count))
        save(items)
    }
}

/// One chosen button: its icon, what it is, and the ways to move it or take it off.
private struct IslandDockSettingsRow: View {
    let item: IslandDockItem
    let index: Int
    let count: Int
    /// The row's index and which way to go: -1 left, +1 right.
    let move: (Int, Int) -> Void
    let drop: (IslandDockItem) -> Void
    /// Nil for the last button left: the row is never emptied from here.
    let remove: (() -> Void)?
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        SettingsCell(vertical: 8) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                SymbolTile(symbol: item.settingsSymbol, tint: item.settingsTint)
                    .dimmedWhenDisabled()
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(SettingsFont.item)
                    Text(item.caption).font(SettingsFont.sub).foregroundStyle(.secondary)
                }
                .dimmedWhenDisabled()
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    Button { move(index, -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                        .help("Move it left")
                    Button { move(index, 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index == count - 1)
                        .help("Move it right")
                    Button { remove?() } label: { Image(systemName: "minus.circle") }
                        .disabled(remove == nil)
                        .help(remove == nil ? "The row keeps at least one button" : "Take it off the row")
                        .padding(.leading, 6)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .background(targeted ? SettingsPalette.selectedRow : .clear)
        .onHover { hovering = $0 }
        .draggable(item.rawValue) {
            Label(item.title, systemImage: item.settingsSymbol)
        }
        .dropDestination(for: String.self) { dropped, _ in
            guard let moved = dropped.compactMap(IslandDockItem.init(rawValue:)).first else { return false }
            drop(moved)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), button \(index + 1) of \(count)")
    }
}

/// The row as the island will draw it: the chosen icons on round glass.
private struct IslandDockPreview: View {
    let items: [IslandDockItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Under the open island").font(SettingsFont.sub).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Icon(item.symbol, size: 15, weight: .medium)
                        .foregroundStyle(item.tint ?? .white.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.black.opacity(0.75)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                        .help(item.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.4)))
        }
        .dimmedWhenDisabled()
    }
}
