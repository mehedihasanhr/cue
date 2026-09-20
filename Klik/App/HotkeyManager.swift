import os
import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut expressed in Carbon terms.
///
/// Carbon `RegisterEventHotKey` is used (rather than an `NSEvent` global monitor)
/// because it works inside the App Sandbox and does not require the
/// Accessibility permission.
struct Hotkey: Hashable, Codable {
    var keyCode: UInt32
    /// Carbon modifier mask: `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    var modifiers: UInt32

    static let fullScreen = Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey | shiftKey))
    static let region = Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey | shiftKey))
    static let scrolling = Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(optionKey | shiftKey))
    static let showPanel = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | shiftKey))
    static let captureText = Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey))
    static let pickColor = Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | shiftKey))
    static let quickTask = Hotkey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey | shiftKey))
    static let clipboardPanel = Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))
    static let commandPalette = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
    static let pasteNext = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    static let window = Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(optionKey | shiftKey))
    static let escape = Hotkey(keyCode: UInt32(kVK_Escape), modifiers: 0)
    static let enter = Hotkey(keyCode: UInt32(kVK_Return), modifiers: 0)

    /// Combinations macOS binds to its own screenshot features by default. They can be
    /// registered, but the system handles the keypress first unless the user turns them off.
    static let reservedByMacOS: Set<Hotkey> = [
        Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)),
        Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)),
        Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)),
        Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey)),
        Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | controlKey)),
        Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | controlKey)),
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(from: event.modifierFlags))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    /// A global shortcut must include ⌘, ⌥ or ⌃, or be a function key, so it can't
    /// swallow ordinary typing.
    var isUsableAsGlobalShortcut: Bool {
        let hasCommandLike = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        let isFunctionKey = (Int(keyCode) >= kVK_F1 && Int(keyCode) <= kVK_F12) || Int(keyCode) >= kVK_F13
        return hasCommandLike || isFunctionKey
    }

    var isReservedByMacOS: Bool { Self.reservedByMacOS.contains(self) }

    /// Human-readable form such as "⌥⇧3".
    var displayString: String {
        Self.modifierSymbols(modifiers) + KeyCodeNames.name(for: keyCode)
    }

    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// AppKit modifier flags for use as an `NSMenuItem` key equivalent.
    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Key equivalent string for `NSMenuItem`.
    var menuKeyEquivalent: String {
        KeyCodeNames.menuKeyEquivalent(for: keyCode)
    }
}

enum HotkeyID: UInt32, CaseIterable {
    case fullScreen = 1
    case region
    case scrolling
    /// Opens the captures panel at the mouse pointer.
    case showPanel
    /// Select an area, recognise its text on-device and copy it.
    case captureText
    /// The eyedropper: pick a color anywhere on screen.
    case pickColor
    /// A floating "new task" form at the pointer.
    case quickTask
    /// The clipboard history alone, as a keyboard-driven list.
    case clipboardPanel
    /// One list over everything: actions, answers, every item.
    case commandPalette
    /// Pastes the next entry of the history each press (the paste stack).
    case pasteNext
    /// A window by itself, with its shadow.
    case window
    /// Registered only while a scrolling capture runs, so ↩ / ⎋ work from any app.
    case confirmCapture = 98
    case cancelCapture = 99

    /// The shortcuts a user can rebind in Settings.
    static let configurable: [HotkeyID] = [.commandPalette, .fullScreen, .region, .window, .scrolling, .captureText, .pickColor, .quickTask, .showPanel, .clipboardPanel, .pasteNext]

    var defaultHotkey: Hotkey {
        switch self {
        case .fullScreen: .fullScreen
        case .region: .region
        case .scrolling: .scrolling
        case .showPanel: .showPanel
        case .captureText: .captureText
        case .pickColor: .pickColor
        case .quickTask: .quickTask
        case .clipboardPanel: .clipboardPanel
        case .commandPalette: .commandPalette
        case .pasteNext: .pasteNext
        case .window: .window
        case .confirmCapture: .enter
        case .cancelCapture: .escape
        }
    }

    var title: String {
        switch self {
        case .fullScreen: "Capture full screen"
        case .region: "Capture area"
        case .scrolling: "Scrolling capture"
        case .showPanel: "Klik panel at the pointer"
        case .captureText: "Capture text (OCR)"
        case .pickColor: "Pick a color"
        case .quickTask: "Quick task"
        case .clipboardPanel: "Clipboard list"
        case .commandPalette: "Command palette"
        case .pasteNext: "Paste next (paste stack)"
        case .window: "Capture window"
        case .confirmCapture: "Finish capture"
        case .cancelCapture: "Stop capture"
        }
    }

    var defaultsKey: String { "shortcut.\(self)" }
}

enum HotkeyError: Error {
    /// Another process (typically macOS's own screenshot shortcuts) owns this combination.
    case alreadyInUse(Hotkey)
    case osStatus(OSStatus)
}

/// Registers global hotkeys with Carbon and dispatches them on the main actor.
final class HotkeyManager {
    private var handlerRef: EventHandlerRef?
    private var registrations: [HotkeyID: (ref: EventHotKeyRef, action: () -> Void)] = [:]

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { handler, event, userData in CarbonHotkeyBridge.handleEvent(handler, event, userData) },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            Log.hotkey.error("InstallEventHandler failed: \(status)")
        }
    }

    isolated deinit {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(_ hotkey: Hotkey, id: HotkeyID, action: @escaping () -> Void) throws(HotkeyError) {
        unregister(id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: CarbonHotkeyBridge.signature, id: id.rawValue)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) {
                Log.hotkey.notice("\(hotkey.displayString, privacy: .public) is already registered by another process")
                throw .alreadyInUse(hotkey)
            }
            Log.hotkey.error("RegisterEventHotKey failed: \(status)")
            throw .osStatus(status)
        }
        registrations[id] = (ref, action)
        Log.hotkey.info("Registered \(hotkey.displayString, privacy: .public) for \(String(describing: id), privacy: .public)")
    }

    func unregister(_ id: HotkeyID) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.ref)
    }

    fileprivate func dispatch(rawID: UInt32) {
        guard let id = HotkeyID(rawValue: rawID), let registration = registrations[id] else { return }
        registration.action()
    }
}

/// The C-callable side of the bridge. Kept `nonisolated` because Carbon calls it
/// through a plain C function pointer; it hops to the main actor before touching
/// the manager. Carbon delivers application-target events on the main thread, so
/// `assumeIsolated` is an assertion, not a hop.
private nonisolated enum CarbonHotkeyBridge {
    static let signature: OSType = 0x4B4C_494B // 'KLIK'

    static func handleEvent(
        _ handler: EventHandlerCallRef?,
        _ event: EventRef?,
        _ userData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated {
            manager.dispatch(rawID: hotKeyID.id)
        }
        return noErr
    }
}
