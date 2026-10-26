import SwiftUI

/// The words of what plays, from LRCLIB (a free, open lyrics database: no key, over
/// the network permission Cue has), timed line by line when it has them.
@MainActor @Observable
final class LyricsStore {
    struct Line: Identifiable, Equatable {
        let id: Int
        /// Seconds into the track; nil for lyrics without timings.
        let time: Double?
        let text: String
    }

    enum State: Equatable {
        case idle, loading, found, none
    }

    private(set) var state: State = .idle
    private(set) var lines: [Line] = []
    /// Whether the lines carry times, so they can follow the song.
    private(set) var synced = false

    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var cache: [String: (lines: [Line], synced: Bool)] = [:]

    /// Fetches the lyrics for `track` once (and remembers them).
    func load(_ track: NowPlaying.Track) {
        guard loadedFor != track.id else { return }
        loadedFor = track.id
        if let cached = cache[track.id] {
            lines = cached.lines
            synced = cached.synced
            state = cached.lines.isEmpty ? .none : .found
            return
        }
        state = .loading
        lines = []
        let (artist, title) = Self.clean(track)
        Task {
            let found = await Self.fetch(artist: artist, title: title, album: track.album, duration: track.duration)
            guard loadedFor == track.id else { return }
            cache[track.id] = found
            lines = found.lines
            synced = found.synced
            state = found.lines.isEmpty ? .none : .found
        }
    }

    /// The line sung at `seconds` (the last one started).
    func current(at seconds: Double) -> Int? {
        guard synced else { return nil }
        return lines.lastIndex { ($0.time ?? 0) <= seconds + 0.25 }
    }

    // MARK: - LRCLIB

    private struct Record: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
    }

    private static func fetch(artist: String, title: String, album: String, duration: Double) async -> (lines: [Line], synced: Bool) {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
            + (album.isEmpty || album == "YouTube" ? [] : [URLQueryItem(name: "album_name", value: album)])
            + (duration > 0 ? [URLQueryItem(name: "duration", value: String(Int(duration.rounded())))] : [])
        if let record: Record = await get(exact.url), let parsed = parse(record) { return parsed }
        // Not found as given: a search, taking the first with synced lines, else any.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)".trimmingCharacters(in: .whitespaces))]
        if let records: [Record] = await get(search.url) {
            if let synced = records.first(where: { $0.syncedLyrics?.isEmpty == false }), let parsed = parse(synced) { return parsed }
            if let any = records.first, let parsed = parse(any) { return parsed }
        }
        return ([], false)
    }

    private static func get<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Cue (https://github.com/mehedihasanhr/cue-releases)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func parse(_ record: Record) -> (lines: [Line], synced: Bool)? {
        if record.instrumental == true { return ([Line(id: 0, time: nil, text: "♪ Instrumental")], false) }
        if let lrc = record.syncedLyrics, !lrc.isEmpty {
            // "[01:23.45] words" (a line may carry several times).
            var timed: [(Double, String)] = []
            for raw in lrc.split(separator: "\n") {
                var rest = Substring(raw)
                var times: [Double] = []
                while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                    let stamp = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                    if stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) { times.append(minutes * 60 + seconds) }
                    rest = rest[rest.index(after: close)...]
                }
                let text = rest.trimmingCharacters(in: .whitespaces)
                for time in times { timed.append((time, text.isEmpty ? "♪" : text)) }
            }
            let lines = timed.sorted { $0.0 < $1.0 }.enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
            if !lines.isEmpty { return (lines, true) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: true).enumerated()
                .map { Line(id: $0.offset, time: nil, text: String($0.element)) }
            return (lines, false)
        }
        return nil
    }

    /// The artist and song as a lyrics site knows them. A YouTube title is usually
    /// "Artist - Song (Official Video)", with the channel as the artist.
    private static func clean(_ track: NowPlaying.Track) -> (artist: String, title: String) {
        var title = track.title
        var artist = track.artist
        // Bracketed extras: (Official Video), [Lyrics], (feat. …).
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"(?i)\s*(official (music )?video|lyrics?|audio|hd|4k)\s*$"#, with: "", options: .regularExpression)
        if track.album == "YouTube", let dash = title.range(of: " - ") ?? title.range(of: " – ") {
            artist = String(title[..<dash.lowerBound])
            title = String(title[dash.upperBound...])
        }
        artist = artist.replacingOccurrences(of: #"(?i)\s*(- topic|vevo|official)$"#, with: "", options: .regularExpression)
        return (artist.trimmingCharacters(in: .whitespaces), title.trimmingCharacters(in: .whitespaces))
    }
}

/// The lyrics in the player: the line sung now large and bright, those before and
/// after dimmer, gliding up as the song goes on. Unsynced lyrics just scroll.
struct LyricsView: View {
    let lyrics: LyricsStore
    let nowPlaying: NowPlaying

    var body: some View {
        switch lyrics.state {
        case .idle, .loading:
            message("Finding the lyrics…")
        case .none:
            message("No lyrics for this one")
        case .found:
            if lyrics.synced {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let index = lyrics.current(at: nowPlaying.position(at: context.date)) ?? -1
                    synced(around: index)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lyrics.lines) { line in
                            Text(line.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func synced(around index: Int) -> some View {
        let lines = lyrics.lines
        // The line before, the one now, and two to come.
        let window = (index - 1)...(index + 2)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(window.filter { lines.indices.contains($0) || $0 == index }, id: \.self) { position in
                let now = position == index
                Text(lines.indices.contains(position) ? lines[position].text : "♪")
                    .font(.system(size: now ? 15 : 12, weight: now ? .bold : .medium))
                    .foregroundStyle(.white.opacity(now ? 1 : position < index ? 0.3 : 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .shadow(color: now ? IslandStyle.accent.opacity(0.5) : .clear, radius: 8)
                    .id(lines.indices.contains(position) ? lines[position].id : -1)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(IslandView.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.85), value: index)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
