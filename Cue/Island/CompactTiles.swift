import SwiftUI

/// A small tile beside the closed notch, one on each side, so the island says a
/// little without opening: the time, the battery, a focus session counting down;
/// while music plays, its artwork on the left and the pixel Cue on the right.
enum CompactTile: String, CaseIterable, Equatable {
    case none, clock, battery, focus, calendar, weather
    /// Only while music plays (not offered as a choice).
    case artwork, critter

    static let choices: [CompactTile] = [.none, .clock, .weather, .battery, .focus, .calendar]

    var title: String {
        switch self {
        case .none: "Nothing"
        case .clock: "Clock"
        case .battery: "Battery"
        case .focus: "Focus timer"
        case .calendar: "Calendar"
        case .weather: "Weather"
        case .artwork: "Artwork"
        case .critter: "Cue"
        }
    }
}

/// The two sides, as they stand.
struct CompactTiles: Equatable {
    var left: CompactTile = .none
    var right: CompactTile = .none

    var isEmpty: Bool { left == .none && right == .none }

    /// How far each side reaches past the notch.
    static let sideWidth: CGFloat = 74
}

/// One tile's content, sized to the notch's height.
struct CompactTileView: View {
    let tile: CompactTile
    let height: CGFloat
    let nowPlaying: NowPlaying?
    let focus: FocusTimer?
    var calendar: CalendarWatcher? = nil
    var weather: WeatherStore? = nil

    var body: some View {
        Group {
            switch tile {
            case .none:
                Color.clear
            case .clock:
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            case .battery:
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    if let battery = BatteryMonitor.current(.unplugged) {
                        HStack(spacing: 5) {
                            MiniBattery(percent: battery.percent, charging: battery.charging)
                            Text("\(battery.percent)%")
                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(battery.percent <= 20 && !battery.charging ? Color(red: 1, green: 0.4, blue: 0.36) : .white)
                        }
                    }
                }
            case .focus:
                if let focus, focus.isRunning {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                            Circle().trim(from: 0, to: focus.progress)
                                .stroke(IslandStyle.accent, style: SwiftUI.StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 13, height: 13)
                        Text(focus.clock)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            case .calendar:
                if let calendar { CalendarTile(watcher: calendar) }
            case .weather:
                if let weather { WeatherTile(weather: weather) }
            case .artwork:
                if let nowPlaying {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1))
                        if let image = nowPlaying.artwork {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else if let icon = nowPlaying.player?.icon {
                            Image(nsImage: icon).resizable().scaledToFit().padding(2)
                        }
                    }
                    .frame(width: height * 0.62, height: height * 0.62)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            case .critter:
                if let nowPlaying {
                    CueCritter(side: height * 0.62, mood: .playing(nowPlaying.isPlaying, trackID: nowPlaying.track?.id))
                }
            }
        }
        .frame(width: CompactTiles.sideWidth, height: height)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }
}

private struct MiniBattery: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        let tint: Color = charging ? Color(red: 0.36, green: 0.85, blue: 0.45) : percent <= 20 ? Color(red: 1, green: 0.4, blue: 0.36) : .white
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(tint)
                    .frame(width: max(1.5, 15 * CGFloat(percent) / 100), height: 6)
                    .padding(.leading, 2)
            }
            .frame(width: 20, height: 10)
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.45)).frame(width: 1.5, height: 4)
        }
        .overlay {
            if charging { Icon("bolt.fill", size: 6, weight: .bold).foregroundStyle(.white).offset(x: -1) }
        }
    }
}
