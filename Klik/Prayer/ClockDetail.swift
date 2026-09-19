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
            VStack(alignment: .leading, spacing: 10) {
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

    private func header(_ now: Date) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                Image(systemName: clock?.status?.current?.symbol ?? "clock.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            .frame(width: 44, height: 44)
            .shadow(color: (tint.first ?? .white).opacity(0.5), radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Self.digits(now))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if let meridiem = Self.meridiem(now) {
                        Text(meridiem).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.hijri(now))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(TimeZone.current.localizedName(for: .shortStandard, locale: .current) ?? TimeZone.current.identifier)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(now.formatted(date: .complete, time: .standard)), \(Self.hijri(now))")
    }

    /// The six times side by side, the current one lit.
    private func times(_ today: PrayerTimes, status: PrayerStatus, now: Date) -> some View {
        EqualColumns(spacing: 6) {
            ForEach(today.ordered, id: \.prayer) { entry in
                let current = status.current == entry.prayer || (status.current == nil && entry.prayer == .sunrise)
                let next = !current && status.next == entry.prayer && entry.time > now
                let past = entry.time <= now && !current
                VStack(spacing: 3) {
                    Image(systemName: entry.prayer.symbol).font(.system(size: 11, weight: .semibold))
                    Text(next ? "Next · \(entry.prayer.title)" : entry.prayer.title).font(.system(size: 10, weight: .semibold))
                    Text(PrayerClock.clock(entry.time)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .foregroundStyle(current ? .black : .white.opacity(past ? 0.45 : 0.9))
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(current ? AnyShapeStyle(LinearGradient(colors: tint.map { $0.opacity(0.95) }, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(next ? 0.1 : 0.07)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(next ? 0.35 : 0), lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.prayer.title) \(PrayerClock.clock(entry.time))\(current ? ", now" : next ? ", next" : past ? ", passed" : "")")
            }
        }
    }

    /// The current period with its bar and what comes next.
    private func period(_ status: PrayerStatus, now: Date) -> some View {
        let start = status.forbidden?.start ?? status.starts
        let end = status.forbidden?.end ?? status.ends
        let progress = min(max(now.timeIntervalSince(start) / max(end.timeIntervalSince(start), 1), 0), 1)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let forbidden = status.forbidden {
                    Label("Prayer not allowed · \(forbidden.kind.title.lowercased())", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let current = status.current {
                    Text("\(current.title) · until \(PrayerClock.clock(status.ends))")
                } else {
                    Text("After sunrise · \(status.next.title) at \(PrayerClock.clock(status.nextStarts))")
                }
                Spacer(minLength: 8)
                Text(status.forbidden.map { "\(PrayerClock.countdown(to: $0.end, from: now)) to go" }
                     ?? (status.current != nil ? "\(PrayerClock.countdown(to: status.ends, from: now)) left · then \(status.next.title)"
                         : "in \(PrayerClock.countdown(to: status.nextStarts, from: now))"))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            Capsule()
                .fill(.white.opacity(0.12))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(LinearGradient(colors: status.forbidden == nil ? tint : [.orange, .red], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * progress)
                    }
                }
        }
    }

    /// The three windows prayer is not allowed in, as columns wide enough for their
    /// times; the live one in orange.
    private func windows(_ today: PrayerTimes, status: PrayerStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Times to avoid")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityAddTraits(.isHeader)
            EqualColumns(spacing: 6) {
                ForEach(today.forbidden, id: \.start) { window in
                    let live = status.forbidden == window
                    HStack(spacing: 8) {
                        Image(systemName: window.kind.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(live ? .orange : .white.opacity(0.5))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(window.kind.shortTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(live ? .orange : .white.opacity(0.6))
                            Text(Self.range(window.start, window.end))
                                .font(.system(size: 11.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(live ? 1 : 0.85))
                        }
                        .fixedSize()
                        Spacer(minLength: 0)
                        if live {
                            Text("now")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background((live ? Color.orange : Color.white).opacity(live ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(window.kind.shortTitle), \(PrayerClock.clock(window.start)) to \(PrayerClock.clock(window.end))\(live ? ", now" : "")")
                }
            }
        }
    }

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
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Layout

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
