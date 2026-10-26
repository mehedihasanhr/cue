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
        if event == .low || (!charging && event == .unplugged && percent <= 20) { return Color(red: 1.0, green: 0.36, blue: 0.32) }
        if charging || event == .full || event == .pluggedIn { return Color(red: 0.36, green: 0.85, blue: 0.45) }
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

/// The battery in the island, after the iPhone's: what happened on a badge that
/// moves for it (a bolt that zaps in, a plug that pulls away, a pulse when low), the
/// words, and a battery that fills to the level, a light running along it while it
/// charges.
struct BatteryRow: View {
    let battery: BatteryHUD
    @State private var shown = false
    @State private var burst = false

    private var motion: Bool { !IslandView.reduceMotion }

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                Text(battery.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(battery.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .offset(x: shown ? 0 : -6)
            .opacity(shown ? 1 : 0)
            Spacer(minLength: 18)
            Text("\(battery.percent)%")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(battery.tint)
                .contentTransition(.numericText(value: Double(battery.percent)))
            BatteryGlyph(level: shown ? Double(battery.percent) / 100 : 0, battery: battery)
                .frame(width: 46, height: 22)
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .fixedSize()
        .onAppear {
            withAnimation(motion ? .spring(response: 0.55, dampingFraction: 0.8).delay(0.1) : .easeOut(duration: 0.15)) { shown = true }
            if motion { withAnimation(.easeOut(duration: 0.7).delay(0.15)) { burst = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(battery.title), \(battery.percent) percent, \(battery.subtitle)")
    }

    /// The event's symbol on a tinted disc, moving for it.
    private var badge: some View {
        let tint = battery.tint
        return ZStack {
            Circle()
                .fill(tint.opacity(0.35))
                .blur(radius: 9)
                .opacity(battery.event == .unplugged ? 0 : shown ? 0.9 : 0)
            // A ring spreading out as it lands.
            Circle()
                .strokeBorder(tint.opacity(0.7), lineWidth: 1.5)
                .scaleEffect(burst ? 1.9 : 1)
                .opacity(burst ? 0 : (battery.event == .unplugged ? 0 : 0.8))
            GlossyDisc(symbol: nil, tint: battery.event == .unplugged ? Color(white: 0.34) : tint, size: 34, lit: battery.event != .unplugged)
            symbol
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private var symbol: some View {
        switch battery.event {
        case .pluggedIn:
            Icon("bolt.fill", size: 15, weight: .bold)
                .scaleEffect(shown ? 1 : 0.3)
                .rotationEffect(.degrees(shown ? 0 : -25))
        case .unplugged:
            // The plug pulls away from the socket and goes.
            Icon("powerplug.fill", size: 14, weight: .semibold)
                .rotationEffect(.degrees(90))
                .offset(x: shown ? -3 : 3)
                .opacity(shown ? 0.85 : 1)
        case .low:
            PulsingIcon(symbol: "exclamationmark", tint: .white)
        case .full:
            Icon("checkmark", size: 14, weight: .bold)
                .scaleEffect(shown ? 1 : 0.3)
        }
    }
}

private struct PulsingIcon: View {
    let symbol: String
    let tint: Color
    @State private var on = false

    var body: some View {
        Icon(symbol, size: 15, weight: .heavy)
            .foregroundStyle(tint)
            .scaleEffect(on ? 1.15 : 0.9)
            .onAppear {
                guard !IslandView.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// A battery drawn to the level: a gradient fill, a glow behind it while charging
/// and a band of light running along the fill.
private struct BatteryGlyph: View {
    var level: Double
    let battery: BatteryHUD

    var body: some View {
        let tint = battery.tint
        GeometryReader { proxy in
            let nub: CGFloat = 3
            let width = proxy.size.width - nub - 1.5
            let height = proxy.size.height
            let inner = CGSize(width: width - 6, height: height - 6)
            let fill = max(3, inner.width * level)
            ZStack(alignment: .leading) {
                // The glow under a charging battery.
                if battery.charging {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.45))
                        .frame(width: width, height: height)
                        .blur(radius: 8)
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(width: width, height: height)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: width, height: height)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill, height: inner.height)
                    .overlay {
                        if battery.charging { Shine().clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous)) }
                    }
                    .padding(.leading, 3)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.white.opacity(0.35))
                    .frame(width: nub, height: height * 0.38)
                    .offset(x: width + 1.5)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// A band of light running along a charging battery's fill, over and over.
private struct Shine: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: IslandView.reduceMotion)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14)
                    .offset(x: -14 + (proxy.size.width + 28) * phase)
                    .blendMode(.plusLighter)
            }
        }
        .opacity(IslandView.reduceMotion ? 0 : 1)
    }
}
