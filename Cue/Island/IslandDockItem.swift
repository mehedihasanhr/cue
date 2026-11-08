import SwiftUI

/// One of the round floating buttons under the open island (see `IslandDock`).
///
/// A button is either a section of the panel (it opens the panel there, or switches
/// to it when the panel is already open), one of Cue's windows, or a quick action
/// that fires straight away — a capture, the color picker, a recording.
///
/// The user chooses which buttons are there and in what order, in
/// Settings › Island › Floating buttons; `AppPreferences.islandDock` is the chosen
/// row, and `Self.standard` what it is before anyone has chosen.
enum IslandDockItem: String, CaseIterable, Hashable, Identifiable, Sendable {
    // Sections of the panel.
    case all, assets, captures, colors, clipboard, notes, snippets, notifications
    // Windows of their own.
    case tasks, settings
    // Quick actions.
    case record, captureArea, captureWindow, captureFullScreen, captureScrolling, captureText, pickColor

    var id: Self { self }

    /// The panel section this button opens, when it opens one.
    var tab: IslandTab? {
        switch self {
        case .all: .all
        case .assets: .assets
        case .captures: .captures
        case .colors: .colors
        case .clipboard: .clipboard
        case .notes: .notes
        case .snippets: .snippets
        case .notifications: .notifications
        default: nil
        }
    }

    init(_ tab: IslandTab) {
        switch tab {
        case .all: self = .all
        case .assets: self = .assets
        case .captures: self = .captures
        case .colors: self = .colors
        case .clipboard: self = .clipboard
        case .notes: self = .notes
        case .snippets: self = .snippets
        case .notifications: self = .notifications
        case .tasks: self = .tasks
        }
    }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .settings: "Settings"
        case .record: "Record"
        case .captureArea: "Capture area"
        case .captureWindow: "Capture window"
        case .captureFullScreen: "Capture full screen"
        case .captureScrolling: "Scrolling capture"
        case .captureText: "Capture text"
        case .pickColor: "Pick a color"
        default: tab?.title ?? rawValue
        }
    }

    /// What the button is for, under its name in Settings.
    var caption: String {
        switch self {
        case .tasks: "The tasks dashboard, in its own window"
        case .settings: "Cue Settings"
        case .record: "Start a screen recording"
        case .captureArea: "Drag out an area to capture"
        case .captureWindow: "Capture a window"
        case .captureFullScreen: "Capture the whole screen"
        case .captureScrolling: "Capture a long page, scrolling as it goes"
        case .captureText: "Read the text in an area and copy it"
        case .pickColor: "Pick a color from the screen"
        default: "Opens the panel on \(title)"
        }
    }

    var symbol: String {
        switch self {
        case .tasks: IslandTab.tasks.symbol
        case .settings: "gearshape"
        case .record: "record.circle"
        case .captureArea: "viewfinder"
        case .captureWindow: "macwindow"
        case .captureFullScreen: "display"
        case .captureScrolling: "rectangle.expand.vertical"
        case .captureText: "text.viewfinder"
        case .pickColor: "eyedropper"
        default: tab?.symbol ?? "square.grid.2x2"
        }
    }

    /// Record is red; everything else takes the row's own white.
    var tint: Color? { self == .record ? .red : nil }

    /// The same icon as an SF Symbol, for Settings, where the island's Hugeicons
    /// stand-ins (`Icon`) are not drawn.
    var settingsSymbol: String {
        switch self {
        case .assets: "folder"
        case .captures: "photo"
        case .clipboard: "doc.on.clipboard"
        default: symbol
        }
    }

    /// The tile's colour in Settings: one per kind of button.
    var settingsTint: Color {
        switch group {
        case .sections: .blue
        case .actions: self == .record ? .red : .orange
        case .windows: .gray
        }
    }

    /// How Settings groups the buttons on offer.
    enum Group: String, CaseIterable, Identifiable {
        case sections = "Panel sections"
        case actions = "Quick actions"
        case windows = "Windows"

        var id: Self { self }
    }

    var group: Group {
        switch self {
        case .tasks, .settings: .windows
        case .record, .captureArea, .captureWindow, .captureFullScreen, .captureScrolling, .captureText, .pickColor: .actions
        default: .sections
        }
    }

    /// The row as it was before the dock could be configured: every panel section on
    /// offer, then Tasks, Record and Settings.
    static func standard(for preferences: AppPreferences) -> [IslandDockItem] {
        preferences.islandTabs.map(IslandDockItem.init) + [.tasks, .record, .settings]
    }

    /// Stored as one string so the order is kept.
    static func decode(_ stored: String) -> [IslandDockItem]? {
        guard !stored.isEmpty else { return nil }
        var seen: Set<IslandDockItem> = []
        return stored.split(separator: ",").compactMap { IslandDockItem(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }

    static func encode(_ items: [IslandDockItem]) -> String {
        items.map(\.rawValue).joined(separator: ",")
    }
}

extension AppPreferences {
    /// A button belongs on the row only while the feature behind it is on in Settings.
    func offers(_ item: IslandDockItem) -> Bool {
        if let tab = item.tab { return shows(tab) }
        switch item {
        case .pickColor: return colorPickerEnabled
        default: return true
        }
    }

    /// Every button that can be put on the row, in a fixed order, for Settings.
    var islandDockChoices: [IslandDockItem] { IslandDockItem.allCases.filter(offers) }

    /// The floating buttons as they are drawn: the chosen row, or the standard one
    /// before anyone has chosen, with anything whose feature is off left out. Never
    /// empty — an empty row would leave the island with nothing under it, so it falls
    /// back to the standard row.
    var islandDock: [IslandDockItem] {
        let chosen = IslandDockItem.decode(islandDockItems)?.filter(offers)
        guard let chosen, !chosen.isEmpty else { return IslandDockItem.standard(for: self).filter(offers) }
        return chosen
    }
}
