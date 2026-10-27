import SwiftUI

/// What the island's clock status is about, drawn by `ClockRow` instead of the
/// plain status line.
struct ClockStatus: Equatable {
    enum Kind: Equatable {
        /// The time, on the hour (or the chosen interval).
        case time
        /// A prayer has just begun.
        case prayer(Prayer)
        /// Prayer is not allowed until `end`.
        case forbidden(ForbiddenWindow.Kind, end: Date)
        /// A forbidden window has just ended.
        case allowed
    }

    let kind: Kind
    let time: Date
    var prayer: PrayerStatus? = nil
    var today: PrayerTimes? = nil

    /// The period's colours: dawn, day, afternoon, dusk, night — or the warning.
    var tint: [Color] {
        if case .forbidden = kind { return [.orange, .red] }
        switch prayer?.current {
        case .fajr: return [.indigo, .orange]
        case .none: return [.yellow, .orange]
        case .dhuhr: return [.yellow, .orange]
        case .asr: return [Self.ember, Self.red, Self.wine]
        case .maghrib: return [Self.red, Self.wine, Self.smoke]
        case .isha, .sunrise: return [.indigo, .blue]
        }
    }

    /// The afternoon and sunset reds: an ember, a hot red, the wine it cools into
    /// and the dark smoke behind it.
    static let ember = Color(red: 1.0, green: 0.42, blue: 0.14)
    static let red = Color(red: 0.93, green: 0.16, blue: 0.14)
    static let wine = Color(red: 0.55, green: 0.04, blue: 0.18)
    static let smoke = Color(red: 0.22, green: 0.02, blue: 0.08)

    /// How far through the current period we are (0…1), for the progress bar.
    var progress: Double? {
        guard let prayer else { return nil }
        let start: Date, end: Date
        if case .forbidden(_, let windowEnd) = kind, let window = prayer.forbidden {
            start = window.start
            end = windowEnd
        } else {
            start = prayer.starts
            end = prayer.ends
        }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return nil }
        return min(max(time.timeIntervalSince(start) / total, 0), 1)
    }
}

/// The island's clock: a period-coloured badge, the time in large digits with the
/// date under it, and — when prayer times are on — the current prayer with a bar
/// showing how much of it is left.
struct ClockRow: View {
    let status: ClockStatus

