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
        static let iconBookmark = "menuBar.customBookmark"
        static let appearance = "appearance"
        static let islandEnabled = "island.enabled"
        static let islandPlainDisplays = "island.plainDisplays"
        static let islandOpenMode = "island.openMode"
        static let islandHoverDelay = "island.hoverDelay"
        static let islandCloseDelay = "island.closeDelay"
        static let islandCloseOnLeave = "island.closeOnLeave"
        static let islandNotchBackground = "island.notchBackground"
        static let islandFlashCaptures = "island.flashCaptures"
        static let islandFlashDuration = "island.flashDuration"
        static let islandStatuses = "island.statuses"
        static let islandAnimation = "island.animation"
        static let islandPreview = "island.preview"
        static let islandOpensOn = "island.opensOn"
        static let clipboardEnabled = "clipboard.enabled"
        static let clipboardLimit = "clipboard.limit"
        static let colorPickerEnabled = "color.enabled"
        static let colorFormat = "color.format"
        static let panelPosition = "panels.position"
        static let timeEnabled = "clock.enabled"
        static let timeInterval = "clock.interval"
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
        static let snippetsEnabled = "snippets.enabled"
        static let snippetPrefix = "snippets.prefix"
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

    /// How the island moves: a spring, a short ease, or straight there.
    var islandAnimation: IslandAnimation {
        didSet { defaults.set(islandAnimation.rawValue, forKey: Key.islandAnimation) }
    }

    /// The tab the island opens on; nil is the last one used.
    var islandOpensOn: IslandTab? {
        didSet { defaults.set(islandOpensOn?.rawValue ?? "", forKey: Key.islandOpensOn) }
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

    /// Applies the chosen appearance to every Klik window (`nil` follows the system).
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
        case symbol(String)
        case custom

        /// Choices offered in Settings; all render as template images so they follow the menu bar tint.
        static let symbols = [
            "camera.viewfinder", "camera", "camera.fill", "camera.aperture", "viewfinder",
            "rectangle.dashed", "photo", "photo.on.rectangle", "macwindow", "scope", "cursorarrow.click", "sparkles",
        ]

        var storageValue: String {
            switch self {
            case .symbol(let name): name
            case .custom: "custom"
            }
        }

        init(storageValue: String) {
            self = storageValue == "custom" ? .custom : .symbol(storageValue)
        }
    }

    var icon: Icon {
        didSet { defaults.set(icon.storageValue, forKey: Key.icon) }
    }

    private(set) var customIconURL: URL?

    // MARK: Init

    init() {
        soundEnabled = defaults.object(forKey: Key.soundEnabled) as? Bool ?? true
        sound = Sound(storageValue: defaults.string(forKey: Key.sound) ?? "shutter")
        icon = Icon(storageValue: defaults.string(forKey: Key.icon) ?? "camera.viewfinder")
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        editorDefaults = EditorDefaults.load(from: defaults)
        dynamicIslandEnabled = defaults.object(forKey: Key.islandEnabled) as? Bool ?? true
        dynamicIslandOnPlainDisplays = defaults.object(forKey: Key.islandPlainDisplays) as? Bool ?? true
        islandOpenMode = IslandOpenMode(rawValue: defaults.string(forKey: Key.islandOpenMode) ?? "") ?? .hover
        islandHoverDelay = defaults.object(forKey: Key.islandHoverDelay) as? Double ?? 0
        islandCloseDelay = defaults.object(forKey: Key.islandCloseDelay) as? Double ?? 0.25
        islandCloseOnLeave = defaults.object(forKey: Key.islandCloseOnLeave) as? Bool ?? true
        islandNotchBackground = defaults.object(forKey: Key.islandNotchBackground) as? Bool ?? false
        islandFlashCaptures = defaults.object(forKey: Key.islandFlashCaptures) as? Bool ?? true
        islandFlashDuration = defaults.object(forKey: Key.islandFlashDuration) as? Double ?? 1.8
        islandStatuses = defaults.object(forKey: Key.islandStatuses) as? Bool ?? true
        islandAnimation = IslandAnimation(rawValue: defaults.string(forKey: Key.islandAnimation) ?? "") ?? .lively
        islandPreview = IslandPreview(rawValue: defaults.string(forKey: Key.islandPreview) ?? "") ?? .inline
        islandOpensOn = IslandTab(rawValue: defaults.string(forKey: Key.islandOpensOn) ?? "")
        clipboardHistoryEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? true
        clipboardHistoryLimit = defaults.object(forKey: Key.clipboardLimit) as? Int ?? 200
        colorPickerEnabled = defaults.object(forKey: Key.colorPickerEnabled) as? Bool ?? true
        colorFormat = ColorFormat(rawValue: defaults.string(forKey: Key.colorFormat) ?? "") ?? .hex
        panelPosition = PanelPosition(rawValue: defaults.string(forKey: Key.panelPosition) ?? "") ?? .pointer
        timeEnabled = defaults.object(forKey: Key.timeEnabled) as? Bool ?? true
        timeStatusInterval = defaults.object(forKey: Key.timeInterval) as? Int ?? 60
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
        notesAppleNotesFolder = defaults.string(forKey: Key.notesAppleNotesFolder) ?? "Klik"
        notesNotionParent = defaults.string(forKey: Key.notesNotionParent) ?? ""
        notesNotionToken = Keychain.get("notes.notion.token") ?? ""
        notesSendTo = Set(defaults.stringArray(forKey: Key.notesSendTo) ?? [])
        snippetsEnabled = defaults.object(forKey: Key.snippetsEnabled) as? Bool ?? true
        snippetPrefix = defaults.string(forKey: Key.snippetPrefix) ?? ";"
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
        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Klik")
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
