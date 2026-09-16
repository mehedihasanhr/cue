import Foundation

/// The five daily prayers plus sunrise, which ends Fajr.
nonisolated enum Prayer: String, CaseIterable, Codable {
    case fajr, sunrise, dhuhr, asr, maghrib, isha

    var title: String {
        switch self {
        case .fajr: "Fajr"
        case .sunrise: "Sunrise"
        case .dhuhr: "Dhuhr"
        case .asr: "Asr"
        case .maghrib: "Maghrib"
        case .isha: "Isha"
        }
    }

    var symbol: String {
        switch self {
        case .fajr: "sunrise"
        case .sunrise: "sun.horizon"
        case .dhuhr: "sun.max"
        case .asr: "sun.min"
        case .maghrib: "sunset"
        case .isha: "moon.stars"
        }
    }

    /// Sunrise is a boundary, not a prayer.
    var isPrayer: Bool { self != .sunrise }
}

/// How Fajr and Isha are derived: the sun's depression angle for each, or, for
/// Isha, a fixed interval after Maghrib.
nonisolated enum CalculationMethod: String, CaseIterable, Codable {
    case muslimWorldLeague, isna, egyptian, ummAlQura, karachi, dubai, kuwait, qatar, singapore, turkey

    var title: String {
        switch self {
        case .muslimWorldLeague: "Muslim World League"
        case .isna: "ISNA (North America)"
        case .egyptian: "Egyptian General Authority"
        case .ummAlQura: "Umm al-Qura (Makkah)"
        case .karachi: "University of Karachi"
        case .dubai: "Dubai"
        case .kuwait: "Kuwait"
        case .qatar: "Qatar"
        case .singapore: "Singapore (MUIS)"
        case .turkey: "Turkey (Diyanet)"
        }
    }

    var fajrAngle: Double {
        switch self {
        case .muslimWorldLeague, .karachi, .kuwait, .qatar, .turkey: 18
        case .isna: 15
        case .egyptian: 19.5
        case .ummAlQura: 18.5
        case .dubai: 18.2
        case .singapore: 20
        }
    }

    /// Isha's depression angle, or nil when it is a fixed interval after Maghrib.
    var ishaAngle: Double? {
        switch self {
        case .muslimWorldLeague, .turkey: 17
        case .isna: 15
        case .egyptian, .kuwait: 17.5
        case .karachi, .singapore: 18
        case .dubai: 18.2
        case .ummAlQura, .qatar: nil
        }
    }

    /// Minutes after Maghrib for the interval methods.
    var ishaInterval: Int { 90 }
}

/// Asr begins when a shadow equals the object's length (plus the noon shadow):
/// once for most schools, twice for the Hanafi.
nonisolated enum Madhab: String, CaseIterable, Codable {
    case standard, hanafi

    var title: String {
        switch self {
        case .standard: "Standard (Shafi, Maliki, Hanbali)"
        case .hanafi: "Hanafi"
        }
    }

    var shadowFactor: Double { self == .hanafi ? 2 : 1 }
}

nonisolated struct Coordinates: Equatable, Codable {
    var latitude: Double
    var longitude: Double
}

