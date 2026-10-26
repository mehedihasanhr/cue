import AppKit
import CoreAudio
import SwiftUI

/// What Apple Music or Spotify is playing, and their transport controls.
///
/// The system-wide Now Playing info is closed to other apps since macOS 15.4, and
/// to sandboxed ones before that; so each player is asked directly, over Apple
/// Events. Both post a distributed notification whenever a track or its state
/// changes, which is when Cue asks; a player that isn't running is never asked (that
/// would launch it). macOS asks the user once per player, the first time it plays
/// with Cue running — never at launch.
@MainActor @Observable
final class NowPlaying {
    enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var name: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            }
        }

        fileprivate var notification: String {
            switch self {
            case .music: "com.apple.Music.playerInfo"
            case .spotify: "com.spotify.client.PlaybackStateChanged"
            }
        }

        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
        var icon: NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    struct Track: Equatable {
        let id: String
        let title: String
        let artist: String
        let album: String
        /// Seconds.
        let duration: Double
    }

    private(set) var player: Player?
    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// Where the track was at `positionDate`; it runs on from there while playing.
    private var position: Double = 0
    private var positionDate = Date()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var permitted: Set<Player> = []
    /// Off in Settings: the players are neither asked nor followed.
    @ObservationIgnored var isEnabled: () -> Bool = { true }

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for player in Player.allCases {
            observers.append(center.addObserver(forName: Notification.Name(player.notification), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(player, mayAsk: true) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, id == self.player?.rawValue else { return }
                self.clear()
            }
        })
        // Already playing at launch: only from a player Cue may already talk to.
        for player in Player.allCases where player.isRunning { changed(player, mayAsk: false) }
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        clear()
    }

    /// Where the track is now (or at `date`).
    func position(at date: Date = .now) -> Double {
        guard let track else { return 0 }
        return min(isPlaying ? position + date.timeIntervalSince(positionDate) : position, track.duration)
    }

    #if DEBUG
    /// For diagnostics: a made-up track, playing in Music.
    func debugFake() {
        player = .music
        track = Track(id: "debug", title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 243)
        isPlaying = true
        position = 81
        positionDate = .now
        artwork = NSImage(named: "AppIcon")
    }
    #endif

    // MARK: - Controls

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = .now
        command("set player position to \(String(format: "%.2f", seconds))")
    }

    func openPlayer() {
        guard let player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The position again from the player (the view asks every second while open,
    /// so a seek in the player itself shows).
    func refreshPosition() {
        guard let player, permitted.contains(player), player.isRunning,
              let text = run("tell application id \"\(player.rawValue)\" to get player position"),
              let seconds = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
        position = seconds
        positionDate = .now
    }

    private func command(_ verb: String) {
        guard let player, permitted.contains(player), player.isRunning else { return }
        _ = run("tell application id \"\(player.rawValue)\" to \(verb)")
        // The player's own notification follows; the position is wanted at once.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            changed(player, mayAsk: false)
        }
    }

    // MARK: - Reading the player

    private func changed(_ source: Player, mayAsk: Bool) {
        guard isEnabled(), source.isRunning else { return }
        if permitted.contains(source) {
            read(source)
            return
        }
        // Asking may put up the consent prompt, which waits on the user: off the main thread.
        let id = source.rawValue
        Task.detached {
            let granted = Self.permission(for: id, ask: mayAsk)
            await MainActor.run { [weak self] in
                guard let self, granted else { return }
                permitted.insert(source)
                read(source)
            }
        }
    }

    nonisolated private static func permission(for bundleID: String, ask: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) == noErr
    }

    private func read(_ source: Player) {
        let id = source.rawValue
        let extra = source == .spotify ? " & linefeed & (artwork url of t)" : ""
        let script = """
        tell application id "\(id)"
            set s to player state as text
            if s is "stopped" then return "stopped"
            set t to current track
            return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position) & linefeed & (id of t)\(extra)
        end tell
        """
        guard let text = run(script) else { return }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 7, lines[0] != "stopped" else {
            if player == source { clear() }
            return
        }
        let playing = lines[0] == "playing"
        // The other player paused or stopped: keep showing the one that plays.
        if let player, player != source, isPlaying, !playing { return }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        // Music gives seconds, Spotify milliseconds.
        let duration = number(lines[4]) / (source == .spotify ? 1000 : 1)
        let new = Track(id: lines[6], title: lines[1], artist: lines[2], album: lines[3], duration: duration)
        if new.id != track?.id || source != player {
            artwork = nil
            loadArtwork(source, trackID: new.id, url: source == .spotify && lines.count > 7 ? URL(string: lines[7]) : nil)
        }
        player = source
        track = new
        isPlaying = playing
        position = number(lines[5])
        positionDate = .now
    }

    private func loadArtwork(_ source: Player, trackID: String, url: URL?) {
        switch source {
        case .music:
            let descriptor = runDescriptor("tell application id \"\(source.rawValue)\" to get raw data of artwork 1 of current track")
            if let data = descriptor?.data, !data.isEmpty { artwork = NSImage(data: data) }
        case .spotify:
            guard let url else { return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), track?.id == trackID else { return }
                artwork = NSImage(data: data)
            }
        }
    }

    private func clear() {
        player = nil
        track = nil
        isPlaying = false
        artwork = nil
    }

    private func run(_ source: String) -> String? {
        runDescriptor(source)?.stringValue
    }

    private func runDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

