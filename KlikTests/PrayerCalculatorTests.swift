import XCTest

/// Prayer times against published values (to the minute or two the methods differ by).
final class PrayerCalculatorTests: XCTestCase {
    private func minutes(_ date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return c.hour! * 60 + c.minute!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func assertTime(_ times: PrayerTimes, _ prayer: Prayer, _ hh: Int, _ mm: Int, in zone: TimeZone, tolerance: Int = 2, line: UInt = #line) {
        let got = minutes(times[prayer], in: zone)
        XCTAssertLessThanOrEqual(abs(got - (hh * 60 + mm)), tolerance, "\(prayer) was \(got / 60):\(String(format: "%02d", got % 60)), expected \(hh):\(String(format: "%02d", mm))", line: line)
    }

    /// Makkah, 1 January 2024, Umm al-Qura. The official calendar (5:38 · 7:01 · 12:26 ·
    /// 3:31 · 5:51 · 7:21) pads the geometry by a minute or two; we allow three.
    func testMakkahUmmAlQura() {
        let zone = TimeZone(identifier: "Asia/Riyadh")!
        let times = PrayerTimes(on: day(2024, 1, 1, in: zone), at: Coordinates(latitude: 21.4225, longitude: 39.8262), method: .ummAlQura, madhab: .standard, timeZone: zone)
        assertTime(times, .fajr, 5, 38, in: zone, tolerance: 3)
        assertTime(times, .sunrise, 7, 1, in: zone, tolerance: 3)
        assertTime(times, .dhuhr, 12, 26, in: zone, tolerance: 3)
        assertTime(times, .asr, 15, 31, in: zone, tolerance: 3)
        assertTime(times, .maghrib, 17, 51, in: zone, tolerance: 3)
        assertTime(times, .isha, 19, 21, in: zone, tolerance: 3)
        // Isha is exactly 90 minutes after Maghrib for this method.
        XCTAssertEqual(times[.isha].timeIntervalSince(times[.maghrib]), 90 * 60)
    }

    /// London at the March equinox: sunrise 6:02, sunset 18:14 GMT, solar noon 12:08.
    func testLondonEquinoxSunriseAndSunset() {
        let zone = TimeZone(identifier: "Europe/London")!
        let times = PrayerTimes(on: day(2024, 3, 20, in: zone), at: Coordinates(latitude: 51.5074, longitude: -0.1278), method: .muslimWorldLeague, madhab: .standard, timeZone: zone)
        assertTime(times, .sunrise, 6, 2, in: zone)
        assertTime(times, .dhuhr, 12, 8, in: zone)
        assertTime(times, .maghrib, 18, 14, in: zone)
        // Hanafi Asr is later than the standard one.
        let hanafi = PrayerTimes(on: day(2024, 3, 20, in: zone), at: Coordinates(latitude: 51.5074, longitude: -0.1278), method: .muslimWorldLeague, madhab: .hanafi, timeZone: zone)
        XCTAssertGreaterThan(hanafi[.asr], times[.asr])
    }

    /// Dhaka, 16 September 2026 (Islamic Foundation-style, Karachi method): sunrise about 5:45, Maghrib about 6:03.
    func testDhakaOrderingAndWindows() {
        let zone = TimeZone(identifier: "Asia/Dhaka")!
        let times = PrayerTimes(on: day(2026, 9, 16, in: zone), at: Coordinates(latitude: 23.8103, longitude: 90.4125), method: .karachi, madhab: .hanafi, timeZone: zone)
        assertTime(times, .sunrise, 5, 45, in: zone, tolerance: 3)
        assertTime(times, .maghrib, 18, 3, in: zone, tolerance: 3)
        let ordered = times.ordered.map(\.time)
        XCTAssertEqual(ordered, ordered.sorted())
        XCTAssertEqual(times.forbidden.map(\.kind), [.sunrise, .zenith, .sunset])
        XCTAssertEqual(times.forbidden[0].start, times[.sunrise])
        XCTAssertEqual(times.forbidden[1].end, times[.dhuhr])
        XCTAssertEqual(times.forbidden[2].end, times[.maghrib])
    }

    /// Tromsø in midsummer: the sun never reaches the Fajr angle, so the night is
    /// divided instead — every time still exists and stays in order.
    func testHighLatitudeFallback() {
        let zone = TimeZone(identifier: "Europe/Oslo")!
        let times = PrayerTimes(on: day(2024, 5, 1, in: zone), at: Coordinates(latitude: 69.6492, longitude: 18.9553), method: .muslimWorldLeague, madhab: .standard, timeZone: zone)
        for (_, time) in times.ordered { XCTAssertFalse(time.timeIntervalSince1970.isNaN) }
        XCTAssertLessThan(times[.fajr], times[.sunrise])
        XCTAssertLessThan(times[.maghrib], times[.isha])
    }

    func testAdjustmentsShiftOnlyTheirPrayer() {
        let zone = TimeZone(identifier: "Asia/Riyadh")!
        let place = Coordinates(latitude: 21.4225, longitude: 39.8262)
        let plain = PrayerTimes(on: day(2024, 1, 1, in: zone), at: place, method: .ummAlQura, madhab: .standard, timeZone: zone)
        let nudged = PrayerTimes(on: day(2024, 1, 1, in: zone), at: place, method: .ummAlQura, madhab: .standard, adjustments: [.fajr: 3, .asr: -2], timeZone: zone)
        XCTAssertEqual(nudged[.fajr].timeIntervalSince(plain[.fajr]), 180)
        XCTAssertEqual(nudged[.asr].timeIntervalSince(plain[.asr]), -120)
        XCTAssertEqual(nudged[.dhuhr], plain[.dhuhr])
        // The forbidden windows follow the adjusted times.
        XCTAssertEqual(nudged.forbidden[2].end, nudged[.maghrib])
    }

    func testStatusWalksThroughTheDay() {
        let zone = TimeZone(identifier: "Asia/Riyadh")!
        let place = Coordinates(latitude: 21.4225, longitude: 39.8262)
        let today = PrayerTimes(on: day(2024, 1, 1, in: zone), at: place, method: .ummAlQura, madhab: .standard, timeZone: zone)
        let tomorrow = PrayerTimes(on: day(2024, 1, 2, in: zone), at: place, method: .ummAlQura, madhab: .standard, timeZone: zone)

        let beforeFajr = PrayerStatus(at: today[.fajr].addingTimeInterval(-3600), today: today, tomorrow: tomorrow)
        XCTAssertEqual(beforeFajr.current, .isha)
        XCTAssertEqual(beforeFajr.next, .fajr)

        let midMorning = PrayerStatus(at: today[.sunrise].addingTimeInterval(3600), today: today, tomorrow: tomorrow)
        XCTAssertNil(midMorning.current)
        XCTAssertEqual(midMorning.next, .dhuhr)
        XCTAssertNil(midMorning.forbidden)

        let justAfterSunrise = PrayerStatus(at: today[.sunrise].addingTimeInterval(60), today: today, tomorrow: tomorrow)
        XCTAssertEqual(justAfterSunrise.forbidden?.kind, .sunrise)

        let asr = PrayerStatus(at: today[.asr].addingTimeInterval(600), today: today, tomorrow: tomorrow)
        XCTAssertEqual(asr.current, .asr)
        XCTAssertEqual(asr.ends, today[.maghrib])
        XCTAssertEqual(asr.next, .maghrib)

        let lateNight = PrayerStatus(at: today[.isha].addingTimeInterval(4 * 3600), today: today, tomorrow: tomorrow)
        XCTAssertEqual(lateNight.current, .isha)
        XCTAssertEqual(lateNight.nextStarts, tomorrow[.fajr])
    }
}