/// The times prayer is not allowed: while the sun rises, stands at its zenith and
/// sets.
nonisolated struct ForbiddenWindow: Equatable {
    enum Kind: String {
        case sunrise, zenith, sunset

        var title: String {
            switch self {
            case .sunrise: "Sunrise"
            case .zenith: "Sun at its zenith"
            case .sunset: "Sunset"
            }
        }
    }

    let kind: Kind
    let start: Date
    let end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// One day's times, from sunrise/sunset geometry for a place and a method (the
/// algorithm behind praytimes.org and the Adhan libraries).
nonisolated struct PrayerTimes: Equatable {
    let date: Date
    let times: [Prayer: Date]
    let forbidden: [ForbiddenWindow]

    /// Minutes prayer is disliked after sunrise, before solar noon and before sunset.
    static let sunriseWindow: TimeInterval = 15 * 60
    static let zenithWindow: TimeInterval = 10 * 60
    static let sunsetWindow: TimeInterval = 15 * 60

    subscript(prayer: Prayer) -> Date { times[prayer]! }

    /// Times in the day's order.
    var ordered: [(prayer: Prayer, time: Date)] { Prayer.allCases.map { ($0, times[$0]!) } }

    /// `adjustments`: minutes added to each time (a local timetable's tweaks).
    init(on date: Date, at place: Coordinates, method: CalculationMethod, madhab: Madhab, adjustments: [Prayer: Int] = [:],
         timeZone: TimeZone = .current, calendar: Calendar = .current) {
        var calendar = calendar
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let jd = Self.julianDay(year: components.year!, month: components.month!, day: components.day!)
        let tz = Double(timeZone.secondsFromGMT(for: day)) / 3600
        let solar = SolarDay(julianDay: jd, latitude: place.latitude, longitude: place.longitude, timeZone: tz)

        // A first pass with the usual portions of the day, then a second one from the
        // results, as the sun's position drifts a little across the day.
        var t = Self.raw(solar, method: method, madhab: madhab, guesses: [.fajr: 5, .sunrise: 6, .dhuhr: 12, .asr: 13, .maghrib: 18, .isha: 18])
        t = Self.raw(solar, method: method, madhab: madhab, guesses: t)

        var times: [Prayer: Date] = [:]
        for (prayer, hours) in t {
            let minutes = (hours * 60).rounded() + Double(adjustments[prayer] ?? 0)
            times[prayer] = day.addingTimeInterval(minutes * 60)
        }
        self.date = day
        self.times = times
        forbidden = [
            ForbiddenWindow(kind: .sunrise, start: times[.sunrise]!, end: times[.sunrise]!.addingTimeInterval(Self.sunriseWindow)),
            ForbiddenWindow(kind: .zenith, start: times[.dhuhr]!.addingTimeInterval(-Self.zenithWindow), end: times[.dhuhr]!),
            ForbiddenWindow(kind: .sunset, start: times[.maghrib]!.addingTimeInterval(-Self.sunsetWindow), end: times[.maghrib]!),
        ]
    }

    /// One pass of the times as hours from local midnight.
    private static func raw(_ solar: SolarDay, method: CalculationMethod, madhab: Madhab, guesses: [Prayer: Double]) -> [Prayer: Double] {
        let horizon = 0.833 // refraction plus the sun's radius
        var t: [Prayer: Double] = [:]
        t[.dhuhr] = solar.noon(at: guesses[.dhuhr]!)
        t[.sunrise] = solar.time(angle: horizon, at: guesses[.sunrise]!, afterNoon: false)
        t[.maghrib] = solar.time(angle: horizon, at: guesses[.maghrib]!, afterNoon: true)
        t[.asr] = solar.asr(factor: madhab.shadowFactor, at: guesses[.asr]!)
        t[.fajr] = solar.time(angle: method.fajrAngle, at: guesses[.fajr]!, afterNoon: false)
        if let angle = method.ishaAngle {
            t[.isha] = solar.time(angle: angle, at: guesses[.isha]!, afterNoon: true)
        } else {
            t[.isha] = t[.maghrib]! + Double(method.ishaInterval) / 60
        }
        // Far north or south the sun may never reach the Fajr / Isha angle: take the
        // same fraction of the night the angle would at the equator (1/60 per degree).
        let night = 24 - (t[.maghrib]! - t[.sunrise]!)
        if t[.fajr]!.isNaN { t[.fajr] = t[.sunrise]! - night * method.fajrAngle / 60 }
        if t[.isha]!.isNaN { t[.isha] = t[.maghrib]! + night * (method.ishaAngle ?? 17) / 60 }
        return t
    }

    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year, m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = floor(Double(y) / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * Double(y + 4716)) + floor(30.6001 * Double(m + 1)) + Double(day) + b - 1524.5
    }
}

