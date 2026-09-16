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
                    Spacer(minLength: 0)
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
                    Spacer(minLength: 0)
                }
                footer
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
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
    }

    /// The six times side by side, the current one lit.
    private func times(_ today: PrayerTimes, status: PrayerStatus, now: Date) -> some View {
        HStack(spacing: 6) {
            ForEach(today.ordered, id: \.prayer) { entry in
                let current = status.current == entry.prayer || (status.current == nil && entry.prayer == .sunrise)
                let past = entry.time <= now && !current
                VStack(spacing: 3) {
                    Image(systemName: entry.prayer.symbol).font(.system(size: 11, weight: .semibold))
                    Text(entry.prayer.title).font(.system(size: 10, weight: .semibold))
                    Text(PrayerClock.clock(entry.time)).font(.system(size: 12, weight: .bold)).monospacedDigit()
                }
                .foregroundStyle(current ? .black : .white.opacity(past ? 0.45 : 0.9))
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(current ? AnyShapeStyle(LinearGradient(colors: tint.map { $0.opacity(0.95) }, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(0.07)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func windows(_ today: PrayerTimes, status: PrayerStatus) -> some View {
        HStack(spacing: 6) {
            Text("Not allowed").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            ForEach(today.forbidden, id: \.start) { window in
                let live = status.forbidden == window
                Text("\(window.kind.title) \(PrayerClock.clock(window.start))–\(PrayerClock.clock(window.end))")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(live ? .orange : .white.opacity(0.7))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((live ? Color.orange : Color.white).opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                KeyCap("esc")
                Text("close").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            Spacer(minLength: 0)
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

    // MARK: - Formatting

    private static func twelveHour() -> Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
    }

    private static func digits(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = twelveHour() ? "h:mm:ss" : "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func meridiem(_ date: Date) -> String? {
        guard twelveHour() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "a"
        return formatter.string(from: date)
    }

    /// "23 Rabiʿ al-Awwal 1448 AH".
    private static func hijri(_ date: Date) -> String {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.locale = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("d MMMM y G")
        return formatter.string(from: date)
    }
}
