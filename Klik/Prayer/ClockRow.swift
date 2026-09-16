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
        case .asr: return [.orange, .pink]
        case .maghrib: return [.pink, .purple]
        case .isha, .sunrise: return [.indigo, .blue]
        }
    }

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
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(maxHeight: .infinity)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: status.tint, startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
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
                Image(systemName: "bell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(status.tint.last ?? .white)
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
    @State private var hovering = false

    var body: some View {
        let status = clock.status
        let forbidden = status?.forbidden != nil
        HStack(spacing: 8) {
            Image(systemName: forbidden ? "exclamationmark.triangle.fill" : (status?.current ?? status?.next ?? .dhuhr).symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(forbidden ? .orange : .white.opacity(0.85))
            if hovering, let today = clock.today {
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
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if let pill = clock.pill {
                Text(pill).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.white.opacity(forbidden ? 0.14 : 0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(hovering ? Color.white.opacity(0.18) : .clear))
        .fixedSize()
        .contentShape(Capsule())
        .onHover { over in withAnimation(.easeOut(duration: 0.18)) { hovering = over } }
    }
}
