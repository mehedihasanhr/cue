import AppKit
import CoreLocation
import Observation
import os

/// The island's clock: shows the time at the chosen interval and, when prayer
/// times are on, announces each prayer and the times prayer is not allowed, all
/// computed on this Mac from the location. Nothing runs between events — one
/// timer sleeps until the next one.
@Observable
@MainActor
final class PrayerClock: NSObject {
    private let preferences: AppPreferences
    /// Shows a status on the island (or the HUD); set by the app delegate. `quiet`
    /// statuses wait for the island to be closed.
    var showStatus: (_ status: IslandStatus, _ quiet: Bool) -> Void = { _, _ in }

    /// The place the times are for (current or manual), once known.
    private(set) var place: Coordinates?
    /// A word about where the place came from, for Settings.
    private(set) var placeDescription = "Locating…"
    private(set) var today: PrayerTimes?
    private(set) var tomorrow: PrayerTimes?
    /// Where we are in the day; refreshed at every boundary and each minute.
    private(set) var status: PrayerStatus?
    /// Ticks once a minute so countdowns in the panel stay right.
    private(set) var minute = Date()

    @ObservationIgnored private var eventTimer: Timer?
    @ObservationIgnored private var minuteTimer: Timer?
    @ObservationIgnored private var locationManager: CLLocationManager?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        minuteTimer = Timer(fire: Self.nextMinute(), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.minute = Date()
                self.updateStatus()
            }
        }
        minuteTimer?.tolerance = 2
        RunLoop.main.add(minuteTimer!, forMode: .common)
        applyPreferences()
    }

    /// Re-reads the settings (and tracks them for changes).
    func applyPreferences() {
        let (enabled, mode, manual) = withObservationTracking {
            _ = preferences.prayerMethod
            _ = preferences.prayerMadhab
            _ = preferences.timeStatusInterval
            _ = preferences.prayerAnnouncements
            _ = preferences.prayerAdjustments
            return (preferences.prayerTimesEnabled, preferences.prayerLocationMode, preferences.prayerManualPlace)
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyPreferences() }
        }
        if enabled {
            switch mode {
            case .current:
                if let saved = preferences.prayerKnownPlace { place = saved; placeDescription = "Current location (last known)" }
                locate()
            case .manual:
                place = manual
                placeDescription = "Entered by hand"
            }
        }
        refresh()
    }

    // MARK: - Location

    /// Asks Core Location once; the fix is kept for next launch and for offline use.
    func locate() {
        if locationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager = manager
        }
        guard let manager = locationManager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            placeDescription = "Waiting for permission…"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            placeDescription = place == nil ? "Location access denied — enter a place by hand" : "Current location (last known; access now denied)"
        default:
            manager.requestLocation()
        }
    }

    // MARK: - Times

    /// Recomputes today and tomorrow and re-arms the event timer.
    func refresh() {
        eventTimer?.invalidate()
        eventTimer = nil
        guard preferences.prayerTimesEnabled, let place else {
            today = nil
            tomorrow = nil
            status = nil
            armTimer()
            return
        }
        let now = Date()
        today = PrayerTimes(on: now, at: place, method: preferences.prayerMethod, madhab: preferences.prayerMadhab, adjustments: preferences.prayerAdjustments)
        tomorrow = PrayerTimes(on: Calendar.current.date(byAdding: .day, value: 1, to: now)!, at: place, method: preferences.prayerMethod,
                               madhab: preferences.prayerMadhab, adjustments: preferences.prayerAdjustments)
        updateStatus()
        armTimer()
    }

    private func updateStatus() {
        guard let today, let tomorrow else { status = nil; return }
        status = PrayerStatus(at: Date(), today: today, tomorrow: tomorrow)
    }

    /// What the island should say at a moment: a prayer starting, a forbidden window
    /// opening or closing, or the time.
    private enum Event: Equatable {
        case prayer(Prayer)
        case forbiddenStart(ForbiddenWindow.Kind)
        case forbiddenEnd(ForbiddenWindow.Kind)
        case time
    }

    /// Every upcoming event with its moment, soonest first.
    private func upcomingEvents(after now: Date) -> [(date: Date, event: Event)] {
        var events: [(Date, Event)] = []
        if preferences.prayerAnnouncements, let today, let tomorrow {
            for day in [today, tomorrow] {
                for (prayer, time) in day.ordered where prayer.isPrayer { events.append((time, .prayer(prayer))) }
                for window in day.forbidden {
                    events.append((window.start, .forbiddenStart(window.kind)))
                    events.append((window.end, .forbiddenEnd(window.kind)))
                }
            }
        }
        if preferences.timeStatusInterval > 0 {
            events.append((Self.nextTick(after: now, everyMinutes: preferences.timeStatusInterval), .time))
        }
        return events.filter { $0.0 > now }.sorted { $0.0 < $1.0 }
    }

    private func armTimer() {
        eventTimer?.invalidate()
        guard let next = upcomingEvents(after: Date()).first else { eventTimer = nil; return }
        let timer = Timer(fire: next.date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }

    /// Shows every event due now (several can share a moment), then waits for the next.
    private func fire() {
        let now = Date()
        updateStatus()
        // Anything within the last few seconds is "now"; a laptop asleep past an event
        // does not get a stale announcement.
        let due = upcomingEvents(after: now.addingTimeInterval(-5)).filter { $0.date <= now.addingTimeInterval(1) }
        if let event = due.map(\.event).first(where: { $0 != .time }) ?? due.first?.event {
            showStatus(status(for: event, at: now), true)
        }
        armTimer()
    }

    /// Shows the time status now (Settings, while its options are being chosen).
    func preview() {
        updateStatus()
        showStatus(status(for: .time, at: Date()), false)
    }

    /// Every event is drawn by `ClockRow`; the plain title/subtitle serve the HUD
    /// when there is no island.
    private func status(for event: Event, at now: Date) -> IslandStatus {
        let kind: ClockStatus.Kind
        let symbol: String, title: String, subtitle: String?, duration: Duration
        switch event {
        case .prayer(let prayer):
            kind = .prayer(prayer)
            (symbol, title, subtitle, duration) = (prayer.symbol, "\(prayer.title) · \(Self.clock(now))", untilNext(), .seconds(5))
        case .forbiddenStart(let windowKind):
            let end = status?.forbidden?.end ?? now
            kind = .forbidden(windowKind, end: end)
            (symbol, title, subtitle, duration) = ("exclamationmark.triangle.fill", "Prayer not allowed · \(windowKind.title.lowercased())", "Until \(Self.clock(end))", .seconds(5))
        case .forbiddenEnd:
            kind = .allowed
            (symbol, title, subtitle, duration) = ("checkmark.circle.fill", "Prayer allowed again", prayerLine(), .seconds(4))
        case .time:
            kind = .time
            (symbol, title, subtitle, duration) = ("clock", Self.clock(now), prayerLine() ?? now.formatted(.dateTime.weekday(.wide).month(.wide).day()), .seconds(4))
        }
        return IslandStatus(symbol: symbol, title: title, subtitle: subtitle, duration: duration,
                            clock: ClockStatus(kind: kind, time: now, prayer: status, today: today))
    }

    /// "Asr · ends 6:12 PM · Maghrib next", for subtitles and the panel pill.
    func prayerLine(at now: Date = Date()) -> String? {
        guard let status else { return nil }
        if let forbidden = status.forbidden {
            return "Prayer not allowed · \(forbidden.kind.title.lowercased()) until \(Self.clock(forbidden.end))"
        }
        if let current = status.current {
            return "\(current.title) · until \(Self.clock(status.ends)) · \(status.next.title) in \(Self.countdown(to: status.nextStarts, from: now))"
        }
        return "\(status.next.title) at \(Self.clock(status.nextStarts)) · in \(Self.countdown(to: status.nextStarts, from: now))"
    }

    /// The short form for the island's pill: "Asr · 1h 20m left".
    var pill: String? {
        guard let status else { return nil }
        if let forbidden = status.forbidden { return "No prayer · \(Self.countdown(to: forbidden.end, from: minute))" }
        if let current = status.current { return "\(current.title) · \(Self.countdown(to: status.ends, from: minute)) left" }
        return "\(status.next.title) in \(Self.countdown(to: status.nextStarts, from: minute))"
    }

    private func untilNext() -> String? {
        guard let status else { return nil }
        return "Until \(Self.clock(status.ends)) · then \(status.next.title)"
    }

    // MARK: - Helpers

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }

    /// The next multiple of `everyMinutes` on the clock (the hour, the half hour…).
    static func nextTick(after now: Date, everyMinutes: Int, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(day)
        let step = TimeInterval(everyMinutes * 60)
        return day.addingTimeInterval((floor(elapsed / step) + 1) * step)
    }

    private static func nextMinute() -> Date {
        let now = Date()
        return now.addingTimeInterval(60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
    }
}

extension PrayerClock: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard preferences.prayerTimesEnabled, preferences.prayerLocationMode == .current else { return }
            switch status {
            case .authorizedAlways, .authorized: locationManager?.requestLocation()
            case .denied, .restricted: locate() // updates the description
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let place = Coordinates(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        Task { @MainActor in
            guard preferences.prayerLocationMode == .current else { return }
            self.place = place
            preferences.prayerKnownPlace = place
            placeDescription = String(format: "Current location · %.3f, %.3f", place.latitude, place.longitude)
            refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Log.app.error("Location: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            if place == nil { placeDescription = "Could not find the location — enter a place by hand" }
        }
    }
}
