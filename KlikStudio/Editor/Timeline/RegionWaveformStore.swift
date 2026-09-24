import Foundation
import Observation
import os
import RecordKit
import TimelineKit

/// The sounds brought in from outside the recording, read once each and kept.
///
/// A sibling of `WaveformStore` rather than a generalisation of it, and the difference is
/// worth stating: the recording is *one* file, known before the editor opens, and its store
/// can be a single state machine. Imported sound is a set that changes while you work —
/// music dropped in, a voiceover recorded, a region deleted — so this is keyed by the path
/// the timeline stores and asked for what it has rather than told what to load.
///
/// An imported sound used to draw as a chip with a filename on it, which is the one thing
/// about a piece of music you can read off the Finder anyway. What you actually want from
/// that lane is where the words are and where the quiet bit is, so you can line the picture
/// up with them — and that is a waveform.
@MainActor
@Observable
final class RegionWaveformStore {
    /// What is known about one file. `unavailable` and a file still being read draw the
    /// same — nothing — but they are different states, and conflating them would mean
    /// retrying a file with no sound in it forever.
    private enum State {
        case loading
        case ready(WaveformPeaks)
        case unavailable
    }

    private var states: [String: State] = [:]
    private var work: [String: Task<Void, Never>] = [:]

    private let package: RecordingPackage
    private let packageURL: URL

    init(package: RecordingPackage) {
        self.package = package
        packageURL = package.url
    }

    /// The peaks for a region's file, or `nil` while there are none to draw.
    ///
    /// Reading it is what makes the row observe this store, so a read that finishes
    /// redraws the lane it belongs to and nothing else.
    func peaks(forPath path: String) -> WaveformPeaks? {
        if case .ready(let peaks) = states[path] { return peaks }
        return nil
    }

    /// Makes sure every sound the edit names has been read, and forgets the ones it no
    /// longer does.
    ///
    /// Called on every refresh, so it has to be cheap on the ordinary path — which it is:
    /// a path already known costs a dictionary lookup. Dropping what is no longer named is
    /// not about memory so much as about a file replaced under the same name: an undo that
    /// brings a region back re-reads it, and the disk cache makes that instant when the
    /// file really is the same one.
    func reconcile(paths: some Collection<String>) {
        let wanted = Set(paths)
        for path in states.keys where !wanted.contains(path) {
            work.removeValue(forKey: path)?.cancel()
            states.removeValue(forKey: path)
        }
        for path in wanted where states[path] == nil {
            load(path)
        }
    }

    private func load(_ path: String) {
        let url = packageURL.appendingPathComponent(path)
        let key = WaveformBuilder.key(forPath: path)
        if let cached = WaveformBuilder.cached(in: package, source: url, key: key) {
            states[path] = .ready(cached)
            return
        }

        states[path] = .loading
        let package = package
        work[path] = Task { [weak self] in
            // No progress reporting, unlike the recording's: an imported sound is seconds
            // of reading rather than minutes, and a spinner per region on the lane would be
            // more noise than the thing it was reporting on.
            let peaks = await Self.read(WaveformBuilder(), url)
            guard !Task.isCancelled, let self else { return }
            work.removeValue(forKey: path)
            if let peaks, !peaks.isEmpty {
                WaveformBuilder.cache(peaks, in: package, source: url, key: key)
                states[path] = .ready(peaks)
            } else {
                states[path] = .unavailable
            }
        }
    }

    private nonisolated static func read(_ builder: WaveformBuilder, _ url: URL) async -> WaveformPeaks? {
        do {
            return try await builder.peaks(of: url)
        } catch {
            // A file that cannot be read draws as a plain chip, which is what the lane did
            // for every sound until now — a worse drawing, not a broken editor.
            log.error("Couldn't read \(url.lastPathComponent, privacy: .public)'s waveform: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func cancel() {
        for task in work.values { task.cancel() }
        work.removeAll()
    }

    private nonisolated static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "waveform")
}
