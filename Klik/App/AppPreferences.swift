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
        static let clipboardEnabled = "clipboard.enabled"
        static let clipboardLimit = "clipboard.limit"
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
        clipboardHistoryEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? true
        clipboardHistoryLimit = defaults.object(forKey: Key.clipboardLimit) as? Int ?? 200
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
