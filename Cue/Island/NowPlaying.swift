import AppKit
import CoreAudio
import SwiftUI

/// What Apple Music, Spotify or a YouTube tab is playing, and its controls.
///
/// The system-wide Now Playing info is closed to other apps since macOS 15.4, and
/// to sandboxed ones before that; so each player is asked directly, over Apple
/// Events. Music and Spotify post a distributed notification whenever a track or
/// its state changes, which is when Cue asks. Browsers post nothing: Cue looks every
/// two seconds for a YouTube tab and reads the video in it with a line of
/// JavaScript, which the browser allows only with "Allow JavaScript from Apple
/// Events" on (without it, only the video's title shows).
///
/// A player that isn't running is never asked (that would launch it). macOS asks
/// the user once per app: for Music and Spotify the first time they play, for a
/// browser the first time one of its windows shows YouTube — never at launch.
@MainActor @Observable
final class NowPlaying {
    enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
        case safari = "com.apple.Safari"
        case chrome = "com.google.Chrome"
        case arc = "company.thebrowser.Browser"
        case brave = "com.brave.Browser"
        case edge = "com.microsoft.edgemac"

        static let browsers: [Player] = [.safari, .chrome, .arc, .brave, .edge]

        var isBrowser: Bool { Self.browsers.contains(self) }

