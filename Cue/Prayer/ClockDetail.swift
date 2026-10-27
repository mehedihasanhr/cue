import SwiftUI

/// The clock opened in the compact island (a click on the time status or the
/// prayer pill): the time to the second, today's date in both calendars, every
/// prayer time with the current period lit and how far through it we are, and the
/// times prayer is not allowed.
struct ClockDetail: View {
    let clock: PrayerClock?
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 12) {
                header(now)
                if let clock, let today = clock.today, let status = clock.status {
                    times(today, status: status, now: now)
                    period(status, now: now)
                    windows(today, status: status)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: clock?.enabled == true ? "location.slash" : "moon.stars")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        Text(clock?.enabled == true
                             ? "No prayer times yet — \(clock?.placeDescription.lowercased() ?? "no location")."
                             : "Prayer times are off. Turn them on to see the day's times here.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        Spacer(minLength: 0)
                        Button("Open Settings", action: openSettings)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // pinned under the notch, never centred
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .foregroundStyle(.white)
    }

    private var tint: [Color] {
        ClockStatus(kind: .time, time: .now, prayer: clock?.status, today: clock?.today).tint
    }

    /// The period's colour, for washes and the lit tile.
    private var accent: Color { tint.last ?? .orange }

    /// The time, and under it the day in both calendars as one line: the Hijri date
    /// follows the Gregorian one it belongs to. The period's colour lives here only.
    private func header(_ now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                StatusIcon(symbol: nil, tint: accent, size: 40)
                Icon(clock?.status?.current?.symbol ?? "clock.fill", size: 19, weight: .semibold)
                    .foregroundStyle(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom))
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Self.digits(now))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let meridiem = Self.meridiem(now) {
                        Text(meridiem).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                HStack(spacing: 6) {
                    Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text(Self.hijri(now))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(TimeZone.current.localizedName(for: .shortStandard, locale: .current) ?? TimeZone.current.identifier)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .modifier(DarkTile(radius: 7))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(now.formatted(date: .complete, time: .standard)), \(Self.hijri(now))")
    }

    /// The six times side by side, each on a dark tile with its symbol: the current
    /// one lit and washed with the period's colour, the next one tagged with how long
    /// until it, the rest quiet (dimmer once passed).
    private func times(_ today: PrayerTimes, status: PrayerStatus, now: Date) -> some View {
        EqualColumns(spacing: 6) {
            ForEach(today.ordered, id: \.prayer) { entry in
                let current = status.current == entry.prayer || (status.current == nil && entry.prayer == .sunrise)
                let next = !current && status.next == entry.prayer && entry.time > now
                let past = entry.time <= now && !current
                VStack(spacing: 3) {
                    Icon(entry.prayer.symbol, size: 14, weight: .semibold)
                        .foregroundStyle(current ? AnyShapeStyle(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom))
                                                 : AnyShapeStyle(.white.opacity(past ? 0.3 : 0.55)))
                        .frame(height: 16)
                    Text(entry.prayer.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(current ? 0.75 : 0.5))
                    Text(PrayerClock.clock(entry.time))
                        .font(.system(size: 12.5, weight: current || next ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(past ? 0.4 : (current || next ? 1 : 0.85)))
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .modifier(DarkTile(lit: current, wash: current ? accent : nil))
                .overlay(alignment: .top) {
                    if next {
                        Text("in \(PrayerClock.countdown(to: entry.time, from: now))")
                            .font(.system(size: 8.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .frame(height: 14)
                            .background(Capsule().fill(.white.opacity(0.85)))
                            .fixedSize()
                            .offset(y: -7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.prayer.title) \(PrayerClock.clock(entry.time))\(current ? ", now" : next ? ", next" : past ? ", passed" : "")")
            }
        }
        .padding(.top, 4) // room for the next one's tag
    }

    /// The current period with its bar and what comes next.
    private func period(_ status: PrayerStatus, now: Date) -> some View {
        let start = status.forbidden?.start ?? status.starts
        let end = status.forbidden?.end ?? status.ends
        let progress = min(max(now.timeIntervalSince(start) / max(end.timeIntervalSince(start), 1), 0), 1)
        // What is happening and how long it lasts; what comes next is already in the row above.
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let forbidden = status.forbidden {
                    Text("Prayer not allowed · \(forbidden.kind.title.lowercased())")
                        .foregroundStyle(Self.caution)
                } else if let current = status.current {
                    Text("\(current.title) until \(PrayerClock.clock(status.ends))")
                } else {
                    Text("\(status.next.title) at \(PrayerClock.clock(status.nextStarts))")
                }
                Spacer(minLength: 8)
                Text("\(PrayerClock.countdown(to: status.forbidden?.end ?? (status.current != nil ? status.ends : status.nextStarts), from: now)) left")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            Capsule()
                .fill(.black.opacity(0.45))
                .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(status.forbidden == nil
                                  ? AnyShapeStyle(LinearGradient(colors: tint, startPoint: .leading, endPoint: .trailing))
                                  : AnyShapeStyle(Self.caution))
                            .frame(width: max(5, proxy.size.width * progress))
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(DarkTile())
    }

    /// The windows prayer is not allowed in, as one row of compact chips; the live
    /// one in the caution colour.
    private func windows(_ today: PrayerTimes, status: PrayerStatus) -> some View {
        HStack(spacing: 6) {
            Text("Avoid")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .accessibilityAddTraits(.isHeader)
            ForEach(today.forbidden, id: \.start) { window in
                let live = status.forbidden == window
                HStack(spacing: 5) {
                    Image(systemName: window.kind.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(live ? Self.caution : .white.opacity(0.45))
                    Text(window.kind.shortTitle)
                        .foregroundStyle(live ? Self.caution : .white.opacity(0.6))
                    Text(Self.range(window.start, window.end))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(live ? 0.95 : 0.8))
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 26)
                .modifier(DarkTile(radius: 8, wash: live ? Self.caution : nil))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(window.kind.shortTitle), \(PrayerClock.clock(window.start)) to \(PrayerClock.clock(window.end))\(live ? ", now" : "")")
            }
            Spacer(minLength: 0)
        }
    }

    /// One soft amber for "not now", in place of reds and oranges.
    private static let caution = Color(red: 1.0, green: 0.72, blue: 0.32)

    /// "5:46–6:01 AM", or "11:42 AM–12:02 PM" when the window crosses noon.
    private static func range(_ start: Date, _ end: Date) -> String {
        let from = PrayerClock.clock(start), to = PrayerClock.clock(end)
        // The time and AM/PM are joined by a narrow no-break space in most locales.
        let fromParts = from.split(whereSeparator: \.isWhitespace), toParts = to.split(whereSeparator: \.isWhitespace)
        guard twelveHour, fromParts.count == 2, toParts.count == 2, fromParts[1] == toParts[1] else { return "\(from)–\(to)" }
        return "\(fromParts[0])–\(to)"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                KeyCap("esc")
                Text("close").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
            Spacer(minLength: 0)
            if let clock, clock.today != nil {
                Text(clock.methodSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .help("How the times are worked out — change it in Time settings")
            }
            Button(action: openSettings) {
                Label("Time settings", systemImage: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10).frame(height: 26)
                    .modifier(DarkTile(radius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Layout

    /// The island's tiles: dark, a little lighter at the top, a hairline catching the
    /// light; `lit` lifts one, `wash` tints it.
    struct DarkTile: ViewModifier {
        var lit = false
        var radius: CGFloat = 12
        var wash: Color? = nil

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .background {
                    shape.fill(LinearGradient(colors: [Color(white: lit ? 0.2 : 0.1), Color(white: lit ? 0.13 : 0.065)],
                                              startPoint: .top, endPoint: .bottom))
                    if let wash {
                        shape.fill(LinearGradient(colors: [wash.opacity(0.28), wash.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(lit ? 0.16 : 0.08), .white.opacity(0.02)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }

    /// Children side by side at one width each: the widest one's when unconstrained
    /// (so the island can be measured to fit), or an equal share of the width given.
    struct EqualColumns: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard !subviews.isEmpty else { return .zero }
            let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
            let gaps = spacing * CGFloat(subviews.count - 1)
            let widest = ideal.map(\.width).max() ?? 0
            let column = proposal.width.map { max(($0 - gaps) / CGFloat(subviews.count), widest) } ?? widest
            return CGSize(width: column * CGFloat(subviews.count) + gaps, height: ideal.map(\.height).max() ?? 0)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard !subviews.isEmpty else { return }
            let gaps = spacing * CGFloat(subviews.count - 1)
            let column = (bounds.width - gaps) / CGFloat(subviews.count)
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + (column + spacing) * CGFloat(index)
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: column, height: bounds.height))
            }
        }
    }

    // MARK: - Formatting

    // Formatters are dear to make and this view redraws every second: one of each.
    private static let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true

    private static let digitsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = twelveHour ? "h:mm:ss" : "HH:mm:ss"
        return formatter
    }()

    private static let meridiemFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "a"
        return formatter
    }()

    private static let hijriFormatter: DateFormatter = {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.locale = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("d MMMM y G")
        return formatter
    }()

    private static func digits(_ date: Date) -> String { digitsFormatter.string(from: date) }

    private static func meridiem(_ date: Date) -> String? { twelveHour ? meridiemFormatter.string(from: date) : nil }

    /// "23 Rabiʿ al-Awwal 1448 AH".
    private static func hijri(_ date: Date) -> String { hijriFormatter.string(from: date) }
}
