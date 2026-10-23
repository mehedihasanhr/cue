import Carbon.HIToolbox
import Foundation
import os
import RecordKit

/// Global shortcuts through Carbon's `RegisterEventHotKey`.
///
/// Carbon rather than an `NSEvent` global monitor, for the reasons Cue's own hot keys use
/// it: it works inside the App Sandbox, it needs no Accessibility grant, and the key is
/// delivered to this app alone instead of being watched on its way to another one. The
/// only thing that ever touches Carbon, behind `HotkeyRegistrar`, so the rules about what
/// is registered when are tested without any of it.
@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, handler: @MainActor () -> Void)] = [:]

    /// 'KSTU'. Cue signs its own hot keys 'CUE'; a different signature means neither app
    /// can mistake a press meant for the other, even though both are asked on one queue.
    nonisolated fileprivate static let signature: OSType = 0x4B53_5455

    private static let log = Logger(subsystem: "com.stackrover.cue", category: "hotkeys")

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         { _, event, userData in CarbonHotkeyEvents.handle(event, userData) },
                                         1, &eventType,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &handlerRef)
        if status != noErr { Self.log.error("InstallEventHandler failed: \(status)") }
    }

    isolated deinit {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func register(_ combo: KeyCombo, id: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Self.log.notice("\(combo.displayString, privacy: .public) was refused: \(status)")
            return false
        }
        registrations[id] = (ref, handler)
        return true
    }

    func unregister(id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.ref)
    }

    fileprivate func dispatch(_ id: UInt32) {
        // Taken out first: what it does may change what is registered.
        let handler = registrations[id]?.handler
        handler?()
    }
}

/// The C side. Carbon delivers application-target events on the main thread, so
/// `assumeIsolated` is an assertion rather than a hop.
private nonisolated enum CarbonHotkeyEvents {
    static func handle(_ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr, hotKeyID.signature == CarbonHotkeyRegistrar.signature else {
            return OSStatus(eventNotHandledErr)
        }
        let id = hotKeyID.id
        let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { registrar.dispatch(id) }
        return noErr
    }
}