        var name: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            case .safari: "Safari"
            case .chrome: "Chrome"
            case .arc: "Arc"
            case .brave: "Brave"
            case .edge: "Edge"
            }
        }

        fileprivate var notification: String? {
            switch self {
            case .music: "com.apple.Music.playerInfo"
            case .spotify: "com.spotify.client.PlaybackStateChanged"
            default: nil
            }
        }

        /// Where the browser's switch for "Allow JavaScript from Apple Events" is.
        var javascriptSetting: String {
            self == .safari
                ? "Safari › Settings › Advanced › Show features for web developers, then Develop › Allow JavaScript from Apple Events"
                : "\(name) › View › Developer › Allow JavaScript from Apple Events"
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
    /// A YouTube tab whose browser won't run JavaScript for Cue: its title shows, but
    /// nothing can be read or controlled until the user allows it.
    private(set) var needsJavaScript = false
    /// Where the track was at `positionDate`; it runs on from there while playing.
    private var position: Double = 0
    private var positionDate = Date()
    /// The YouTube tab shown (window and tab index), for the controls.
    @ObservationIgnored private var tab: (window: Int, index: Int)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var permitted: Set<Player> = []
    /// Browsers already asked this session (a "no" is not asked again).
    @ObservationIgnored private var asked: Set<Player> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Off in Settings: the players are neither asked nor followed.
    @ObservationIgnored var isEnabled: () -> Bool = { true }

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for player in Player.allCases {
            guard let name = player.notification else { continue }
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
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
        for player in Player.allCases where player.isRunning && !player.isBrowser { changed(player, mayAsk: false) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollBrowsers()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        pollTask?.cancel()
        pollTask = nil
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

    func playPause() {
        command("playpause", javascript: "var v=document.querySelector('video');if(v){v.paused?v.play():v.pause()}")
    }

    func next() {
        command("next track", javascript: "var b=document.querySelector('.ytp-next-button, ytmusic-player-bar .next-button');if(b)b.click()")
    }

    func previous() {
        command("previous track", javascript: "var v=document.querySelector('video');if(v&&v.currentTime>3){v.currentTime=0}else{history.back()}")
    }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = .now
        let time = String(format: "%.2f", seconds)
        command("set player position to \(time)", javascript: "var v=document.querySelector('video');if(v)v.currentTime=\(time)")
    }

    func openPlayer() {
        guard let player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The position again from the player (the view asks every second while open,
    /// so a seek in the player itself shows).
    func refreshPosition() {
        guard let player, permitted.contains(player), player.isRunning else { return }
        if player.isBrowser {
            readBrowser(player)
            return
        }
        guard let text = run("tell application id \"\(player.rawValue)\" to get player position"),
              let seconds = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
        position = seconds
        positionDate = .now
    }

    private func command(_ verb: String, javascript: String) {
        guard let player, permitted.contains(player), player.isRunning else { return }
        if player.isBrowser {
            guard let tab, !needsJavaScript else { return }
            _ = run(Self.browserScript(player, javascript: javascript, in: tab))
        } else {
            _ = run("tell application id \"\(player.rawValue)\" to \(verb)")
        }
        // The player's own notification follows (or the next look); the state is wanted at once.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if player.isBrowser { readBrowser(player) } else { changed(player, mayAsk: false) }
        }
    }

    // MARK: - Music and Spotify

    private func changed(_ source: Player, mayAsk: Bool) {
        guard isEnabled(), source.isRunning else { return }
        if permitted.contains(source) {
            source.isBrowser ? readBrowser(source) : read(source)
            return
        }
        // Asking may put up the consent prompt, which waits on the user: off the main thread.
        let id = source.rawValue
        Task.detached {
            let granted = Self.permission(for: id, ask: mayAsk)
            await MainActor.run { [weak self] in
                guard let self, granted else { return }
                permitted.insert(source)
                source.isBrowser ? readBrowser(source) : read(source)
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
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        // Music gives seconds, Spotify milliseconds.
        let duration = number(lines[4]) / (source == .spotify ? 1000 : 1)
        let new = Track(id: lines[6], title: lines[1], artist: lines[2], album: lines[3], duration: duration)
        show(new, from: source, playing: lines[0] == "playing", at: number(lines[5]),
             artworkURL: source == .spotify && lines.count > 7 ? URL(string: lines[7]) : nil)
    }

    // MARK: - YouTube in a browser

    /// Reads the video in the first YouTube tab that plays (or the first one there is).
    private static let readVideo = """
    (function(){var v=document.querySelector('video');if(!v)return '';\
    var h=document.querySelector('ytd-watch-metadata h1, ytmusic-player-bar .title');\
    var a=document.querySelector('ytd-watch-metadata #owner #channel-name a, ytmusic-player-bar .byline a');\
    var t=(h&&h.textContent.trim())||document.title.replace(/ - YouTube( Music)?$/,'');\
    var id=new URL(location.href).searchParams.get('v')||'';\
    return JSON.stringify({t:t,a:a?a.textContent.trim():'',d:isFinite(v.duration)?v.duration:0,p:v.currentTime||0,s:!v.paused,id:id});})()
    """

    private func pollBrowsers() {
        guard isEnabled() else { return }
        let running = Player.browsers.filter(\.isRunning)
        // The shown tab's browser quit, or its tab is gone (read finds none).
        for browser in running where permitted.contains(browser) { readBrowser(browser) }
        // A browser not yet asked: only once one of its windows shows YouTube.
        let unasked = running.filter { !permitted.contains($0) && !asked.contains($0) }
        guard !unasked.isEmpty else { return }
        for browser in Self.browsersShowingYouTube() where unasked.contains(browser) {
            asked.insert(browser)
            changed(browser, mayAsk: true)
        }
    }

    /// Browsers with a window titled with YouTube (the window list's titles need the
    /// screen-recording permission Cue has for captures; without it, none are found).
    private static func browsersShowingYouTube() -> Set<Player> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var found: Set<Player> = []
        for window in windows {
            guard let title = window[kCGWindowName as String] as? String, title.contains("YouTube"),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  let player = Player(rawValue: id), player.isBrowser else { continue }
            found.insert(player)
        }
        return found
    }

    private func readBrowser(_ browser: Player) {
        let id = browser.rawValue
        let javascript = Self.appleScriptString(Self.readVideo)
        let run = browser == .safari ? "do JavaScript \(javascript) in tab i of window w" : "execute (tab i of window w) javascript \(javascript)"
        let title = browser == .safari ? "name" : "title"
        let script = """
        tell application id "\(id)"
            set sep to ASCII character 9
            set out to ""
            set allURLs to URL of every tab of every window
            repeat with w from 1 to count allURLs
                set us to item w of allURLs
                repeat with i from 1 to count us
                    set u to item i of us
                    if u is not missing value and (u contains "youtube.com/watch" or u contains "music.youtube.com") then
                        set r to "nojs"
                        try
                            set r to \(run)
                        end try
                        set out to out & w & sep & i & sep & (\(title) of tab i of window w) & sep & u & sep & r & linefeed
                    end if
                end repeat
            end repeat
            return out
        end tell
        """
        guard let text = self.run(script) else { return }
        struct Video: Decodable { let t: String; let a: String; let d: Double; let p: Double; let s: Bool; let id: String }
        struct Tab { let window: Int; let index: Int; let title: String; let url: String; let video: Video? }
        let tabs: [Tab] = text.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5, let window = Int(fields[0]), let index = Int(fields[1]) else { return nil }
            let video = fields[4] == "nojs" ? nil : fields[4].data(using: .utf8).flatMap { try? JSONDecoder().decode(Video.self, from: $0) }
            return Tab(window: window, index: index, title: fields[2], url: fields[3], video: video)
        }
        guard let chosen = tabs.first(where: { $0.video?.s == true }) ?? tabs.first else {
            if player == browser { clear() }
            return
        }
        let videoID = chosen.video?.id ?? URLComponents(string: chosen.url)?.queryItems?.first { $0.name == "v" }?.value ?? chosen.url
        let artworkURL = URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
        if let video = chosen.video {
            show(Track(id: videoID, title: video.t, artist: video.a, album: "YouTube", duration: video.d), from: browser,
                 playing: video.s, at: video.p, artworkURL: artworkURL, blocked: false)
        } else {
            // JavaScript off: what the tab's title says, and nothing more.
            let name = chosen.title.replacingOccurrences(of: " - YouTube Music", with: "").replacingOccurrences(of: " - YouTube", with: "")
            show(Track(id: videoID, title: name, artist: "", album: "YouTube", duration: 0), from: browser,
                 playing: false, at: 0, artworkURL: artworkURL, blocked: true)
        }
        if player == browser { tab = (chosen.window, chosen.index) }
    }

    /// A browser script that runs `javascript` in the tab at `tab`.
    private static func browserScript(_ browser: Player, javascript: String, in tab: (window: Int, index: Int)) -> String {
        let source = appleScriptString(javascript)
        let target = "tab \(tab.index) of window \(tab.window)"
        return browser == .safari
            ? "tell application id \"\(browser.rawValue)\" to do JavaScript \(source) in \(target)"
            : "tell application id \"\(browser.rawValue)\" to execute (\(target)) javascript \(source)"
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Showing it

    /// Takes the track from `source`, unless another player is playing and this one isn't.
    private func show(_ new: Track, from source: Player, playing: Bool, at seconds: Double, artworkURL: URL?, blocked: Bool = false) {
        if let player, player != source, isPlaying, !playing { return }
        if new.id != track?.id || source != player {
            artwork = nil
            loadArtwork(source, trackID: new.id, url: artworkURL)
        }
        player = source
        track = new
        isPlaying = playing
        needsJavaScript = blocked
        position = seconds
        positionDate = .now
    }

    private func loadArtwork(_ source: Player, trackID: String, url: URL?) {
        if source == .music {
            let descriptor = runDescriptor("tell application id \"\(source.rawValue)\" to get raw data of artwork 1 of current track")
            if let data = descriptor?.data, !data.isEmpty { artwork = NSImage(data: data) }
            return
        }
        guard let url else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), track?.id == trackID else { return }
            artwork = NSImage(data: data)
        }
    }

    private func clear() {
        player = nil
        track = nil
        isPlaying = false
        artwork = nil
        needsJavaScript = false
        tab = nil
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
                if !nowPlaying.needsJavaScript {
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
                    if nowPlaying.needsJavaScript, let player = nowPlaying.player {
                        Text("To follow and control the video, turn on \(player.javascriptSetting).")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    } else {
                        scrubber(track)
                            .padding(.top, 10)
                        controls
                            .padding(.top, 6)
                    }
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
