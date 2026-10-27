import CoreAudio
import IOBluetooth
import SwiftUI

/// A Bluetooth audio device coming or going, as the island shows it.
struct AudioDeviceHUD: Equatable {
    let name: String
    let connected: Bool
    /// 0…100 each, when the device reports it (AirPods and Beats do; many others don't).
    var left: Int?
    var right: Int?
    var batteryCase: Int?
    var single: Int?

    var symbol: String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpods.max" }
        if name.contains("airpods pro") { return "airpods.pro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("buds") || name.contains("earbud") || left != nil { return "earbuds" }
        if name.contains("speaker") || name.contains("boom") || name.contains("soundlink") { return "hifispeaker.fill" }
        return "headphones"
    }

    var hasBattery: Bool { left != nil || right != nil || batteryCase != nil || single != nil }
}

/// Watches for Bluetooth audio devices appearing among the Mac's sound devices (a
/// CoreAudio listener: no permission) and reads their battery over Bluetooth.
@MainActor
final class AudioDeviceMonitor {
    private let onChange: (AudioDeviceHUD) -> Void
    private var known: [AudioDeviceID: String] = [:]
    private var listener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping (AudioDeviceHUD) -> Void) {
        self.onChange = onChange
        known = Self.bluetoothDevices()
        var address = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.devicesChanged() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    func stop() {
        guard let listener else { return }
        var address = Self.devicesAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        self.listener = nil
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func devicesChanged() {
        let now = Self.bluetoothDevices()
        // A headset shows up as an input and an output: one HUD per name.
        let arrived = Set(now.filter { known[$0.key] == nil }.values)
        let left = Set(known.filter { now[$0.key] == nil }.values).subtracting(now.values)
        known = now
        for name in arrived {
            onChange(Self.hud(for: name, connected: true))
            // Batteries are often reported a moment after the connection.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                let later = Self.hud(for: name, connected: true)
                if later.hasBattery { self?.onChange(later) }
            }
        }
        for name in left { onChange(AudioDeviceHUD(name: name, connected: false)) }
    }

    static func hud(for name: String, connected: Bool) -> AudioDeviceHUD {
        var hud = AudioDeviceHUD(name: name, connected: connected)
        guard let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { $0.name == name }) else { return hud }
        func percent(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)), let value = device.value(forKey: key) as? Int, value > 0 else { return nil }
            return min(value, 100)
        }
        hud.left = percent("batteryPercentLeft")
        hud.right = percent("batteryPercentRight")
        hud.batteryCase = percent("batteryPercentCase")
        hud.single = hud.left == nil && hud.right == nil ? percent("batteryPercentSingle") : nil
        return hud
    }

    /// The Mac's Bluetooth sound devices, by ID, with their names.
    private static func bluetoothDevices() -> [AudioDeviceID: String] {
        var address = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [:] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [:] }
        var devices: [AudioDeviceID: String] = [:]
        for id in ids {
            var transport = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var type = UInt32(0)
            var typeSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transport, 0, nil, &typeSize, &type) == noErr,
                  type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE else { continue }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name = name?.takeRetainedValue() as String? else { continue }
            devices[id] = name
        }
        return devices
    }
}

/// The device in the island: its picture popping in on a disc, its name, and a ring
/// for each battery it reports.
struct AudioDeviceRow: View {
    let device: AudioDeviceHUD
    @State private var shown = false
    @State private var burst = false

    private static let blue = Color(red: 0.4, green: 0.68, blue: 1.0)
    private var motion: Bool { !IslandView.reduceMotion }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Self.blue.opacity(0.5), lineWidth: 1)
                    .scaleEffect(burst ? 1.5 : 1)
                    .opacity(burst || !device.connected ? 0 : 0.6)
                StatusIcon(symbol: nil, tint: Self.blue, size: 36, active: device.connected)
                Icon(device.symbol, size: 17, weight: .semibold)
                    .foregroundStyle(StatusIcon.glyphStyle(Self.blue, active: device.connected))
                    .scaleEffect(shown ? 1 : (device.connected ? 0.4 : 1))
                    .rotationEffect(.degrees(shown || !device.connected ? 0 : -30))
                    .offset(y: !device.connected && shown ? 2 : 0)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(device.connected ? "Connected" : "Disconnected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .frame(maxWidth: 180, alignment: .leading)
            .offset(x: shown ? 0 : -6)
            .opacity(shown ? 1 : 0)
            if device.connected, device.hasBattery {
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    if let left = device.left { BatteryRing(percent: left, label: "L", shown: shown) }
                    if let right = device.right { BatteryRing(percent: right, label: "R", shown: shown) }
                    if let single = device.single { BatteryRing(percent: single, label: nil, shown: shown) }
                    if let batteryCase = device.batteryCase { BatteryRing(percent: batteryCase, label: "Case", shown: shown) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .fixedSize()
        .animation(.easeOut(duration: 0.25), value: device.hasBattery)
        .onAppear {
            withAnimation(motion ? .spring(response: 0.5, dampingFraction: 0.62).delay(0.08) : .easeOut(duration: 0.15)) { shown = true }
            if motion, device.connected { withAnimation(.easeOut(duration: 0.7).delay(0.15)) { burst = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name) \(device.connected ? "connected" : "disconnected")")
    }
}

/// One battery: a ring filled to its level, the number inside, and what it is under it.
private struct BatteryRing: View {
    let percent: Int
    let label: String?
    let shown: Bool

    private var tint: Color { percent <= 20 ? Color(red: 1.0, green: 0.36, blue: 0.32) : Color(red: 0.36, green: 0.85, blue: 0.45) }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: shown ? CGFloat(percent) / 100 : 0)
                    .stroke(tint, style: SwiftUI.StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(IslandView.reduceMotion ? nil : .easeOut(duration: 0.7).delay(0.15), value: shown)
                Text("\(percent)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 26, height: 26)
            if let label {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}
