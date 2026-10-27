import AppKit
import EventKit
import SwiftUI

/// A meeting about to start, as the island shows it.
struct MeetingHUD: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    /// The video call's link, if the event has one (Zoom, Meet, Teams, Webex…).
    let joinURL: URL?
    /// The calendar's colour.
    let color: Color

    var timeRange: String {
        let format = Date.FormatStyle.dateTime.hour().minute()
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }
}

/// The user's calendar, read with EventKit once they allow it: the next and the
/// current event, and a call back five minutes before each meeting.
@MainActor @Observable
final class CalendarWatcher {
    private(set) var next: EKEvent?
    private(set) var current: EKEvent?
    private(set) var authorized = false

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var alerted: Set<String> = []
    @ObservationIgnored var onAlert: (MeetingHUD) -> Void = { _ in }

    /// How long before a meeting the island says so.
    static let lead: TimeInterval = 5 * 60

    /// Asks for access (macOS shows its prompt the first time) and starts watching.
    func start() {
        guard timer == nil else { return }
        Task {
            let granted: Bool
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                granted = true
            } else {
                granted = (try? await store.requestFullAccessToEvents()) ?? false
            }
            authorized = granted
            guard granted else { return }
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        next = nil
        current = nil
    }

    private func refresh() {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
        current = events.last { $0.startDate <= now && $0.endDate > now }
        next = events.first { $0.startDate > now }
        // Five minutes ahead: once per event.
        for event in events where !alerted.contains(Self.key(event)) {
            let until = event.startDate.timeIntervalSince(now)
            guard until > 0, until <= Self.lead else { continue }
            alerted.insert(Self.key(event))
            onAlert(Self.hud(event))
        }
    }

    static func hud(_ event: EKEvent) -> MeetingHUD {
        MeetingHUD(id: key(event), title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                   joinURL: joinURL(event), color: event.calendar.map { Color(nsColor: $0.color) } ?? .blue)
    }

    private static func key(_ event: EKEvent) -> String {
        "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)"
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first { $0.isCurrentUser }?.participantStatus == .declined
    }

    /// A video call's link from the event's URL, place or notes.
    static func joinURL(_ event: EKEvent) -> URL? {
        let hosts = ["zoom.us/j", "zoom.us/my", "meet.google.com", "teams.microsoft.com/l/meetup-join", "teams.live.com/meet", "webex.com", "whereby.com", "facetime.apple.com"]
        if let url = event.url, hosts.contains(where: { url.absoluteString.contains($0) }) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, hosts.contains(where: { url.absoluteString.contains($0) }) { return url }
        }
        return nil
    }
}

/// The meeting in the island: a bead in its calendar's colour, its name, when, and
/// Join for a call.
struct MeetingRow: View {
    let meeting: MeetingHUD
    var onJoin: (URL) -> Void = { _ in }
    @State private var shown = false
    @State private var burst = false

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .strokeBorder(meeting.color.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(burst ? 1.9 : 1)
                    .opacity(burst ? 0 : 0.8)
                GlossyDisc(symbol: meeting.joinURL == nil ? "calendar" : "video.fill", tint: meeting.color, size: 38)
                    .scaleEffect(shown ? 1 : 0.5)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let minutes = max(0, Int((meeting.start.timeIntervalSince(context.date) / 60).rounded(.up)))
                    Text((minutes == 0 ? "Starting now" : "In \(minutes) min") + " · " + meeting.timeRange)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: 220, alignment: .leading)
            .offset(x: shown ? 0 : -6)
            .opacity(shown ? 1 : 0)
            Spacer(minLength: 12)
            if let url = meeting.joinURL {
                Button { onJoin(url) } label: {
                    HStack(spacing: 5) {
                        Icon("video.fill", size: 11, weight: .bold)
                        Text("Join").font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(Color(red: 0.2, green: 0.72, blue: 0.4), in: Capsule())
                    .shadow(color: Color(red: 0.2, green: 0.72, blue: 0.4).opacity(0.5), radius: 6)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .scaleEffect(shown ? 1 : 0.7)
                .help("Join the call")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .fixedSize()
        .onAppear {
            let motion = !IslandView.reduceMotion
            withAnimation(motion ? .spring(response: 0.45, dampingFraction: 0.75).delay(0.1) : .easeOut(duration: 0.15)) { shown = true }
            if motion { withAnimation(.easeOut(duration: 0.7).delay(0.15)) { burst = true } }
        }
    }
}

/// The calendar tile beside the notch: the event on now, its ring running down, or
/// how soon the next one starts.
struct CalendarTile: View {
    let watcher: CalendarWatcher

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let event = watcher.current {
                let total = event.endDate.timeIntervalSince(event.startDate)
                let left = event.endDate.timeIntervalSince(context.date)
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                        Circle().trim(from: 0, to: total > 0 ? max(0, min(1, 1 - left / total)) : 0)
                            .stroke(event.calendar.map { Color(nsColor: $0.color) } ?? .blue, style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text("\(max(1, Int(left / 60)))m left")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            } else if let event = watcher.next, event.startDate.timeIntervalSince(context.date) < 12 * 3600 {
                let minutes = Int(event.startDate.timeIntervalSince(context.date) / 60)
                HStack(spacing: 5) {
                    Circle().fill(event.calendar.map { Color(nsColor: $0.color) } ?? .blue).frame(width: 7, height: 7)
                    Text(minutes < 60 ? "in \(max(1, minutes))m" : event.startDate.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
