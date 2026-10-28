import os
import AppKit
import Observation
import UniformTypeIdentifiers

/// Capture sound and menu-bar icon preferences. Persisted in UserDefaults; files the
/// user picks from disk are kept as security-scoped bookmarks (sandbox).
@Observable
final class AppPreferences {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let soundEnabled = "sound.enabled"
        static let sound = "sound.choice"
        static let soundBookmark = "sound.customBookmark"
        static let icon = "menuBar.icon"
        static let iconMarkMigrated = "menuBar.icon.markMigrated.2"
        static let welcomeTourSeen = "welcome.tourSeen"
        static let islandHello = "island.hello"
        static let iconBookmark = "menuBar.customBookmark"
        static let appearance = "appearance"
        static let showInDock = "app.showInDock"
        static let islandEnabled = "island.enabled"
        static let islandPlainDisplays = "island.plainDisplays"
        static let islandOpenMode = "island.openMode"
        static let islandHoverDelay = "island.hoverDelay"
        static let islandCloseDelay = "island.closeDelay"
        static let islandCloseOnLeave = "island.closeOnLeave"
        static let islandNotchBackground = "island.notchBackground"
        static let islandGlass = "island.glass"
        static let islandGlassStyle = "island.glass.style"
        static let islandGlassDarkness = "island.glass.darkness"
        static let islandGlassTint = "island.glass.tint"
        static let islandGlassLightNotchless = "island.glass.lightNotchless"
        static let islandFlashCaptures = "island.flashCaptures"
        static let islandFlashDuration = "island.flashDuration"
        static let islandStatuses = "island.statuses"
        static let islandAnimation = "island.animation"
        static let islandAnimationSpeed = "island.animationSpeed"
        static let islandShelfOpenAfterDrop = "island.shelf.openAfterDrop"
        static let islandShelfAutoCollapse = "island.shelf.autoCollapse"
        static let basketEnabled = "basket.enabled"
        static let islandNowPlaying = "island.nowPlaying"
        static let islandLevelHUD = "island.levelHUD"
        static let islandBattery = "island.battery"
        static let islandAudioDevices = "island.audioDevices"
        static let islandCapsLock = "island.capsLock"
        static let islandFocus = "island.focus"
        static let islandNetwork = "island.network"
        static let islandCompactTiles = "island.tiles"
        static let islandTileLeft = "island.tiles.left"
        static let islandTileRight = "island.tiles.right"
        static let islandTilesNowPlaying = "island.tiles.nowPlaying"
        static let islandDrives = "island.drives"
        static let islandDownloads = "island.downloads"
        static let islandNotifications = "island.notifications"
        // A new name: it was on by default, and is now off until asked for, whatever was saved before.
        static let islandHidesBanners = "island.notifications.hideBanners.2"
        static let islandCalendar = "island.calendar"
        static let islandWeather = "island.weather"
        static let islandLockScreen = "island.lockScreen"
        static let basketHideDelay = "basket.hideDelay"
        static let basketQuickActions = "basket.quickActions"
        static let islandPreview = "island.preview"
        static let islandPreviewOnHover = "island.previewOnHover"
        static let islandPreviewHoverDelay = "island.previewHoverDelay"
        static let islandOpensOn = "island.opensOn"
        static let agentSessions = "agents.enabled"
        static let agentAutoOpen = "agents.autoOpen"
        static let agentNotchGlow = "agents.notchGlow"
        static let afterCapture = "capture.after"
        static let clipboardEnabled = "clipboard.enabled"
        static let clipboardLimit = "clipboard.limit"
        static let colorPickerEnabled = "color.enabled"
        static let colorFormat = "color.format"
        static let panelPosition = "panels.position"
        static let panelColumns = "panels.columns"
        static let timeEnabled = "clock.enabled"
        static let timeInterval = "clock.interval"
        static let timeSpoken = "clock.spoken"
        static let timeVoice = "clock.voice"
        static let timeVoiceVolume = "clock.voiceVolume"
        static let prayerEnabled = "prayer.enabled"
        static let prayerMethod = "prayer.method"
        static let prayerMadhab = "prayer.madhab"
        static let prayerLocationMode = "prayer.locationMode"
        static let prayerManualLatitude = "prayer.manualLatitude"
        static let prayerManualLongitude = "prayer.manualLongitude"
        static let prayerKnownLatitude = "prayer.knownLatitude"
        static let prayerKnownLongitude = "prayer.knownLongitude"
        static let prayerAnnouncements = "prayer.announcements"
        static let prayerAdjustments = "prayer.adjustments"
        static let notesEnabled = "notes.enabled"
        static let notesObsidianVault = "notes.obsidianVault"
        static let notesAppleNotesFolder = "notes.appleNotesFolder"
        static let notesNotionParent = "notes.notionParent"
        static let notesSendTo = "notes.sendTo"
        static let notesPanelClarity = "notes.panelClarity"
        static let notesPanelWidth = "notes.panelWidth"
        static let notesPanelHeight = "notes.panelHeight"
        static let tasksServerURL = "tasks.server.url"
        static let tasksSyncEnabled = "tasks.sync.enabled"
        static let tasksSyncInterval = "tasks.sync.interval"
        static let tasksWebhookURL = "tasks.webhook.url"
        static let tasksWebhookEnabled = "tasks.webhook.enabled"
        static let tasksWebhookEvents = "tasks.webhook.events"
        static let tasksMCPEnabled = "tasks.mcp.enabled"
        static let snippetsEnabled = "snippets.enabled"
        static let snippetPrefix = "snippets.prefix"
        static let ocrLanguages = "ocr.languages"
        static let ocrCloudEnabled = "ocr.cloud.enabled"
        static let ocrCloudProvider = "ocr.cloud.provider"
        static let ocrCloudEndpoint = "ocr.cloud.endpoint"
        static let ocrCloudModel = "ocr.cloud.model"
        static let ocrPreferCloud = "ocr.cloud.preferred"
        static let ocrChecksScript = "ocr.checksScript"
    }

    // MARK: Notes

    var notesEnabled: Bool {
        didSet { defaults.set(notesEnabled, forKey: Key.notesEnabled) }
    }

    /// The Obsidian vault "Send to Obsidian" writes into (empty: the last one opened).
    var notesObsidianVault: String {
        didSet { defaults.set(notesObsidianVault, forKey: Key.notesObsidianVault) }
    }

    /// The Apple Notes folder new notes go in (empty: the account's default).
    var notesAppleNotesFolder: String {
        didSet { defaults.set(notesAppleNotesFolder, forKey: Key.notesAppleNotesFolder) }
    }

    /// The Notion page or database new pages go under (an id or its URL).
    var notesNotionParent: String {
        didSet { defaults.set(notesNotionParent, forKey: Key.notesNotionParent) }
    }

    /// The Notion integration's secret, in the Keychain.
    var notesNotionToken: String {
        didSet { Keychain.set(notesNotionToken, for: "notes.notion.token") }
    }

    /// Where every new note is sent as it is saved (raw values of `NoteDestination`).
    var notesSendTo: Set<String> {
        didSet { defaults.set(Array(notesSendTo).sorted(), forKey: Key.notesSendTo) }
    }

    /// How clear the quick note's glass is: 0 frosted (the default), 1 nearly clear.
    var notesPanelClarity: Double {
        didSet { defaults.set(notesPanelClarity, forKey: Key.notesPanelClarity) }
    }

    /// The quick note's last size (nil: the default), kept once it is resized.
    var notesPanelSize: CGSize? {
        didSet {
            if let size = notesPanelSize {
                defaults.set(Double(size.width), forKey: Key.notesPanelWidth)
                defaults.set(Double(size.height), forKey: Key.notesPanelHeight)
            } else {
                defaults.removeObject(forKey: Key.notesPanelWidth)
                defaults.removeObject(forKey: Key.notesPanelHeight)
            }
        }
    }

    // MARK: Tasks

    /// The URL Cue POSTs its tasks to, and takes the server's changes from.
    var tasksServerURL: String {
        didSet { defaults.set(tasksServerURL, forKey: Key.tasksServerURL) }
    }

    /// Sent as `Authorization: Bearer …`; in the Keychain.
    var tasksServerToken: String {
        didSet { Keychain.set(tasksServerToken, for: "tasks.server.token") }
    }

    var tasksSyncEnabled: Bool {
        didSet { defaults.set(tasksSyncEnabled, forKey: Key.tasksSyncEnabled) }
    }

    /// Minutes between syncs besides the one after each change (0: only then).
    var tasksSyncInterval: Int {
        didSet { defaults.set(tasksSyncInterval, forKey: Key.tasksSyncInterval) }
    }

    /// Where each change is POSTed as an event.
    var tasksWebhookURL: String {
        didSet { defaults.set(tasksWebhookURL, forKey: Key.tasksWebhookURL) }
    }

    /// Signs each webhook body (`X-Cue-Signature`); in the Keychain.
    var tasksWebhookSecret: String {
        didSet { Keychain.set(tasksWebhookSecret, for: "tasks.webhook.secret") }
    }

    var tasksWebhookEnabled: Bool {
        didSet { defaults.set(tasksWebhookEnabled, forKey: Key.tasksWebhookEnabled) }
    }

    /// Whether AI agents can reach the task list over MCP (Settings › Tasks).
    var tasksMCPEnabled: Bool {
        didSet { defaults.set(tasksMCPEnabled, forKey: Key.tasksMCPEnabled) }
    }

    /// Which changes the webhook gets: `created`, `updated`, `status`, `deleted`.
    var tasksWebhookEvents: Set<String> {
        didSet { defaults.set(Array(tasksWebhookEvents).sorted(), forKey: Key.tasksWebhookEvents) }
    }

    static let taskWebhookEventKinds: [(kind: String, title: String)] = [("created", "Created"), ("updated", "Edited"), ("status", "Status changed"), ("deleted", "Deleted")]

    // MARK: Snippets

    /// Expand snippet keywords as they are typed in any app (needs Accessibility).
    var snippetsEnabled: Bool {
        didSet { defaults.set(snippetsEnabled, forKey: Key.snippetsEnabled) }
    }

    /// What every keyword starts with (";" by default) so plain words never expand;
    /// the form fills it in, and it can be changed there for one snippet.
    var snippetPrefix: String {
        didSet { defaults.set(snippetPrefix, forKey: Key.snippetPrefix) }
    }

    // MARK: Capture text

    /// The languages Capture Text reads, in order; the first decides which engine
    /// runs. Empty — the default, and what every existing install has — leaves Vision
    /// to detect the language itself, exactly as Cue has always done.
    var ocrLanguages: [String] {
        didSet { defaults.set(ocrLanguages, forKey: Key.ocrLanguages) }
    }

    /// Say so when the text comes back in a different alphabet from the one asked
    /// for, rather than copying it anyway.
    var ocrChecksScript: Bool {
        didSet { defaults.set(ocrChecksScript, forKey: Key.ocrChecksScript) }
    }

    /// Send the selected area to a recognition service. Off until switched on by hand.
    var ocrCloudEnabled: Bool {
        didSet { defaults.set(ocrCloudEnabled, forKey: Key.ocrCloudEnabled) }
    }

    var ocrCloudProvider: CloudOCRConfiguration.Provider {
        didSet { defaults.set(ocrCloudProvider.rawValue, forKey: Key.ocrCloudProvider) }
    }

    /// The service's key, kept where the other service credentials are kept and never
    /// written to UserDefaults or the log.
    var ocrCloudSecret: String {
        didSet { Keychain.set(ocrCloudSecret, for: "ocr.cloud.secret") }
    }

    var ocrCloudEndpoint: String {
        didSet { defaults.set(ocrCloudEndpoint, forKey: Key.ocrCloudEndpoint) }
    }

    var ocrCloudModel: String {
        didSet { defaults.set(ocrCloudModel, forKey: Key.ocrCloudModel) }
    }

    /// Use the service even for languages this Mac can read on its own.
    var ocrPreferCloud: Bool {
        didSet { defaults.set(ocrPreferCloud, forKey: Key.ocrPreferCloud) }
    }

    /// Everything recognition needs, copied out so a background capture can carry it.
    var ocrSettings: OCRSettings {
        OCRSettings(
            selection: OCRPreferenceCodec.selection(fromTags: ocrLanguages),
            cloud: OCRPreferenceCodec.cloud(enabled: ocrCloudEnabled, provider: ocrCloudProvider.rawValue,
                                            secret: ocrCloudSecret, endpoint: ocrCloudEndpoint, model: ocrCloudModel),
            preferCloud: ocrPreferCloud,
            checksScript: ocrChecksScript
        )
    }

    // MARK: Time & prayer

    static let timeIntervals = [0, 15, 30, 60, 120, 180]

    /// The island clock as a whole: the time on the island and prayer times.
    var timeEnabled: Bool {
        didSet { defaults.set(timeEnabled, forKey: Key.timeEnabled) }
    }

    /// Minutes between the island showing the time (0: never).
    var timeStatusInterval: Int {
        didSet { defaults.set(timeStatusInterval, forKey: Key.timeInterval) }
    }

    /// Say the time, and each prayer, aloud as the island shows them.
    var timeSpoken: Bool {
        didSet { defaults.set(timeSpoken, forKey: Key.timeSpoken) }
    }

    /// The voice it's said in (an identifier; empty: the sweetest one installed).
    var timeVoice: String {
        didSet { defaults.set(timeVoice, forKey: Key.timeVoice) }
    }

    /// How loud it's said, 0.1–1: soft by default.
    var timeVoiceVolume: Double {
        didSet { defaults.set(timeVoiceVolume, forKey: Key.timeVoiceVolume) }
    }

    var prayerTimesEnabled: Bool {
        didSet { defaults.set(prayerTimesEnabled, forKey: Key.prayerEnabled) }
    }

    var prayerMethod: CalculationMethod {
        didSet { defaults.set(prayerMethod.rawValue, forKey: Key.prayerMethod) }
    }

    var prayerMadhab: Madhab {
        didSet { defaults.set(prayerMadhab.rawValue, forKey: Key.prayerMadhab) }
    }

    enum PrayerLocationMode: String, CaseIterable {
        case current, manual

        var title: String {
            switch self {
            case .current: "Current location"
            case .manual: "Entered by hand"
            }
        }
    }

    var prayerLocationMode: PrayerLocationMode {
        didSet { defaults.set(prayerLocationMode.rawValue, forKey: Key.prayerLocationMode) }
    }

    var prayerManualPlace: Coordinates {
        didSet {
            defaults.set(prayerManualPlace.latitude, forKey: Key.prayerManualLatitude)
            defaults.set(prayerManualPlace.longitude, forKey: Key.prayerManualLongitude)
        }
    }

    /// The last fix from Core Location, so times are ready at launch and offline.
    var prayerKnownPlace: Coordinates? {
        didSet {
            defaults.set(prayerKnownPlace?.latitude, forKey: Key.prayerKnownLatitude)
            defaults.set(prayerKnownPlace?.longitude, forKey: Key.prayerKnownLongitude)
        }
    }

    /// Announce each prayer, and the times prayer is not allowed, on the island.
    var prayerAnnouncements: Bool {
        didSet { defaults.set(prayerAnnouncements, forKey: Key.prayerAnnouncements) }
    }

    /// Minutes added to each computed time, to match a local timetable.
    var prayerAdjustments: [Prayer: Int] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: prayerAdjustments.filter { $0.value != 0 }.map { ($0.key.rawValue, $0.value) })
            defaults.set(stored, forKey: Key.prayerAdjustments)
        }
    }

    // MARK: Panels

    /// Where the floating panel and the quick task open.
    var panelPosition: PanelPosition {
        didSet { defaults.set(panelPosition.rawValue, forKey: Key.panelPosition) }
    }

    /// Cards per row in the floating panel's grid.
    var panelColumns: Int {
        didSet { defaults.set(panelColumns, forKey: Key.panelColumns) }
    }
    static let panelColumnRange = 2...6

    // MARK: Color picker

    var colorPickerEnabled: Bool {
        didSet { defaults.set(colorPickerEnabled, forKey: Key.colorPickerEnabled) }
    }

    /// The format a picked color is copied in (every format is in the card's menu).
    var colorFormat: ColorFormat {
        didSet { defaults.set(colorFormat.rawValue, forKey: Key.colorFormat) }
    }

    // MARK: Clipboard history

    var clipboardHistoryEnabled: Bool {
        didSet { defaults.set(clipboardHistoryEnabled, forKey: Key.clipboardEnabled) }
    }

    static let clipboardLimits = [50, 100, 200, 500, 1000]

    var clipboardHistoryLimit: Int {
        didSet { defaults.set(clipboardHistoryLimit, forKey: Key.clipboardLimit) }
    }

    // MARK: Dynamic Island

    /// The hover-to-open captures panel docked on the notch.
    var dynamicIslandEnabled: Bool {
        didSet { defaults.set(dynamicIslandEnabled, forKey: Key.islandEnabled) }
    }

    /// Without a notch the island is a small pill on the menu bar; some people would
    /// rather not have it there.
    var dynamicIslandOnPlainDisplays: Bool {
        didSet { defaults.set(dynamicIslandOnPlainDisplays, forKey: Key.islandPlainDisplays) }
    }

    /// What opens the island: the pointer resting on it, or a click.
    enum IslandOpenMode: String, CaseIterable {
        case hover, click

        var title: String {
            switch self {
            case .hover: "Hover"
            case .click: "Click"
            }
        }
    }

    var islandOpenMode: IslandOpenMode {
        didSet { defaults.set(islandOpenMode.rawValue, forKey: Key.islandOpenMode) }
    }

    /// How long the pointer rests on the closed island before it opens (hover mode).
    var islandHoverDelay: Double {
        didSet { defaults.set(islandHoverDelay, forKey: Key.islandHoverDelay) }
    }

    /// How long after the pointer leaves the open island closes.
    var islandCloseDelay: Double {
        didSet { defaults.set(islandCloseDelay, forKey: Key.islandCloseDelay) }
    }

    /// Off: the island stays open until ⎋ or a click outside it.
    var islandCloseOnLeave: Bool {
        didSet { defaults.set(islandCloseOnLeave, forKey: Key.islandCloseOnLeave) }
    }

    /// Draw the closed island black beside the notch (or as a pill) instead of
    /// keeping it invisible until it opens.
    var islandNotchBackground: Bool {
        didSet { defaults.set(islandNotchBackground, forKey: Key.islandNotchBackground) }
    }

    /// The open island as dark Liquid Glass (macOS 26 and later) rather than solid black.
    var islandGlass: Bool {
        didSet { defaults.set(islandGlass, forKey: Key.islandGlass) }
    }

    /// Clear glass (sharp, the desktop bent at its edges) or frosted (blurred).
    enum GlassStyle: String, CaseIterable {
        case clear, frosted

        var title: String { self == .clear ? "Clear" : "Frosted" }
    }

    /// A colour washed over the glass.
    enum GlassTint: String, CaseIterable {
        case none, blue, purple, pink, orange, green, graphite

        var title: String { self == .none ? "None" : rawValue.capitalized }
    }

    var islandGlassStyle: GlassStyle {
        didSet { defaults.set(islandGlassStyle.rawValue, forKey: Key.islandGlassStyle) }
    }

    /// How dark the glass stays below the content, 0 (clear) to 1 (black): enough
    /// that what sits there stays readable over a bright desktop.
    var islandGlassDarkness: Double {
        didSet { defaults.set(islandGlassDarkness, forKey: Key.islandGlassDarkness) }
    }

    var islandGlassTint: GlassTint {
        didSet { defaults.set(islandGlassTint.rawValue, forKey: Key.islandGlassTint) }
    }

    /// Without a notch to meet, the island needs no black band at the top: lighter glass all down.
    var islandGlassLightNotchless: Bool {
        didSet { defaults.set(islandGlassLightNotchless, forKey: Key.islandGlassLightNotchless) }
    }

    enum AfterCapture: String, CaseIterable {
        case edit, copy

        var title: String {
            switch self {
            case .edit: "Open the editor"
            case .copy: "Copy to the clipboard"
            }
        }
    }

    /// What a finished capture does: opens in the editor (it is on the clipboard
    /// either way), or is just copied and kept in the library.
    var afterCapture: AfterCapture {
        didSet { defaults.set(afterCapture.rawValue, forKey: Key.afterCapture) }
    }

    /// Show each new capture on the island for a moment.
    var islandFlashCaptures: Bool {
        didSet { defaults.set(islandFlashCaptures, forKey: Key.islandFlashCaptures) }
    }

    /// Seconds a new capture stays on the island.
    var islandFlashDuration: Double {
        didSet { defaults.set(islandFlashDuration, forKey: Key.islandFlashDuration) }
    }

    /// Statuses on the island: pastes from the stack, uploads, focus sessions,
    /// snippets saved. Off: the HUD says them instead.
    var islandStatuses: Bool {
        didSet { defaults.set(islandStatuses, forKey: Key.islandStatuses) }
    }

    enum IslandAnimation: String, CaseIterable {
        case lively, quick, none

        var title: String {
            switch self {
            case .lively: "Lively"
            case .quick: "Quick"
            case .none: "Off"
            }
        }
    }

    /// How fast the lively island moves, around the pace set for the display.
    enum IslandAnimationSpeed: String, CaseIterable {
        case slower, normal, faster

        var title: String {
            switch self {
            case .slower: "Slower"
            case .normal: "Normal"
            case .faster: "Faster"
            }
        }

        /// Multiplies every duration and spring response.
        var factor: Double {
            switch self {
            case .slower: 1.3
            case .normal: 1
            case .faster: 0.75
            }
        }
    }

    enum IslandPreview: String, CaseIterable {
        case inline, pane

        var title: String {
            switch self {
            case .inline: "In the island"
            case .pane: "Below it"
            }
        }
    }

    /// Where an opened card shows: in the cards' place, or in a pane under the island.
    var islandPreview: IslandPreview {
        didSet { defaults.set(islandPreview.rawValue, forKey: Key.islandPreview) }
    }

    /// With the pane: resting the pointer on a card opens it there.
    var islandPreviewOnHover: Bool {
        didSet { defaults.set(islandPreviewOnHover, forKey: Key.islandPreviewOnHover) }
    }

    /// How long the pointer rests on a card before the pane shows it.
    var islandPreviewHoverDelay: Double {
        didSet { defaults.set(islandPreviewHoverDelay, forKey: Key.islandPreviewHoverDelay) }
    }

    /// How the island moves: a spring, a short ease, or straight there.
    var islandAnimation: IslandAnimation {
        didSet { defaults.set(islandAnimation.rawValue, forKey: Key.islandAnimation) }
    }

    var islandAnimationSpeed: IslandAnimationSpeed {
        didSet { defaults.set(islandAnimationSpeed.rawValue, forKey: Key.islandAnimationSpeed) }
    }

    /// After files go on the shelf, the island stays open showing them; off, it closes.
    var islandShelfOpenAfterDrop: Bool {
        didSet { defaults.set(islandShelfOpenAfterDrop, forKey: Key.islandShelfOpenAfterDrop) }
    }

    /// Tiles beside the closed notch.
    var islandCompactTiles: Bool {
        didSet { defaults.set(islandCompactTiles, forKey: Key.islandCompactTiles) }
    }

    var islandTileLeft: CompactTile {
        didSet { defaults.set(islandTileLeft.rawValue, forKey: Key.islandTileLeft) }
    }

    var islandTileRight: CompactTile {
        didSet { defaults.set(islandTileRight.rawValue, forKey: Key.islandTileRight) }
    }

    /// While music plays, its artwork and the dancing Cue take both sides.
    var islandTilesNowPlaying: Bool {
        didSet { defaults.set(islandTilesNowPlaying, forKey: Key.islandTilesNowPlaying) }
    }

    /// The island shows the network dropping or changing, and a VPN connecting.
    var islandNetwork: Bool {
        didSet { defaults.set(islandNetwork, forKey: Key.islandNetwork) }
    }

    /// The island shows a drive or disk image mounting or ejecting.
    var islandDrives: Bool {
        didSet { defaults.set(islandDrives, forKey: Key.islandDrives) }
    }

    /// What plays and a focus session over the lock screen (experimental, private calls).
    var islandLockScreen: Bool {
        didSet { defaults.set(islandLockScreen, forKey: Key.islandLockScreen) }
    }

    /// The weather in the panel's header, and its forecast in the island.
    var islandWeather: Bool {
        didSet { defaults.set(islandWeather, forKey: Key.islandWeather) }
    }

    /// Five minutes before a meeting the island says so, with Join for a call.
    var islandCalendar: Bool {
        didSet { defaults.set(islandCalendar, forKey: Key.islandCalendar) }
    }

    /// The island shows a download finishing in Downloads; clicking it reveals the file.
    var islandDownloads: Bool {
        didSet { defaults.set(islandDownloads, forKey: Key.islandDownloads) }
    }

    /// The welcome and its tour have been shown (or closed), so launch goes straight to work.
    var welcomeTourSeen: Bool {
        didSet { defaults.set(welcomeTourSeen, forKey: Key.welcomeTourSeen) }
    }

    /// The island says hello each time Cue starts.
    var islandHello: Bool {
        didSet { defaults.set(islandHello, forKey: Key.islandHello) }
    }

    /// The island shows the notifications macOS shows, and keeps them in a tab.
    var islandNotifications: Bool {
        didSet { defaults.set(islandNotifications, forKey: Key.islandNotifications) }
    }

    /// With those on, and only when asked: macOS's own banner in the corner is closed
    /// once the island has it (which drops it from Notification Center). Off by default.
    var islandHidesBanners: Bool {
        didSet { defaults.set(islandHidesBanners, forKey: Key.islandHidesBanners) }
    }

    /// The island shows Caps Lock turning on and off.
    var islandCapsLock: Bool {
        didSet { defaults.set(islandCapsLock, forKey: Key.islandCapsLock) }
    }

    /// The island shows a Focus (Do Not Disturb and the rest) turning on and off.
    var islandFocus: Bool {
        didSet { defaults.set(islandFocus, forKey: Key.islandFocus) }
    }

    /// The island shows AirPods and other Bluetooth audio devices connecting, with their batteries.
    var islandAudioDevices: Bool {
        didSet { defaults.set(islandAudioDevices, forKey: Key.islandAudioDevices) }
    }

    /// The island shows the charger going in or out, and the battery running low.
    var islandBattery: Bool {
        didSet { defaults.set(islandBattery, forKey: Key.islandBattery) }
    }

    /// The volume and brightness keys show their level in the island, not the system's overlay.
    var islandLevelHUD: Bool {
        didSet { defaults.set(islandLevelHUD, forKey: Key.islandLevelHUD) }
    }

    /// What Music or Spotify plays shows in the island, with its controls.
    var islandNowPlaying: Bool {
        didSet { defaults.set(islandNowPlaying, forKey: Key.islandNowPlaying) }
    }

    /// Shaking the pointer while dragging files brings up the floating basket.
    var basketEnabled: Bool {
        didSet { defaults.set(basketEnabled, forKey: Key.basketEnabled) }
    }

    /// Shaking offers four places (basket, Transform, share link, AirDrop), not just the basket.
    var basketQuickActions: Bool {
        didSet { defaults.set(basketQuickActions, forKey: Key.basketQuickActions) }
    }

    /// How long an empty basket stays after the drag that brought it ends.
    var basketHideDelay: Double {
        didSet { defaults.set(basketHideDelay, forKey: Key.basketHideDelay) }
    }

    /// The island closes once the shelf's last files have been dragged out.
    var islandShelfAutoCollapse: Bool {
        didSet { defaults.set(islandShelfAutoCollapse, forKey: Key.islandShelfAutoCollapse) }
    }

    /// The tab the island opens on; nil is the last one used.
    var islandOpensOn: IslandTab? {
        didSet { defaults.set(islandOpensOn?.rawValue ?? "", forKey: Key.islandOpensOn) }
    }

    // MARK: Agent sessions

    /// Claude Code and Codex sessions on the island, once an agent is connected.
    var agentSessionsEnabled: Bool {
        didSet { defaults.set(agentSessionsEnabled, forKey: Key.agentSessions) }
    }

    /// The island opens by itself when an agent asks something.
    var agentAutoOpen: Bool {
        didSet { defaults.set(agentAutoOpen, forKey: Key.agentAutoOpen) }
    }

    /// A line of light around the closed notch while an agent works. On by default.
    var agentNotchGlow: Bool {
        didSet { defaults.set(agentNotchGlow, forKey: Key.agentNotchGlow) }
    }

    // MARK: Editor defaults

    var editorDefaults: EditorDefaults {
        didSet { editorDefaults.save(to: defaults) }
    }

    // MARK: Appearance

    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    /// Applies the chosen appearance to every Cue window (`nil` follows the system).
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    // MARK: Sound

    /// Built-in shutter, one of the macOS alert sounds, or a file the user picked.
    enum Sound: Hashable {
        case shutter
        case system(String)
        case custom

        static let systemNames = ["Tink", "Pop", "Glass", "Ping", "Purr", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Sosumi", "Submarine", "Basso"]

        var title: String {
            switch self {
            case .shutter: "Shutter (built-in)"
            case .system(let name): name
            case .custom: "Custom file"
            }
        }

        var storageValue: String {
            switch self {
            case .shutter: "shutter"
            case .system(let name): "system:\(name)"
            case .custom: "custom"
            }
        }

        init(storageValue: String) {
            if storageValue == "custom" { self = .custom }
            else if storageValue.hasPrefix("system:") { self = .system(String(storageValue.dropFirst(7))) }
            else { self = .shutter }
        }
    }

    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) }
    }

    var sound: Sound {
        didSet { defaults.set(sound.storageValue, forKey: Key.sound) }
    }

    private(set) var customSoundURL: URL?

    // MARK: Menu-bar icon

    enum Icon: Hashable {
        /// Cue's own mark, the default.
        case mark
        case symbol(String)
        case custom

        /// Choices offered in Settings; all render as template images so they follow the menu bar tint.
        static let symbols = [
            "camera.viewfinder", "camera", "camera.fill", "camera.aperture", "viewfinder",
            "rectangle.dashed", "photo", "photo.on.rectangle", "macwindow", "scope", "cursorarrow.click", "sparkles",
        ]

        var storageValue: String {
            switch self {
            case .mark: "mark"
            case .symbol(let name): name
            case .custom: "custom"
            }
        }

        init(storageValue: String) {
            switch storageValue {
            case "mark": self = .mark
            case "custom": self = .custom
            default: self = .symbol(storageValue)
            }
        }
    }

    var icon: Icon {
        didSet { defaults.set(icon.storageValue, forKey: Key.icon) }
    }

    // MARK: Dock

    /// Cue in the Dock and the app switcher, rather than the menu bar alone. Off,
    /// it is an agent as before — the panels behave the same either way.
    var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Key.showInDock)
            applyDockVisibility()
        }
    }

    /// Set while a video editor is open: its commands live in the menu bar, which an app
    /// without a Dock tile does not have.
    var keepsDock = false {
        didSet { if keepsDock != oldValue { applyDockVisibility() } }
    }

    func applyDockVisibility() {
        let policy: NSApplication.ActivationPolicy = showInDock || keepsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Coming back from an agent, the app needs a nudge to claim its Dock tile.
        if policy == .regular { NSApp.activate(ignoringOtherApps: false) }
    }

    private(set) var customIconURL: URL?

    // MARK: Init

    init() {
        // Someone who had Cue before the tour existed has been through it, in effect:
        // this flag is set on every launch, so its presence means Cue has run before.
        welcomeTourSeen = defaults.object(forKey: Key.welcomeTourSeen) as? Bool ?? defaults.bool(forKey: Key.iconMarkMigrated)
        soundEnabled = defaults.object(forKey: Key.soundEnabled) as? Bool ?? true
        sound = Sound(storageValue: defaults.string(forKey: Key.sound) ?? "shutter")
        // Cue borrowed a camera glyph before it had a mark of its own; every one of
        // those moves across once. An image the user chose from disk is left alone,
        // and a glyph can be picked again in Settings.
        if !defaults.bool(forKey: Key.iconMarkMigrated), defaults.string(forKey: Key.icon) != "custom" {
            defaults.set("mark", forKey: Key.icon)
        }
        defaults.set(true, forKey: Key.iconMarkMigrated)
        icon = Icon(storageValue: defaults.string(forKey: Key.icon) ?? "mark")
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        editorDefaults = EditorDefaults.load(from: defaults)
        dynamicIslandEnabled = defaults.object(forKey: Key.islandEnabled) as? Bool ?? true
        dynamicIslandOnPlainDisplays = defaults.object(forKey: Key.islandPlainDisplays) as? Bool ?? true
        islandOpenMode = IslandOpenMode(rawValue: defaults.string(forKey: Key.islandOpenMode) ?? "") ?? .hover
        islandHoverDelay = defaults.object(forKey: Key.islandHoverDelay) as? Double ?? 0
        afterCapture = AfterCapture(rawValue: defaults.string(forKey: Key.afterCapture) ?? "") ?? .edit
        islandCloseDelay = defaults.object(forKey: Key.islandCloseDelay) as? Double ?? 0.25
        islandCloseOnLeave = defaults.object(forKey: Key.islandCloseOnLeave) as? Bool ?? true
        islandNotchBackground = defaults.object(forKey: Key.islandNotchBackground) as? Bool ?? false
        islandGlass = defaults.object(forKey: Key.islandGlass) as? Bool ?? true
        islandGlassStyle = GlassStyle(rawValue: defaults.string(forKey: Key.islandGlassStyle) ?? "") ?? .clear
        islandGlassDarkness = defaults.object(forKey: Key.islandGlassDarkness) as? Double ?? 0.45
        islandGlassTint = GlassTint(rawValue: defaults.string(forKey: Key.islandGlassTint) ?? "") ?? .none
        islandGlassLightNotchless = defaults.object(forKey: Key.islandGlassLightNotchless) as? Bool ?? true
        islandFlashCaptures = defaults.object(forKey: Key.islandFlashCaptures) as? Bool ?? true
        islandFlashDuration = defaults.object(forKey: Key.islandFlashDuration) as? Double ?? 1.8
        islandStatuses = defaults.object(forKey: Key.islandStatuses) as? Bool ?? true
        islandAnimation = IslandAnimation(rawValue: defaults.string(forKey: Key.islandAnimation) ?? "") ?? .lively
        islandAnimationSpeed = IslandAnimationSpeed(rawValue: defaults.string(forKey: Key.islandAnimationSpeed) ?? "") ?? .normal
        islandShelfOpenAfterDrop = defaults.object(forKey: Key.islandShelfOpenAfterDrop) as? Bool ?? true
        islandShelfAutoCollapse = defaults.object(forKey: Key.islandShelfAutoCollapse) as? Bool ?? true
        basketEnabled = defaults.object(forKey: Key.basketEnabled) as? Bool ?? true
        islandNowPlaying = defaults.object(forKey: Key.islandNowPlaying) as? Bool ?? true
        islandLevelHUD = defaults.object(forKey: Key.islandLevelHUD) as? Bool ?? true
        islandBattery = defaults.object(forKey: Key.islandBattery) as? Bool ?? true
        islandAudioDevices = defaults.object(forKey: Key.islandAudioDevices) as? Bool ?? true
        islandCapsLock = defaults.object(forKey: Key.islandCapsLock) as? Bool ?? true
        islandNetwork = defaults.object(forKey: Key.islandNetwork) as? Bool ?? true
        islandCompactTiles = defaults.object(forKey: Key.islandCompactTiles) as? Bool ?? true
        islandTileLeft = CompactTile(rawValue: defaults.string(forKey: Key.islandTileLeft) ?? "") ?? .none
        islandTileRight = CompactTile(rawValue: defaults.string(forKey: Key.islandTileRight) ?? "") ?? .none
        islandTilesNowPlaying = defaults.object(forKey: Key.islandTilesNowPlaying) as? Bool ?? true
        islandDrives = defaults.object(forKey: Key.islandDrives) as? Bool ?? true
        islandDownloads = defaults.object(forKey: Key.islandDownloads) as? Bool ?? true
        islandNotifications = defaults.object(forKey: Key.islandNotifications) as? Bool ?? false
        islandHidesBanners = defaults.object(forKey: Key.islandHidesBanners) as? Bool ?? false
        islandHello = defaults.object(forKey: Key.islandHello) as? Bool ?? true
        islandCalendar = defaults.object(forKey: Key.islandCalendar) as? Bool ?? false
        islandWeather = defaults.object(forKey: Key.islandWeather) as? Bool ?? false
        islandLockScreen = defaults.object(forKey: Key.islandLockScreen) as? Bool ?? false
        islandFocus = defaults.object(forKey: Key.islandFocus) as? Bool ?? true
        basketHideDelay = defaults.object(forKey: Key.basketHideDelay) as? Double ?? 1.5
        basketQuickActions = defaults.object(forKey: Key.basketQuickActions) as? Bool ?? true
        islandPreview = IslandPreview(rawValue: defaults.string(forKey: Key.islandPreview) ?? "") ?? .inline
        islandPreviewOnHover = defaults.object(forKey: Key.islandPreviewOnHover) as? Bool ?? true
        islandPreviewHoverDelay = defaults.object(forKey: Key.islandPreviewHoverDelay) as? Double ?? 0.5
        islandOpensOn = IslandTab(rawValue: defaults.string(forKey: Key.islandOpensOn) ?? "")
        agentSessionsEnabled = defaults.object(forKey: Key.agentSessions) as? Bool ?? true
        agentAutoOpen = defaults.object(forKey: Key.agentAutoOpen) as? Bool ?? true
        agentNotchGlow = defaults.object(forKey: Key.agentNotchGlow) as? Bool ?? true
        clipboardHistoryEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? true
        clipboardHistoryLimit = defaults.object(forKey: Key.clipboardLimit) as? Int ?? 200
        colorPickerEnabled = defaults.object(forKey: Key.colorPickerEnabled) as? Bool ?? true
        colorFormat = ColorFormat(rawValue: defaults.string(forKey: Key.colorFormat) ?? "") ?? .hex
        panelPosition = PanelPosition(rawValue: defaults.string(forKey: Key.panelPosition) ?? "") ?? .pointer
        panelColumns = min(max(defaults.object(forKey: Key.panelColumns) as? Int ?? 4, Self.panelColumnRange.lowerBound), Self.panelColumnRange.upperBound)
        timeEnabled = defaults.object(forKey: Key.timeEnabled) as? Bool ?? true
        timeStatusInterval = defaults.object(forKey: Key.timeInterval) as? Int ?? 60
        timeSpoken = defaults.bool(forKey: Key.timeSpoken)
        timeVoice = defaults.string(forKey: Key.timeVoice) ?? ""
        timeVoiceVolume = defaults.object(forKey: Key.timeVoiceVolume) as? Double ?? 0.6
        prayerTimesEnabled = defaults.bool(forKey: Key.prayerEnabled)
        prayerMethod = CalculationMethod(rawValue: defaults.string(forKey: Key.prayerMethod) ?? "") ?? .muslimWorldLeague
        prayerMadhab = Madhab(rawValue: defaults.string(forKey: Key.prayerMadhab) ?? "") ?? .standard
        prayerLocationMode = PrayerLocationMode(rawValue: defaults.string(forKey: Key.prayerLocationMode) ?? "") ?? .current
        prayerManualPlace = Coordinates(latitude: defaults.double(forKey: Key.prayerManualLatitude), longitude: defaults.double(forKey: Key.prayerManualLongitude))
        if let latitude = defaults.object(forKey: Key.prayerKnownLatitude) as? Double, let longitude = defaults.object(forKey: Key.prayerKnownLongitude) as? Double {
            prayerKnownPlace = Coordinates(latitude: latitude, longitude: longitude)
        } else {
            prayerKnownPlace = nil
        }
        prayerAnnouncements = defaults.object(forKey: Key.prayerAnnouncements) as? Bool ?? true
        notesEnabled = defaults.object(forKey: Key.notesEnabled) as? Bool ?? true
        notesObsidianVault = defaults.string(forKey: Key.notesObsidianVault) ?? ""
        notesAppleNotesFolder = defaults.string(forKey: Key.notesAppleNotesFolder) ?? "Cue"
        notesNotionParent = defaults.string(forKey: Key.notesNotionParent) ?? ""
        notesNotionToken = Keychain.get("notes.notion.token") ?? ""
        notesSendTo = Set(defaults.stringArray(forKey: Key.notesSendTo) ?? [])
        notesPanelClarity = defaults.object(forKey: Key.notesPanelClarity) as? Double ?? 0
        if let width = defaults.object(forKey: Key.notesPanelWidth) as? Double, let height = defaults.object(forKey: Key.notesPanelHeight) as? Double {
            notesPanelSize = CGSize(width: width, height: height)
        } else {
            notesPanelSize = nil
        }
        tasksServerURL = defaults.string(forKey: Key.tasksServerURL) ?? ""
        tasksServerToken = Keychain.get("tasks.server.token") ?? ""
        tasksSyncEnabled = defaults.object(forKey: Key.tasksSyncEnabled) as? Bool ?? false
        tasksSyncInterval = defaults.object(forKey: Key.tasksSyncInterval) as? Int ?? 5
        tasksWebhookURL = defaults.string(forKey: Key.tasksWebhookURL) ?? ""
        tasksWebhookSecret = Keychain.get("tasks.webhook.secret") ?? ""
        tasksWebhookEnabled = defaults.object(forKey: Key.tasksWebhookEnabled) as? Bool ?? false
        tasksMCPEnabled = defaults.object(forKey: Key.tasksMCPEnabled) as? Bool ?? true
        tasksWebhookEvents = Set(defaults.stringArray(forKey: Key.tasksWebhookEvents) ?? ["created", "updated", "status", "deleted"])
        snippetsEnabled = defaults.object(forKey: Key.snippetsEnabled) as? Bool ?? true
        snippetPrefix = defaults.string(forKey: Key.snippetPrefix) ?? ";"
        ocrLanguages = defaults.stringArray(forKey: Key.ocrLanguages) ?? []
        ocrChecksScript = defaults.object(forKey: Key.ocrChecksScript) as? Bool ?? true
        ocrCloudEnabled = defaults.bool(forKey: Key.ocrCloudEnabled)
        ocrCloudProvider = CloudOCRConfiguration.Provider(rawValue: defaults.string(forKey: Key.ocrCloudProvider) ?? "") ?? .google
        ocrCloudSecret = Keychain.get("ocr.cloud.secret") ?? ""
        ocrCloudEndpoint = defaults.string(forKey: Key.ocrCloudEndpoint) ?? ""
        ocrCloudModel = defaults.string(forKey: Key.ocrCloudModel) ?? ""
        ocrPreferCloud = defaults.bool(forKey: Key.ocrPreferCloud)
        let stored = defaults.dictionary(forKey: Key.prayerAdjustments) as? [String: Int] ?? [:]
        prayerAdjustments = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Prayer(rawValue: key).map { ($0, value) } })
        customSoundURL = defaults.data(forKey: Key.soundBookmark).flatMap(Self.resolve)
        customIconURL = defaults.data(forKey: Key.iconBookmark).flatMap(Self.resolve)
        if sound == .custom, customSoundURL == nil { sound = .shutter }
        if icon == .custom, customIconURL == nil { icon = .symbol("camera.viewfinder") }
    }

    // MARK: Playback

    @ObservationIgnored private var player: NSSound?

    /// Plays the configured capture sound (no-op when disabled).
    func playCaptureSound() {
        guard soundEnabled else { return }
        play(sound)
    }

    /// Plays any option, e.g. for the preview button in Settings.
    func play(_ sound: Sound) {
        player?.stop()
        guard let loaded = load(sound) else { return }
        loaded.volume = 0.8
        loaded.play()
        player = loaded
    }

    private func load(_ sound: Sound) -> NSSound? {
        switch sound {
        case .shutter:
            guard let url = Bundle.main.url(forResource: "Shutter", withExtension: "wav") else { return nil }
            return NSSound(contentsOf: url, byReference: true)
        case .system(let name):
            return NSSound(named: name)
        case .custom:
            guard let url = customSoundURL else { return nil }
            return withScopedAccess(to: url) { NSSound(contentsOf: url, byReference: false) }
        }
    }

    // MARK: Choosing files

    func chooseCustomSound() {
        let panel = NSOpenPanel()
        panel.title = "Choose a capture sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = bookmark(url) else { return }
        defaults.set(bookmark, forKey: Key.soundBookmark)
        customSoundURL = url
        sound = .custom
        play(.custom)
    }

    func chooseCustomIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose a menu bar icon"
        panel.message = "Best results: a black-on-transparent PNG or PDF, about 18×18 points."
        panel.allowedContentTypes = [.png, .pdf, .jpeg, .tiff, .heic, .svg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = bookmark(url) else { return }
        defaults.set(bookmark, forKey: Key.iconBookmark)
        customIconURL = url
        icon = .custom
    }

    /// The status-item image for the current choice (template so it adapts to the menu bar).
    func menuBarImage() -> NSImage? {
        switch icon {
        case .mark:
            guard let mark = NSImage(named: "CueMark") else { return nil }
            let image = NSImage(size: Self.fit(mark.size, height: 17), flipped: false) { rect in
                mark.draw(in: rect)
                return true
            }
            image.isTemplate = true
            return image
        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Cue")
            image?.isTemplate = true
            return image
        case .custom:
            guard let url = customIconURL,
                  let image = withScopedAccess(to: url, { NSImage(contentsOf: url) })
            else { return nil }
            let size = Self.fit(image.size, height: 18)
            let scaled = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
            scaled.isTemplate = true
            return scaled
        }
    }

    // MARK: Helpers

    private static func fit(_ size: CGSize, height: CGFloat) -> CGSize {
        guard size.height > 0 else { return CGSize(width: height, height: height) }
        let scale = height / size.height
        return CGSize(width: max(1, (size.width * scale).rounded()), height: height)
    }

    private func bookmark(_ url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            Log.app.error("Could not bookmark \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func withScopedAccess<T>(to url: URL, _ body: () -> T) -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return body()
    }
}
