import AppKit
import AVFoundation
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

    /// Prayer times are turned on in Settings (times still need a place).
    var enabled: Bool { preferences.timeEnabled && preferences.prayerTimesEnabled }
    /// The place the times are for (current or manual), once known.
    private(set) var place: Coordinates?
    /// A word about where the place came from, for Settings.
    private(set) var placeDescription = "Locating…"
    /// "Umm al-Qura · Hanafi" — how the times are worked out, for a footnote.
    var methodSummary: String {
        preferences.prayerMadhab == .hanafi ? "\(preferences.prayerMethod.shortTitle) · Hanafi" : preferences.prayerMethod.shortTitle
    }
    private(set) var today: PrayerTimes?
    private(set) var tomorrow: PrayerTimes?
    /// Where we are in the day; refreshed at every boundary and each minute.
    private(set) var status: PrayerStatus?
    /// Ticks once a minute so countdowns in the panel stay right.
    private(set) var minute = Date()

    @ObservationIgnored private var eventTimer: Timer?
    /// What the event timer was armed for, so a late firing (App Nap, sleep) still
    /// shows what fell due instead of skipping to the next tick.
    @ObservationIgnored private var armed: [(date: Date, event: Event)] = []
    /// Keeps App Nap from stretching the timers while there is something to show.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    /// Fires shortly before the next event, to hold App Nap off for it.
    @ObservationIgnored private var prepareTimer: Timer?
    @ObservationIgnored private var minuteTimer: Timer?
    @ObservationIgnored private var locationManager: CLLocationManager?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Says the time and prayers aloud when that's on; kept so speech isn't cut off.
    /// Made the first time something is said: most clocks never speak.
    @ObservationIgnored private lazy var speech = AVSpeechSynthesizer()

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
            return (preferences.timeEnabled && preferences.prayerTimesEnabled, preferences.prayerLocationMode, preferences.prayerManualPlace)
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
        Log.app.info("Island clock: \(self.preferences.timeEnabled ? "on" : "off"), prayer times \(self.preferences.prayerTimesEnabled ? "on" : "off"), place \(self.placeDescription, privacy: .public), every \(self.preferences.timeStatusInterval) min")
        guard enabled, let place else {
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
        if preferences.timeEnabled, preferences.timeStatusInterval > 0 {
            events.append((Self.nextTick(after: now, everyMinutes: preferences.timeStatusInterval), .time))
        }
        return events.filter { $0.0 > now }.sorted { $0.0 < $1.0 }
    }

    private func armTimer() {
        eventTimer?.invalidate()
        let upcoming = upcomingEvents(after: Date())
        guard let next = upcoming.first else {
            eventTimer = nil
            armed = []
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            return
        }
        // Everything that shares the next moment (a prayer and a window can coincide).
        armed = upcoming.filter { $0.date.timeIntervalSince(next.date) < 1 }
        // App Nap is held off only for the last half minute before the moment, so the
        // event lands on time. Held for as long as anything was pending — all day — it
        // kept the whole app awake and stopped macOS from easing every other timer in it.
        prepareTimer?.invalidate()
        if next.date.timeIntervalSinceNow <= Self.holdOff {
            holdAppNap()
        } else {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            let prepare = Timer(fire: next.date.addingTimeInterval(-Self.holdOff), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdAppNap() }
            }
            prepare.tolerance = 10
            RunLoop.main.add(prepare, forMode: .common)
            prepareTimer = prepare
        }
        let timer = Timer(fire: next.date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
        Log.app.info("Island clock: next \(String(describing: next.event), privacy: .public) at \(next.date.formatted(date: .omitted, time: .standard), privacy: .public)")
    }

    /// How long before an event App Nap is held off.
    private static let holdOff: TimeInterval = 30

    private func holdAppNap() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Island clock")
    }

    /// Shows what the timer was armed for, then waits for the next event. A firing
    /// that comes very late (the Mac was asleep) is dropped rather than announced
    /// long after the fact.
    private func fire() {
        let now = Date()
        updateStatus()
        let due = armed.filter { now.timeIntervalSince($0.date) < 10 * 60 }
        Log.app.info("Island clock: fired, \(due.count) due, late by \(Int(now.timeIntervalSince(self.armed.first?.date ?? now)))s")
        if let event = due.map(\.event).first(where: { $0 != .time }) ?? due.first?.event {
            showStatus(status(for: event, at: now), true)
            speak(event, at: now)
        }
        armTimer()
    }

    /// Shows the time status now (Settings, while its options are being chosen).
    func preview() {
        updateStatus()
        showStatus(status(for: .time, at: Date()), false)
        speak(.time, at: Date())
    }

    /// Says what the island shows, in a sentence: "It's 3:00 PM. Asr at 3:20 PM."
    private func speak(_ event: Event, at now: Date) {
        guard preferences.timeSpoken else { return }
        let line: String
        switch event {
        case .prayer(let prayer):
            line = "It's time for \(prayer.title) prayer."
        case .forbiddenStart:
            line = "Prayer is not allowed until \(Self.clock(status?.forbidden?.end ?? now))."
        case .forbiddenEnd:
            line = "Prayer is allowed again."
        case .time:
            var words = "It's \(Self.clock(now))."
            if let status, status.forbidden == nil {
                words += " \(status.next.title) at \(Self.clock(status.nextStarts))."
            }
            line = words
        }
        // A prayer's line waits for its chime.
        if case .prayer = event { say(line, after: 1) } else { say(line) }
    }

    /// Says a line in the chosen voice, softly and a little slower than usual.
    func say(_ line: String, after delay: TimeInterval = 0) {
        speech.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = Self.voice(preferences.timeVoice)
        utterance.volume = Float(min(max(preferences.timeVoiceVolume, 0.1), 1))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.05
        utterance.preUtteranceDelay = delay
        speech.speak(utterance)
    }

    /// Gentle voices, sweetest first, for when several sound as good.
    private static let sweet = ["Samantha", "Ava", "Zoe", "Allison", "Susan", "Karen", "Moira", "Tessa", "Serena", "Veena"]

    /// Voices that suit it, in the Mac's language: no novelty voices (Bells, Bubbles…),
    /// the best sounding first, then the gentlest. (A sandboxed app isn't offered
    /// the downloaded premium voices; any enhanced one it is offered comes first.)
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.identifier.contains(".siri.") }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if (a.language == language) != (b.language == language) { return a.language == language }
                let rank = { (voice: AVSpeechSynthesisVoice) in sweet.firstIndex(of: voice.name) ?? sweet.count }
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                if (a.gender == .female) != (b.gender == .female) { return a.gender == .female }
                // The fuller of two voices with one name ("compact" over "super-compact").
                if a.name == b.name { return !a.identifier.contains("super-compact") }
                return a.name < b.name
            }
    }

    /// The chosen voice, or the sweetest one installed.
    static func voice(_ identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) { return chosen }
        return voices().first
    }

    /// Every event is drawn by `ClockRow`; the plain title/subtitle serve the HUD
    /// when there is no island.
    private func status(for event: Event, at now: Date) -> IslandStatus {
        let kind: ClockStatus.Kind
        let symbol: String, title: String, subtitle: String?, duration: Duration
        switch event {
        case .prayer(let prayer):
            kind = .prayer(prayer)
            (symbol, title, subtitle, duration) = (prayer.symbol, "\(prayer.title) prayer · \(Self.clock(now))", untilNext(), .seconds(8))
            if preferences.soundEnabled { NSSound(named: "Glass")?.play() } // a notification, so a chime
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