    var body: some View {
        HStack(spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                headline
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            if let side = sideTitle {
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(side)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    if let progress = status.progress {
                        Capsule()
                            .fill(.white.opacity(0.15))
                            .frame(width: 96, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(LinearGradient(colors: status.tint, startPoint: .leading, endPoint: .trailing))
                                    .frame(width: 96 * progress)
                            }
                    }
                    if let detail = sideDetail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        // The badge's 7 pt from the island's edge, as a status tile's; a touch above
        // centre, as a status sits.
        .padding(.leading, 7)
        .padding(.trailing, 18)
        .padding(.bottom, 4)
        .frame(maxHeight: .infinity)
    }

    private var badge: some View {
        ZStack {
            LiquidFill(colors: status.tint)
                .clipShape(Circle())
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Icon(symbol, size: 19, weight: .semibold)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
        .frame(width: 38, height: 38)
        .shadow(color: (status.tint.first ?? .white).opacity(0.5), radius: 8)
    }

    private var symbol: String {
        switch status.kind {
        case .time: status.prayer?.current?.symbol ?? "clock.fill"
        case .prayer(let prayer): prayer.symbol
        case .forbidden: "exclamationmark.triangle.fill"
        case .allowed: "checkmark.circle.fill"
        }
    }

    @ViewBuilder
    private var headline: some View {
        switch status.kind {
        case .time:
            clockDigits
        case .prayer(let prayer):
            // A notification: the prayer's name, with a bell.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(prayer.title) prayer").font(.system(size: 20, weight: .bold, design: .rounded))
                Icon("bell.fill", size: 14, weight: .bold).foregroundStyle(status.tint.last ?? .white)
            }
        case .forbidden:
            Text("Prayer not allowed").font(.system(size: 17, weight: .bold, design: .rounded))
        case .allowed:
            Text("Prayer allowed again").font(.system(size: 17, weight: .bold, design: .rounded))
        }
    }

    /// "3:00" large, "PM" small beside it (no "PM" in 24-hour locales).
    private var clockDigits: some View {
        let (digits, meridiem) = Self.parts(status.time)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(digits)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let meridiem {
                Text(meridiem).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private static let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
    private static let digitsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = twelveHour ? "h:mm" : "HH:mm"
        return formatter
    }()
    private static let meridiemFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "a"
        return formatter
    }()

    private static func parts(_ date: Date) -> (digits: String, meridiem: String?) {
        (digitsFormatter.string(from: date), twelveHour ? meridiemFormatter.string(from: date) : nil)
    }

    private var caption: String {
        switch status.kind {
        case .time: status.time.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .prayer: status.prayer.map { "Started \(PrayerClock.clock(status.time)) · until \(PrayerClock.clock($0.ends))" } ?? PrayerClock.clock(status.time)
        case .forbidden(let kind, let end): "\(kind.title) · until \(PrayerClock.clock(end))"
        case .allowed: status.prayer.map { $0.current.map { "\($0.title) time" } ?? "\($0.next.title) at \(PrayerClock.clock($0.nextStarts))" } ?? ""
        }
    }

    private var sideTitle: String? {
        guard let prayer = status.prayer else { return nil }
        switch status.kind {
        case .forbidden(let kind, _): return kind.title
        case .allowed: return nil
        case .prayer: return "\(PrayerClock.countdown(to: prayer.ends, from: status.time)) to pray"
        default:
            if let forbidden = prayer.forbidden { return "No prayer · \(forbidden.kind.title.lowercased())" }
            if let current = prayer.current { return "\(current.title) · until \(PrayerClock.clock(prayer.ends))" }
            return "\(prayer.next.title) at \(PrayerClock.clock(prayer.nextStarts))"
        }
    }

    private var sideDetail: String? {
        guard let prayer = status.prayer else { return nil }
        switch status.kind {
        case .forbidden(_, let end): return "\(PrayerClock.countdown(to: end, from: status.time)) to go"
        case .allowed: return nil
        case .prayer: return "then \(prayer.next.title) at \(PrayerClock.clock(prayer.nextStarts))"
        default:
            if let forbidden = prayer.forbidden { return "until \(PrayerClock.clock(forbidden.end))" }
            if prayer.current != nil { return "\(PrayerClock.countdown(to: prayer.ends, from: status.time)) left · then \(prayer.next.title)" }
            return "in \(PrayerClock.countdown(to: prayer.nextStarts, from: status.time))"
        }
    }
}

/// The prayer clock in the island's header: the current period and what is left of
/// it; hovering opens it into the whole day, the current period lit, with when it
/// closes.
struct PrayerPill: View {
    let clock: PrayerClock
    /// Open: the pill stretches to show the day's times inline (the island widens
    /// with it); a click toggles it.
    @Binding var expanded: Bool
    var onShowClock: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        let status = clock.status
        let forbidden = status?.forbidden != nil
        HStack(spacing: 8) {
            Icon(forbidden ? "exclamationmark.triangle.fill" : (status?.current ?? status?.next ?? .dhuhr).symbol, size: 13, weight: .medium)
                .foregroundStyle(forbidden ? .orange : .white.opacity(0.85))
            if expanded, let today = clock.today {
                times(today, status: status)
                    .transition(IslandView.reduceMotion
                                ? .opacity
                                : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)).animation(.easeOut(duration: 0.22).delay(0.06)),
                                              removal: .opacity.animation(.easeOut(duration: 0.1))))
                Button(action: onShowClock) {
                    Icon("arrow.up.left.and.arrow.down.right", size: 12, weight: .bold)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Open the clock")
                .accessibilityLabel("Open the clock")
                .transition(.opacity)
            } else if let pill = clock.pill {
                Text(pill)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .transition(IslandView.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .foregroundStyle(.white.opacity(0.78))
        .padding(.horizontal, 10)
        .frame(height: IslandChrome.controlHeight)
        .fixedSize()
        // Quiet until it matters: no fill unless hovered, opened or a forbidden time.
        .background(.white.opacity(forbidden ? 0.12 : (expanded || hovering ? 0.08 : 0)),
                    in: RoundedRectangle(cornerRadius: IslandChrome.controlRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: IslandChrome.controlRadius, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.86)) { expanded.toggle() }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(clock.prayerLine() ?? clock.pill ?? "Prayer times")
        .accessibilityHint(expanded ? "Hides the day's times" : "Shows the day's times")
        .accessibilityAddTraits(.isButton)
    }

    private func times(_ today: PrayerTimes, status: PrayerStatus?) -> some View {
        HStack(spacing: 10) {
            ForEach(today.ordered, id: \.prayer) { entry in
                let current = status?.current == entry.prayer || (status?.current == nil && entry.prayer == .sunrise && status?.next == .dhuhr)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.prayer.title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(current ? Color.brand : .white.opacity(0.5))
                    Text(PrayerClock.clock(entry.time))
                        .font(.system(size: 11, weight: current ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(current ? .white : .white.opacity(0.8))
                }
            }
            if let status {
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.forbidden.map { "No prayer · \($0.kind.title.lowercased())" } ?? status.current.map { "\($0.title) closes" } ?? "\(status.next.title) opens")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(status.forbidden == nil ? .white.opacity(0.5) : .orange)
                    Text(PrayerClock.clock(status.forbidden?.end ?? (status.current == nil ? status.nextStarts : status.ends)))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A tint that looks poured rather than printed: the colours swirl as soft, blurred
/// blobs over a dark base, with a highlight where light would catch the surface.
struct LiquidFill: View {
    let colors: [Color]

    var body: some View {
        let first = colors.first ?? .orange
        let middle = colors.count > 2 ? colors[1] : first
        let last = colors.last ?? .red
        GeometryReader { proxy in
            let size = proxy.size
            let unit = max(size.width, size.height)
            ZStack {
                LinearGradient(colors: [middle, last], startPoint: .top, endPoint: .bottom)
                // Smoke: the dark end curling up from the bottom.
                Ellipse()
                    .fill(last)
                    .frame(width: unit * 1.3, height: unit * 0.9)
                    .offset(x: unit * 0.2, y: unit * 0.45)
                    .blur(radius: unit * 0.22)
                // The hot pool, off-centre.
                Ellipse()
                    .fill(first)
                    .frame(width: unit * 0.95, height: unit * 0.75)
                    .offset(x: -unit * 0.22, y: -unit * 0.25)
                    .blur(radius: unit * 0.18)
                // A second, cooler swirl.
                Ellipse()
                    .fill(middle)
                    .frame(width: unit * 0.7, height: unit * 0.5)
                    .offset(x: unit * 0.25, y: -unit * 0.05)
                    .blur(radius: unit * 0.16)
                // The surface highlight.
                Ellipse()
                    .fill(.white.opacity(0.35))
                    .frame(width: unit * 0.6, height: unit * 0.3)
                    .offset(x: -unit * 0.18, y: -unit * 0.34)
                    .blur(radius: unit * 0.14)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .drawingGroup() // one texture, so the blurs cost nothing on every tick
    }
}
