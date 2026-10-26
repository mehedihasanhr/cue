import Foundation
import IOKit.ps
import SwiftUI

/// The battery as the island shows it: when the charger goes in or out, and when it
/// runs low.
struct BatteryHUD: Equatable {
    enum Event: Equatable {
        case pluggedIn, unplugged, low, full
    }

    let event: Event
    /// 0…100.
    let percent: Int
    let charging: Bool
    /// Minutes to full while charging, or left on battery; nil while the Mac works it out.
    let minutes: Int?

    var title: String {
        switch event {
        case .pluggedIn: charging ? "Charging" : "Plugged in"
        case .unplugged: "On battery"
        case .low: "Low battery"
        case .full: "Fully charged"
        }
    }

    var subtitle: String {
        switch event {
        case .full: return "You can unplug"
        case .pluggedIn where !charging: return "Not charging"
        default:
            guard let minutes else { return "Working out the time…" }
            let time = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
            return charging ? "\(time) until full" : "\(time) left"
        }
    }

    var tint: Color {
        if charging || event == .full { return Color(red: 0.36, green: 0.85, blue: 0.45) }
        if percent <= 20 { return Color(red: 1.0, green: 0.36, blue: 0.32) }
        return .white
    }
}

/// Watches the power source and calls back on what the island should show. The
/// power-source notifications need no permission, sandbox or not.
@MainActor
final class BatteryMonitor {
    private var source: CFRunLoopSource?
    private let onEvent: (BatteryHUD) -> Void
    private var lastOnAC: Bool?
    private var lastPercent: Int?
    /// The low levels already warned of on this discharge.
    private var warned: Set<Int> = []
    private static let lowLevels = [20, 10]

    /// nil on a Mac without a battery.
    init?(onEvent: @escaping (BatteryHUD) -> Void) {
        guard Self.read() != nil else { return nil }
        self.onEvent = onEvent
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.changed() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        // Where things stand now: nothing to say yet.
        if let state = Self.read() {
            lastOnAC = state.onAC
            lastPercent = state.percent
            warned = Set(Self.lowLevels.filter { state.percent <= $0 })
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    /// The battery now, as an event (for the diagnostics and the first look).
    static func current(_ event: BatteryHUD.Event) -> BatteryHUD? {
        read().map { BatteryHUD(event: event, percent: $0.percent, charging: $0.charging, minutes: $0.minutes) }
    }

    private func changed() {
        guard let state = Self.read() else { return }
        defer {
            lastOnAC = state.onAC
            lastPercent = state.percent
        }
        let hud = { (event: BatteryHUD.Event) in
            BatteryHUD(event: event, percent: state.percent, charging: state.charging, minutes: state.minutes)
        }
        if let lastOnAC, lastOnAC != state.onAC {
            if state.onAC { warned = [] }
            onEvent(hud(state.onAC ? .pluggedIn : .unplugged))
            return
        }
        if state.onAC {
            if let lastPercent, lastPercent < 100, state.percent == 100 { onEvent(hud(.full)) }
            return
        }
        // On battery, crossing a low level: once each, until it charges again.
        if Self.lowLevels.contains(where: { state.percent <= $0 && !warned.contains($0) }) {
            warned.formUnion(Self.lowLevels.filter { state.percent <= $0 })
            onEvent(hud(.low))
        }
    }

    private struct State {
        let percent: Int
        let onAC: Bool
        let charging: Bool
        let minutes: Int?
    }

    private static func read() -> State? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            return State(percent: Int((Double(current) / Double(max) * 100).rounded()), onAC: onAC, charging: charging,
                         minutes: minutes.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }
}

/// The battery in the island: a drawn glyph that fills to the level (a bolt over it
/// while charging), what happened, the time, and the percentage.
struct BatteryRow: View {
    let battery: BatteryHUD
    @State private var filled = false

    var body: some View {
        HStack(spacing: 12) {
            BatteryGlyph(percent: filled ? battery.percent : 0, charging: battery.charging, tint: battery.tint)
                .frame(width: 34, height: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(battery.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(battery.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            Text("\(battery.percent)%")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(battery.tint)
                .contentTransition(.numericText(value: Double(battery.percent)))
        }
        .padding(.horizontal, 22)
        .fixedSize()
        .onAppear {
            withAnimation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.6).delay(0.12)) { filled = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(battery.title), \(battery.percent) percent, \(battery.subtitle)")
    }
}

private struct BatteryGlyph: View {
    var percent: Int
    let charging: Bool
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let nub: CGFloat = 3
            let body = CGSize(width: proxy.size.width - nub - 1, height: proxy.size.height)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
                    .frame(width: body.width, height: body.height)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, (body.width - 6) * CGFloat(percent) / 100), height: body.height - 6)
                    .padding(.leading, 3)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.white.opacity(0.45))
                    .frame(width: nub, height: body.height * 0.4)
                    .offset(x: body.width + 1)
                if charging {
                    Icon("bolt.fill", size: 10, weight: .bold)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(width: body.width, height: body.height)
                }
            }
        }
    }
}