/// The Mac's sound outputs, and which one plays now.
enum AudioOutputs {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutput).compactMap { id in name(of: id).map { Device(id: id, name: $0) } }
    }

    static var current: AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func select(_ device: Device) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

// MARK: - Views

/// A few bars rising and falling while music plays; still when paused.
struct AudioBars: View {
    let playing: Bool
    var color: Color = IslandStyle.accent
    var height: CGFloat = 12

    private static let speeds: [Double] = [5.1, 7.3, 6.2, 8.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || IslandView.reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Self.speeds.indices, id: \.self) { index in
                    let wave = playing && !IslandView.reduceMotion ? (sin(time * Self.speeds[index] + Double(index)) + 1) / 2 : 0.15
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: max(3, height * (0.25 + 0.75 * wave)))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
    }
}

/// The track in the panel's header: artwork, the bars, the title, play/pause. A
/// click opens the player.
struct NowPlayingPill: View {
    let nowPlaying: NowPlaying
    var onShow: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        if let track = nowPlaying.track {
            HStack(spacing: 8) {
                Artwork(image: nowPlaying.artwork, player: nowPlaying.player, side: 24, radius: 6)
                AudioBars(playing: nowPlaying.isPlaying, height: 11)
                Text(track.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Button(action: nowPlaying.playPause) {
                    Icon(nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 11, weight: .bold)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(nowPlaying.isPlaying ? "Pause" : "Play")
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.leading, 4).padding(.trailing, 5)
            .frame(height: IslandChrome.controlHeight)
            .fixedSize()
            .background(.white.opacity(hovering ? 0.12 : 0.08), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onShow)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(track.title) by \(track.artist)")
        }
    }
}

/// The player, opened in the island: artwork, the track, a scrubber, the controls,
/// and where the sound goes.
struct NowPlayingDetail: View {
    static let width: CGFloat = 420
    static let height: CGFloat = 132

    let nowPlaying: NowPlaying
    let close: () -> Void
    @State private var scrub: Double?
    @State private var outputs: [AudioOutputs.Device] = []
    @State private var currentOutput = AudioOutputs.current

    var body: some View {
        HStack(spacing: 16) {
            Artwork(image: nowPlaying.artwork, player: nowPlaying.player, side: 96, radius: 16)
            VStack(alignment: .leading, spacing: 0) {
                if let track = nowPlaying.track {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.top, 2)
                    scrubber(track)
                        .padding(.top, 10)
                    controls
                        .padding(.top, 6)
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .frame(width: Self.width, height: Self.height)
        .task {
            // The player's own seeks show; the bars and the clock run on between.
            while !Task.isCancelled {
                nowPlaying.refreshPosition()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear {
            outputs = AudioOutputs.all()
            currentOutput = AudioOutputs.current
        }
    }

    private func scrubber(_ track: NowPlaying.Track) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = scrub ?? nowPlaying.position(at: context.date)
            let fraction = track.duration > 0 ? min(max(position / track.duration, 0), 1) : 0
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.white.opacity(scrub == nil ? 0.8 : 1))
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                    .frame(height: scrub == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrub = min(max(value.location.x / proxy.size.width, 0), 1) * track.duration
                        }
                        .onEnded { _ in
                            if let scrub { nowPlaying.seek(to: scrub) }
                            scrub = nil
                        })
                }
                .frame(height: 10)
                HStack {
                    Text(Self.time(position))
                    Spacer()
                    Text("-" + Self.time(max(track.duration - position, 0)))
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
            .animation(.easeOut(duration: 0.12), value: scrub == nil)
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(outputs) { device in
                    Button {
                        AudioOutputs.select(device)
                        currentOutput = device.id
                    } label: {
                        if device.id == currentOutput { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                    }
                }
            } label: {
                Icon("hifispeaker.fill", size: 12)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Play sound on…")
            Spacer()
            ControlButton(symbol: "backward.fill", size: 14, help: "Previous", action: nowPlaying.previous)
            ControlButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 20, help: nowPlaying.isPlaying ? "Pause" : "Play", action: nowPlaying.playPause)
                .padding(.horizontal, 10)
            ControlButton(symbol: "forward.fill", size: 14, help: "Next", action: nowPlaying.next)
            Spacer()
            Button(action: nowPlaying.openPlayer) {
                Group {
                    if let icon = nowPlaying.player?.icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    }
                }
                .frame(width: 20, height: 20)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(nowPlaying.player?.name ?? "the player")")
        }
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(symbol, size: size, weight: .bold)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: size + 18, height: size + 18)
                .background(.white.opacity(hovering ? 0.1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The track's artwork, or the player's icon until it has some.
private struct Artwork: View {
    let image: NSImage?
    let player: NowPlaying.Player?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(.white.opacity(0.08))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else if let icon = player?.icon {
                Image(nsImage: icon).resizable().scaledToFit().padding(side * 0.18)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .animation(.easeOut(duration: 0.25), value: image)
    }
}
