import AVFoundation
import CoreMedia
import Foundation
import os
import RecordKit

/// Reads a recording's sound and reduces it to something a timeline can draw.
///
/// Sits beside `CursorTrack` and `ZoomSuggester` for the same reason they sit together:
/// all three read what was recorded and produce something the editor shows. None of them
/// draw anything, which is why this is here and not in the renderer.
public struct WaveformBuilder: Sendable {
    /// The finest resolution kept. Two hundred bins a second is far more than any
    /// timeline draws, and costs 1.6 kB per second of recording.
    public static let finestBinsPerSecond: Double = 200

    /// Peaks need no fidelity, only envelope — reading mono at 16 kHz is a tenth of the
    /// work of reading stereo at 48.
    private static let readRate: Double = 16_000

    public init() {}

    /// Whether this recording has any sound at all, from the manifest alone.
    ///
    /// The manifest names its audio tracks precisely so the editor need not open the
    /// asset to find out, and a silent recording is an ordinary recording — it gets a
    /// plain clip, no spinner and no error.
    public static func hasAudio(_ manifest: RecordingManifest) -> Bool {
        manifest.track(.systemAudio) != nil || manifest.track(.microphone) != nil
    }

    /// Reads every audio track, mixed, and bins it.
    ///
    /// - Parameter progress: called with 0…1 from a background context.
    public func peaks(of url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> WaveformPeaks? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return nil }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: Self.readRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let binCount = max(1, Int((duration * Self.finestBinsPerSecond).rounded(.up)))
        var minimums = [Float](repeating: 0, count: binCount)
        var maximums = [Float](repeating: 0, count: binCount)
        var framesRead = 0.0
        var lastReported = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }

            // The settings above ask for mono 32-bit float, but the reader is allowed to
            // hand back something else, so the rate is taken from the buffer rather than
            // assumed — the binning below works at whatever rate it is given.
            let description = CMSampleBufferGetFormatDescription(buffer)
            let streamRate = description
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
                ?? Self.readRate
            let channels = description
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
                .map(Int.init) ?? 1
            let sampleCount = length / MemoryLayout<Float>.size
            guard sampleCount > 0, streamRate > 0, channels > 0 else { continue }

            pointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                var index = 0
                while index < sampleCount {
                    // One frame is `channels` interleaved samples; the loudest channel
                    // is the one worth drawing.
                    var low: Float = 0
                    var high: Float = 0
                    for channel in 0..<channels where index + channel < sampleCount {
                        let value = samples[index + channel]
                        guard value.isFinite else { continue }
                        low = Swift.min(low, value)
                        high = Swift.max(high, value)
                    }
                    let seconds = (framesRead + Double(index / channels)) / streamRate
                    let bin = Int(seconds * Self.finestBinsPerSecond)
                    if bin >= 0, bin < binCount {
                        minimums[bin] = Swift.min(minimums[bin], low)
                        maximums[bin] = Swift.max(maximums[bin], high)
                    }
                    index += channels
                }
                framesRead += Double(sampleCount / channels)
            }

            if let progress {
                let done = min(1, framesRead / streamRate / duration)
                if done - lastReported > 0.02 {
                    lastReported = done
                    progress(done)
                }
            }
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
        }

        guard reader.status == .completed else { return nil }
        progress?(1)
        return WaveformPeaks(duration: duration,
                             finest: .init(binsPerSecond: Self.finestBinsPerSecond,
                                           minimums: minimums,
                                           maximums: maximums))
    }

    // MARK: - The cache on disk

    /// Reads a cached set of peaks, or `nil` when it is absent, stale or damaged.
    ///
    /// `key` names *which* sound inside the project this is, and it exists because the
    /// recording stopped being the only one: an imported piece of music or a voiceover take
    /// has a waveform worth drawing too, and one file called `peaks.bin` could only ever
    /// hold the recording's. The stamp still does the validating — a file whose size or
    /// date has moved is thrown away and read again — so the key only has to be unique,
    /// not meaningful.
    public static func cached(in package: RecordingPackage,
                             source url: URL,
                             key: String = recordingKey) -> WaveformPeaks? {
        guard let stamp = stamp(of: url),
              let data = try? Data(contentsOf: cacheURL(in: package, key: key)) else { return nil }
        return WaveformPeaks.Cache.decode(data, sourceSize: stamp.size, sourceModified: stamp.modified)
    }

    /// Writes the cache, creating `derived/` — which `RecordingPackage.create` does not.
    public static func cache(_ peaks: WaveformPeaks,
                             in package: RecordingPackage,
                             source url: URL,
                             key: String = recordingKey) {
        guard let stamp = stamp(of: url) else { return }
        do {
            try FileManager.default.createDirectory(at: package.derivedFolder, withIntermediateDirectories: true)
            let data = WaveformPeaks.Cache.encode(peaks, sourceSize: stamp.size, sourceModified: stamp.modified)
            try data.write(to: cacheURL(in: package, key: key), options: .atomic)
        } catch {
            // Regenerable by definition: failing to write it is worth a line in the log
            // and nothing else.
            log.error("Couldn't cache waveform: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The recording's own key, which is the name the cache has always had — so a project
    /// carrying a `peaks.bin` from before any of this still reads.
    public static let recordingKey = "peaks"

    public static func cacheURL(in package: RecordingPackage, key: String = recordingKey) -> URL {
        package.derivedFolder.appendingPathComponent("\(key).bin")
    }

    /// A filename-safe key for a file inside the project, from the path the timeline
    /// stores.
    ///
    /// Hashed rather than escaped: a relative path contains separators and may be any
    /// length, and a cache filename derived by substitution would collide the first time
    /// two folders differed only in a character that had to be replaced. The path is the
    /// document's own idea of identity — two regions naming the same file share one
    /// waveform, which is what should happen when the same music is laid down twice.
    public static func key(forPath path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "peaks-" + String(hash, radix: 36)
    }

    private static func stamp(of url: URL) -> (size: UInt64, modified: Double)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return (UInt64(size), modified.timeIntervalSinceReferenceDate)
    }

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "waveform")
}
