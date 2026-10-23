import AVFoundation
import Foundation
import RecordKit
import RenderKit
import TimelineKit

/// `studiolab export <recording.cuerec> <out.mp4>` — the file the app would write, and
/// whether what is in it is where it should be.
///
/// The same `EditorDocument`, `SceneBuilder` and `VideoExporter` the editor uses, with the
/// export sheet's defaults, so a fault found here is a fault in the app's export and not
/// in a copy of it. It then reads the file back: the lengths of the picture and the sound,
/// and — with click sounds on — whether each click is heard at the moment it is seen.
@MainActor
enum ExportCheck {
    static func run(_ arguments: [String], everything: Bool = false) async -> Int32 {
        guard arguments.count >= 2 else {
            print("usage: studiolab export <recording.cuerec> <out.mp4>")
            return 2
        }
        let package = RecordingPackage(url: URL(fileURLWithPath: arguments[0]))
        let out = URL(fileURLWithPath: arguments[1])
        let document: EditorDocument
        do {
            document = try EditorDocument(package: package)
        } catch {
            print("could not open the recording: \(error)")
            return 1
        }
        guard let videoURL = document.videoURL else {
            print("the recording has no video")
            return 1
        }
        var timeline = document.timeline
        if everything { KitchenSink.apply(to: &timeline) }
        let size = document.manifest.track(.screen)?.pixelSize ?? CGSize(width: 1_920, height: 1_080)
        let builder = SceneBuilder(videoSize: size, displayScale: document.manifest.displayScale,
                                   packageURL: package.url, cursorArtwork: document.cursorArtwork)
        let exporter = VideoExporter(timeline: timeline, builder: builder, cursor: document.cursorTrack,
                                     videoURL: videoURL, webcamURL: document.webcamURL,
                                     packageURL: package.url, settings: ExportSettings())
        try? FileManager.default.removeItem(at: out)
        let started = Date()
        do {
            try await exporter.export(to: out)
        } catch {
            print("export failed: \(error)")
            return 1
        }
        print(String(format: "exported %.2f s of edit in %.1f s", timeline.duration.seconds, Date().timeIntervalSince(started)))

        var failures = 0
        let asset = AVURLAsset(url: out)
        let expected = timeline.duration.seconds
        for (name, type) in [("picture", AVMediaType.video), ("sound", .audio)] {
            guard let track = try? await asset.loadTracks(withMediaType: type).first,
                  let range = try? await track.load(.timeRange) else {
                print("  \(name): none")
                continue
            }
            let off = range.end.seconds - expected
            // A frame either way is the most an encoder is allowed.
            let fine = abs(off) <= 1.0 / 30
            if !fine { failures += 1 }
            print(String(format: "  %@: %.3f s to %.3f s (%+.1f ms against the edit) %@",
                         name, range.start.seconds, range.end.seconds, off * 1_000, fine ? "ok" : "WRONG"))
        }

        let moments = timeline.clickSoundMoments(for: document.cursorTrack.clicks)
        if !moments.isEmpty {
            let onsets = (try? await self.onsets(in: asset)) ?? []
            print("  click sounds: \(moments.count) expected, \(onsets.count) heard")
            for moment in moments {
                let at = moment.time.seconds
                let nearest = onsets.min { abs($0 - at) < abs($1 - at) }
                let off = nearest.map { ($0 - at) * 1_000 }
                // Two milliseconds is a tenth of a frame, and less than anybody can hear.
                let fine = off.map { abs($0) <= 2 } ?? false
                if !fine { failures += 1 }
                print(String(format: "    %.3f s: %@ %@", at,
                             off.map { String(format: "heard %+.1f ms from it", $0) } ?? "not heard",
                             fine ? "ok" : "WRONG"))
            }
        }
        print(failures == 0 ? "PASS" : "FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }

    /// Where sounds begin in the file's audio: the moments the level jumps from quiet.
    ///
    /// Read in millisecond windows. A click rises from nothing to its peak inside one, so
    /// the first window that is loud after ten quiet ones is where it starts.
    private static func onsets(in asset: AVURLAsset) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 48_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        var first: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if first == nil { first = buffer.presentationTimeStamp.seconds }
            guard let block = buffer.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            samples += chunk
        }
        let window = Int(rate / 1_000)
        let levels = stride(from: 0, to: samples.count - window, by: window).map { start in
            samples[start..<start + window].map { abs($0) }.max() ?? 0
        }
        var onsets: [Double] = []
        var quiet = 0
        for (index, level) in levels.enumerated() {
            if level < 0.02 {
                quiet += 1
                continue
            }
            if quiet >= 10 {
                // Inside the window: the first sample over the line.
                let start = index * window
                let offset = samples[start..<start + window].firstIndex { abs($0) >= 0.02 } ?? start
                onsets.append((first ?? 0) + Double(offset) / rate)
            }
            quiet = 0
        }
        return onsets
    }
}
