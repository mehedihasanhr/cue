import CoreLocation
import SwiftUI

/// The weather where the user is, from Open-Meteo (free, no key, over the network
/// permission Cue has). The place is the prayer clock's when it has one, otherwise
/// Core Location's fix (the permission the prayer times use). Fetched every half hour.
@MainActor @Observable
final class WeatherStore: NSObject {
    struct Hour: Identifiable, Equatable {
        let id: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
    }

    struct Conditions: Equatable {
        let temperature: Double
        let feelsLike: Double
        let code: Int
        let isDay: Bool
        let high: Double
        let low: Double
        let hours: [Hour]
    }

    private(set) var conditions: Conditions?
    private(set) var place: String?
    /// "°C" or "°F": the Mac's own Temperature setting (Language & Region), or its
    /// region's custom when that was never set.
    let unit: String

    /// The prayer clock's place, when it has one; set by the controller.
    @ObservationIgnored var knownPlace: () -> CLLocationCoordinate2D? = { nil }
    @ObservationIgnored private var location: CLLocationManager?
    @ObservationIgnored private var located: CLLocationCoordinate2D?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fetchedFor: CLLocationCoordinate2D?

    override init() {
        switch UserDefaults.standard.string(forKey: "AppleTemperatureUnit") {
        case "Fahrenheit": unit = "°F"
        case "Celsius": unit = "°C"
        default: unit = Locale.current.measurementSystem == .us ? "°F" : "°C"
        }
        super.init()
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch() }
        }
        fetch()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var coordinate: CLLocationCoordinate2D? { knownPlace() ?? located }

    private func fetch() {
        guard let coordinate else {
            locate()
            return
        }
        let fahrenheit = unit == "°F" ? "&temperature_unit=fahrenheit" : ""
        let address = "https://api.open-meteo.com/v1/forecast?latitude=\(coordinate.latitude)&longitude=\(coordinate.longitude)"
            + "&current=temperature_2m,apparent_temperature,weather_code,is_day&hourly=temperature_2m,weather_code,is_day"
            + "&daily=temperature_2m_max,temperature_2m_min&forecast_days=2&timezone=auto\(fahrenheit)"
        guard let url = URL(string: address) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
            conditions = response.conditions()
            if fetchedFor.map({ abs($0.latitude - coordinate.latitude) > 0.05 || abs($0.longitude - coordinate.longitude) > 0.05 }) ?? true {
                fetchedFor = coordinate
                name(coordinate)
            }
        }
    }

    private func name(_ coordinate: CLLocationCoordinate2D) {
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) { [weak self] marks, _ in
            let name = marks?.first.flatMap { $0.locality ?? $0.subAdministrativeArea ?? $0.administrativeArea }
            Task { @MainActor in self?.place = name }
        }
    }

    private func locate() {
        if location == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            location = manager
        }
        guard let location else { return }
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted: break
        default: location.requestLocation()
        }
    }

    // MARK: - Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let weather_code: [Int]
            let is_day: [Int]
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let hourly: Hourly
        let daily: Daily
        let utc_offset_seconds: Int

        func conditions() -> Conditions {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd'T'HH:mm"
            format.timeZone = TimeZone(secondsFromGMT: utc_offset_seconds)
            let now = Date()
            var hours: [Hour] = []
            for (index, time) in hourly.time.enumerated() {
                guard let date = format.date(from: time), date > now, hours.count < 6 else { continue }
                hours.append(Hour(id: date, temperature: hourly.temperature_2m[index], code: hourly.weather_code[index], isDay: hourly.is_day[index] == 1))
            }
            return Conditions(temperature: current.temperature_2m, feelsLike: current.apparent_temperature, code: current.weather_code,
                              isDay: current.is_day == 1, high: daily.temperature_2m_max.first ?? current.temperature_2m,
                              low: daily.temperature_2m_min.first ?? current.temperature_2m, hours: hours)
        }
    }

    // MARK: - WMO weather codes

    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61, 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow showers"
        case 95, 96, 99: "Thunderstorm"
        default: "Cloudy"
        }
    }

    /// The sky's colour for a bead: blue by day, deep violet at night, grey under cloud.
    static func tint(_ code: Int, isDay: Bool) -> Color {
        if [95, 96, 99].contains(code) { return Color(red: 0.45, green: 0.38, blue: 0.75) }
        if code >= 45 { return Color(red: 0.42, green: 0.52, blue: 0.66) }
        return isDay ? Color(red: 0.25, green: 0.6, blue: 1.0) : Color(red: 0.3, green: 0.27, blue: 0.62)
    }
}

extension WeatherStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorized else { return }
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            located = coordinate
            fetch()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}

/// A weather symbol in its own colours (a yellow sun, white clouds, blue rain).
struct WeatherSymbol: View {
    let code: Int
    let isDay: Bool
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: WeatherStore.symbol(code, isDay: isDay))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size, weight: .medium))
    }
}

/// The weather beside the notch: the sky and the temperature.
struct WeatherTile: View {
    let weather: WeatherStore

    var body: some View {
        if let now = weather.conditions {
            HStack(spacing: 4) {
                WeatherSymbol(code: now.code, isDay: now.isDay, size: 13)
                Text("\(Int(now.temperature.rounded()))°")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }
}

/// The weather in the panel's header; a click opens the forecast.
struct WeatherPill: View {
    let weather: WeatherStore
    var onShow: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        if let now = weather.conditions {
            HStack(spacing: 6) {
                WeatherSymbol(code: now.code, isDay: now.isDay, size: 14)
                Text("\(Int(now.temperature.rounded()))°")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 11)
            .frame(height: IslandChrome.controlHeight)
            .background(.white.opacity(hovering ? 0.12 : 0.08), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onShow)
            .help("\(WeatherStore.describe(now.code)) · the next hours")
        }
    }
}

/// The forecast, opened in the island: a sky bead with the conditions, the
/// temperature large, the day's high and low, and the next six hours.
struct WeatherDetail: View {
    static let width: CGFloat = 460
    static let height: CGFloat = 150

    let weather: WeatherStore

    var body: some View {
        Group {
            if let now = weather.conditions {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            ZStack {
                                GlossyDisc(symbol: nil, tint: WeatherStore.tint(now.code, isDay: now.isDay), size: 50)
                                WeatherSymbol(code: now.code, isDay: now.isDay, size: 22)
                                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(Int(now.temperature.rounded()))°")
                                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                                Text("\(WeatherStore.describe(now.code)) · feels \(Int(now.feelsLike.rounded()))°")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        Text([weather.place, "H \(Int(now.high.rounded()))°  L \(Int(now.low.rounded()))°"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        ForEach(now.hours) { hour in
                            VStack(spacing: 6) {
                                Text(hour.id.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow))))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                WeatherSymbol(code: hour.code, isDay: hour.isDay, size: 15)
                                    .frame(height: 18)
                                Text("\(Int(hour.temperature.rounded()))°")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            }
                            .frame(width: 32)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            } else {
                Text("Finding the weather…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .frame(width: Self.width, height: Self.height)
    }
}