/// The sun over one place on one day: declination, equation of time, and the hour
/// at which it reaches a given angle below the horizon.
nonisolated private struct SolarDay {
    let julianDay: Double
    let latitude: Double
    let longitude: Double
    let timeZone: Double

    private func position(atHours hours: Double) -> (declination: Double, equationOfTime: Double) {
        let d = julianDay + hours / 24 - timeZone / 24 - 2451545.0
        let g = (357.529 + 0.98560028 * d).truncatingRemainder(dividingBy: 360)
        let q = (280.459 + 0.98564736 * d).truncatingRemainder(dividingBy: 360)
        let l = (q + 1.915 * sin(g.radians) + 0.020 * sin(2 * g.radians)).truncatingRemainder(dividingBy: 360)
        let e = 23.439 - 0.00000036 * d
        var ra = atan2(cos(e.radians) * sin(l.radians), cos(l.radians)).degrees / 15
        ra = (ra + 24).truncatingRemainder(dividingBy: 24)
        let eqt = q / 15 - ra
        let declination = asin(sin(e.radians) * sin(l.radians)).degrees
        return (declination, eqt)
    }

    /// Solar noon in local hours.
    func noon(at hours: Double) -> Double {
        let eqt = position(atHours: hours).equationOfTime
        return Self.fixHour(12 - eqt) - longitude / 15 + timeZone
    }

    /// The local hour the sun is `angle` degrees below the horizon, before or after noon.
    func time(angle: Double, at hours: Double, afterNoon: Bool) -> Double {
        let declination = position(atHours: hours).declination
        let noon = noon(at: hours)
        let cosH = (-sin(angle.radians) - sin(declination.radians) * sin(latitude.radians)) / (cos(declination.radians) * cos(latitude.radians))
        guard abs(cosH) <= 1 else { return .nan }
        let t = acos(cosH).degrees / 15
        return afterNoon ? noon + t : noon - t
    }

    func asr(factor: Double, at hours: Double) -> Double {
        let declination = position(atHours: hours).declination
        let angle = -atan(1 / (factor + tan(abs(latitude - declination).radians))).degrees
        return time(angle: angle, at: hours, afterNoon: true)
    }

    private static func fixHour(_ hour: Double) -> Double {
        let h = hour.truncatingRemainder(dividingBy: 24)
        return h < 0 ? h + 24 : h
    }
}

nonisolated private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

/// What the clock says about now: which prayer's time it is, when it ends, what
/// comes next, and whether prayer is currently not allowed.
nonisolated struct PrayerStatus: Equatable {
    /// The prayer whose time it is; nil between sunrise and Dhuhr.
    var current: Prayer?
    /// When the current period began (the last boundary).
    var starts: Date
    /// When the current period ends (the next boundary).
    var ends: Date
    var next: Prayer
    var nextStarts: Date
    /// The forbidden window we are in, if any.
    var forbidden: ForbiddenWindow?

    /// "Asr", or "Between Fajr and Dhuhr".
    var title: String {
        if let forbidden { return "Prayer not allowed · \(forbidden.kind.title.lowercased())" }
        if let current { return "\(current.title) time" }
        return "After sunrise"
    }

    /// Computed from today's and tomorrow's times.
    init(at now: Date, today: PrayerTimes, tomorrow: PrayerTimes) {
        let boundaries: [(Prayer, Date)] = today.ordered.map { ($0.prayer, $0.time) } + [(.fajr, tomorrow[.fajr])]
        if now < today[.fajr] {
            // Still last night's Isha (about where yesterday's Isha fell).
            current = .isha
            starts = today[.isha].addingTimeInterval(-86_400)
            ends = today[.fajr]
            next = .fajr
            nextStarts = today[.fajr]
        } else {
            var index = 0
            while index + 1 < boundaries.count, now >= boundaries[index + 1].1 { index += 1 }
            let (prayer, start) = boundaries[index]
            current = prayer == .sunrise ? nil : prayer
            starts = start
            ends = boundaries[index + 1].1
            next = boundaries[index + 1].0
            nextStarts = boundaries[index + 1].1
        }
        forbidden = (today.forbidden + tomorrow.forbidden).first { $0.contains(now) }
    }
}
