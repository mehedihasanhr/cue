import Foundation
import Observation
import os
import RecordKit
import TimelineKit

/// The recording's sound, read once and kept.
///
/// Built off the main actor and cached inside the package, because a ten-minute take is
/// a few seconds of decoding and nobody should wait on it to start editing. The timeline
/// draws whatever is ready and nothing when there is nothing — a recording with no sound
/// is an ordinary recording, and it gets a plain clip rather than an error.
@MainActor
@Observable
final class WaveformStore {
    enum State: Equatable {
        case idle
        case loading(Double)
        case ready(WaveformPeaks)
        /// No audio track, or the sound could not be read. Both draw the same: nothing.
        case unavailable
    }

    private(set) var state: State = .idle

    private let package: RecordingPackage
    private let manifest: RecordingManifest
    private var work: Task<Void, Never>?

    init(package: RecordingPackage, manifest: RecordingManifest) {
        self.package = package
        self.manifest = manifest
    }

    var peaks: WaveformPeaks? {
        if case .ready(let peaks) = state { return peaks }
        return nil
    }

    var progress: Double? {
        if case .loading(let done) = state { return done }
        return nil
    }

    func load(videoURL: URL) {
        guard case .idle = state else { return }
        // The manifest names its audio tracks precisely so the editor need not open the
        // asset to find out whether there are any.
        guard WaveformBuilder.hasAudio(manifest) else {
            state = .unavailable
            return
        }
        // A recording whose sources were captured separately has no sound in its video file
        // at all: each lane reads its own, through `RegionWaveformStore`. Decoding the whole
        // picture to discover that would be a minute of work to find nothing.
        guard manifest.audioTracks.contains(where: { $0.path == manifest.track(.screen)?.path }) else {
            state = .unavailable
            return
        }
        if let cached = WaveformBuilder.cached(in: package, source: videoURL) {
            state = .ready(cached)
            return
        }

        state = .loading(0)
        let package = package
        work = Task { [weak self] in
            guard let self else { return }
            let peaks = await Self.read(WaveformBuilder(), videoURL) { done in
                Task { @MainActor in
                    guard case .loading = self.state else { return }
                    self.state = .loading(done)
                }
            }

            guard !Task.isCancelled else { return }
            if let peaks, !peaks.isEmpty {
                WaveformBuilder.cache(peaks, in: package, source: videoURL)
                state = .ready(peaks)
            } else {
                state = .unavailable
            }
        }
    }

    /// Reading it is a background job with one interesting failure — there is no sound —
    /// and that is not an error worth showing anybody.
    private nonisolated static func read(_ builder: WaveformBuilder,
                                         _ url: URL,
                                         progress: @escaping @Sendable (Double) -> Void) async -> WaveformPeaks? {
        do {
            return try await builder.peaks(of: url, progress: progress)
        } catch {
            log.error("Couldn't read the waveform: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Forgets what was read and reads it again — for the rare recording whose manifest
    /// predates the audio track entries.
    func rebuild(videoURL: URL) {
        work?.cancel()
        try? FileManager.default.removeItem(at: WaveformBuilder.cacheURL(in: package))
        state = .idle
        load(videoURL: videoURL)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    private nonisolated static let log = Logger(subsystem: "com.stackrover.klik", category: "waveform")
}
