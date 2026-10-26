import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

/// A level the island shows in place of the system's overlay: the volume or the
/// display's brightness, as it is after a key press.
struct LevelHUD: Equatable {
    enum Kind: Equatable {
        case volume, brightness
    }

    let kind: Kind
    /// 0…1.
    let value: Double
    var muted = false

    var symbol: String {
        switch kind {
        case .brightness: value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || value == 0 { "speaker.slash.fill" }
            else if value < 0.34 { "speaker.wave.1.fill" }
            else if value < 0.67 { "speaker.wave.2.fill" }
            else { "speaker.wave.3.fill" }
        }
    }
}

/// The Mac's volume (the default output) and the main display's brightness.
enum SystemLevels {
    // MARK: Volume

    private static var output: AudioDeviceID { AudioOutputs.current }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// The output takes a volume (some, like a display over HDMI, don't: the system
    /// keeps those keys).
    static var canSetVolume: Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(output, &address) && AudioObjectIsPropertySettable(output, &address, &settable) == noErr && settable.boolValue
    }

    static var volume: Double {
        get {
            var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(output, &address, 0, nil, &size, &value)
            return Double(value)
        }
        set {
            var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            var value = Float32(min(max(newValue, 0), 1))
            AudioObjectSetPropertyData(output, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    static var muted: Bool {
        get {
            var address = address(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(output, &address) else { return false }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(output, &address, 0, nil, &size, &value)
            return value != 0
        }
        set {
            var address = address(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(output, &address) else { return }
            var value = UInt32(newValue ? 1 : 0)
            AudioObjectSetPropertyData(output, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }

    // MARK: Brightness

    /// DisplayServices, the private framework the system's own brightness keys use;
    /// nil where it can't be loaded (the system then keeps the brightness keys).
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let displayServices: (get: GetBrightness, set: SetBrightness)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"), let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetBrightness.self), unsafeBitCast(set, to: SetBrightness.self))
    }()

    /// The display the pointer is on, if its brightness can be read.
    private static var display: CGDirectDisplayID? {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The display's brightness, where DisplayServices answers (an external display
    /// without DDC doesn't: its keys stay with the system). In the sandbox it needs
    /// the backlightd lookup the entitlements allow.
    static var brightness: Double? {
        get {
            guard let services = displayServices, let display else { return nil }
            var value = Float(-1)
            return services.get(display, &value) == 0 && value >= 0 ? Double(value) : nil
        }
        set {
            guard let newValue, let services = displayServices, let display else { return }
            _ = services.set(display, Float(min(max(newValue, 0), 1)))
        }
    }
}

/// Takes the volume and brightness keys before the system does, sets the level
/// itself and has the island show it; the system's overlay never appears. Keys the
/// Mac can't be driven for here (a volume-less output, a display whose brightness
/// can't be read) are left to the system.
///
/// An active event tap, so it needs Accessibility; without it the system keeps them.
@MainActor
final class LevelKeys {
    private nonisolated(unsafe) static var tap: CFMachPort?
    private nonisolated(unsafe) static var onLevel: (@MainActor (LevelHUD) -> Void)?
    nonisolated(unsafe) static var isEnabled: @MainActor () -> Bool = { true }

    // NX_KEYTYPE_*: the keys' codes in a system-defined event.
    nonisolated private static let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    /// A press moves a sixteenth, as the system's does; with ⌥⇧ a quarter of that.
    nonisolated private static let step = 1.0 / 16

    @discardableResult
    static func start(onLevel: @escaping @MainActor (LevelHUD) -> Void) -> Bool {
        guard tap == nil else { return true }
        self.onLevel = onLevel
        // NSSystemDefined: 14.
        let mask = CGEventMask(1 << 14)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            LevelKeys.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    static func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = nil
    }

    /// True when the event was taken (the system won't see it). Runs on the main thread.
    nonisolated private static func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        let step = fine ? Self.step / 4 : Self.step
        return MainActor.assumeIsolated {
            guard isEnabled() else { return false }
            switch code {
            case soundUp, soundDown, mute:
                guard SystemLevels.canSetVolume else { return false }
                if down {
                    if code == mute {
                        SystemLevels.muted.toggle()
                    } else {
                        let up = code == soundUp
                        SystemLevels.muted = false
                        SystemLevels.volume = Self.snap(SystemLevels.volume + (up ? step : -step), step: step)
                        if !up, SystemLevels.volume == 0 { SystemLevels.muted = true }
                    }
                    onLevel?(LevelHUD(kind: .volume, value: SystemLevels.volume, muted: SystemLevels.muted))
                }
                return true
            case brightnessUp, brightnessDown:
                guard let current = SystemLevels.brightness else { return false }
                if down {
                    SystemLevels.brightness = Self.snap(current + (code == brightnessUp ? step : -step), step: step)
                    onLevel?(LevelHUD(kind: .brightness, value: SystemLevels.brightness ?? current))
                }
                return true
            default:
                return false
            }
        }
    }

    /// To the nearest step, so presses land on the same marks as the system's.
    private static func snap(_ value: Double, step: Double) -> Double {
        min(max((value / step).rounded() * step, 0), 1)
    }
}

/// The level in the island: its symbol, a bar that can be dragged, the number.
struct LevelRow: View {
    let level: LevelHUD
    /// The bar is being dragged (the island holds the HUD meanwhile).
    var onDrag: () -> Void = {}
    @State private var dragged: Double?

    static let width: CGFloat = 300

    var body: some View {
        let value = dragged ?? (level.muted ? 0 : level.value)
        HStack(spacing: 12) {
            LevelArt(level: dragged.map { LevelHUD(kind: level.kind, value: $0, muted: $0 == 0) } ?? level, size: 32)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(.white)
                        .frame(width: max(6, proxy.size.width * value))
                }
                .frame(height: dragged == nil ? 6 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let new = min(max(drag.location.x / proxy.size.width, 0), 1)
                        dragged = new
                        switch level.kind {
                        case .volume:
                            SystemLevels.muted = new == 0
                            SystemLevels.volume = new
                        case .brightness:
                            SystemLevels.brightness = new
                        }
                        onDrag()
                    }
                    .onEnded { _ in onDrag() })
            }
            .frame(height: 20)
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, alignment: .trailing)
                .contentTransition(.numericText(value: value))
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .frame(width: Self.width)
        .animation(.easeOut(duration: 0.12), value: value)
        .animation(.easeOut(duration: 0.12), value: dragged == nil)
        .onChange(of: level) { _, _ in dragged = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.kind == .volume ? "Volume" : "Brightness")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}
