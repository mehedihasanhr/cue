import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import RecordKit

/// A take written the way `RecordingSession` writes one — the same writers on one queue,
/// one clock, the marker, a pointer sidecar — from pictures and sound made up on the spot.
///
/// Nothing is captured: no screen, no microphone, no camera, so nothing asks for
/// permission and nothing lights up. The pictures are a bar moving across a grey field,
/// one step per frame, so a frame's content says which frame it is.
final class SyntheticTake: @unchecked Sendable {
    let package: RecordingPackage
    let frameRate: Int
    let pixelSize: CGSize
    let codec: AVVideoCodecType
    let clock = RecordingClock()
    let queue = DispatchQueue(label: "com.stackrover.klik.studio.synthetic-take")

    let screen: SessionWriter
    let systemAudio: AudioTrackWriter
    let microphone: AudioTrackWriter
    let cursor: JSONLWriter

    /// The host clock when the take began. Taken from the real one, because the screen's
    /// writer pads the end of a take up to the real clock's "now" when it finishes.
    let hostStart: CMTime
    private(set) var framesWritten = 0
    private var audioSamplesWritten = 0
    /// Host time spent on hold so far. The host clock runs on through a pause; the take's
    /// own clock does not.
    private var heldFor = CMTime.zero

    static let sampleRate = 48_000
    static let audioChunk = 1_024
    static let pointerRate = 120

    private let pool: CVPixelBufferPool
    private let audioFormat: CMAudioFormatDescription

    init(named name: String,
         in folder: URL,
         frameRate: Int = 30,
         pixelSize: CGSize = CGSize(width: 640, height: 360),
         codec: AVVideoCodecType = .h264) throws {
        self.frameRate = frameRate
        self.pixelSize = pixelSize
        self.codec = codec
        package = try RecordingPackage.create(named: name, in: folder)
        hostStart = RecordingClock.now

        screen = try SessionWriter(url: package.mediaFolder.appendingPathComponent("screen.mov"),
                                   pixelSize: pixelSize,
                                   codec: codec,
                                   bitrate: 3_000_000,
                                   frameRate: frameRate,
                                   systemAudio: false,
                                   microphone: false,
                                   clock: clock,
                                   queue: queue)
        systemAudio = try AudioTrackWriter(url: package.mediaFolder.appendingPathComponent("system-audio.m4a"),
                                           clock: clock, queue: queue)
        microphone = try AudioTrackWriter(url: package.mediaFolder.appendingPathComponent("microphone-1.m4a"),
                                          clock: clock, queue: queue)
        let cursor = JSONLWriter(url: package.telemetryFolder.appendingPathComponent("cursor.jsonl"), queue: queue)
        try queue.sync { try cursor.open() }
        self.cursor = cursor

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(pixelSize.width),
            kCVPixelBufferHeightKey: Int(pixelSize.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &pool)
        guard let pool else { throw ProbeError.setup("no pixel buffer pool") }
        self.pool = pool

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        guard let format else { throw ProbeError.setup("no audio format") }
        audioFormat = format

        // Before the first frame, as the recorder does it.
        try package.writeMarker(TakeMarker(manifest: manifest(duration: 0)))
    }

    /// The manifest the recorder would write for this take.
    func manifest(duration: Double) -> RecordingManifest {
        RecordingManifest(name: package.url.deletingPathExtension().lastPathComponent,
                          duration: duration,
                          tracks: [
                              .init(kind: .screen, path: "media/screen.mov", pixelSize: pixelSize,
                                    frameRate: frameRate, codec: codec.rawValue),
                              .init(kind: .systemAudio, path: "media/system-audio.m4a", name: "System Audio"),
                              .init(kind: .microphone, path: "media/microphone-1.m4a",
                                    name: "Test Microphone", deviceID: "test-microphone"),
                          ],
                          telemetry: .init(cursor: "telemetry/cursor.jsonl", pointerLatency: 0))
    }

    func hostTime(ofFrame index: Int) -> CMTime {
        hostStart + heldFor + CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
    }

    private func hostTime(ofSample index: Int) -> CMTime {
        hostStart + heldFor + CMTime(value: CMTimeValue(index), timescale: CMTimeScale(Self.sampleRate))
    }

    /// Holds the take for this long, the way `RecordingSession.pause()` and `resume()` do:
    /// the clock first, then every writer. Nothing arrives in between, and the host clock
    /// moves on by the length of the hold.
    func pause(seconds: Double) {
        let from = hostTime(ofFrame: framesWritten)
        clock.hold(at: from)
        queue.sync {
            screen.setPaused(true)
            systemAudio.setPaused(true)
            microphone.setPaused(true)
        }
        heldFor = heldFor + CMTime(seconds: seconds, preferredTimescale: 600)
        clock.release(at: hostTime(ofFrame: framesWritten))
        queue.sync {
            screen.setPaused(false)
            systemAudio.setPaused(false)
            microphone.setPaused(false)
        }
    }

    /// Writes this many more seconds of the take. At the pace it would really arrive,
    /// unless asked not to: the writers are real-time writers, and what a crash leaves on
    /// disk depends on the encoder having had the time it would have had.
    func record(seconds: Double, realTime: Bool = true) {
        let frames = Int((seconds * Double(frameRate)).rounded())
        let wallStart = Date()
        for step in 0..<frames {
            if realTime {
                let due = wallStart.addingTimeInterval(Double(step) / Double(frameRate))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            let index = framesWritten
            let time = hostTime(ofFrame: index)
            guard let video = videoBuffer(frame: index, at: time) else { continue }
            let frameEnd = hostTime(ofFrame: index + 1)
            queue.sync {
                screen.append(video: video)
                // Sound up to the end of this frame, into both sound files.
                while hostTime(ofSample: audioSamplesWritten) < frameEnd {
                    let at = hostTime(ofSample: audioSamplesWritten)
                    guard let sound = audioBuffer(at: at) else { break }
                    systemAudio.append(sound)
                    microphone.append(sound)
                    audioSamplesWritten += Self.audioChunk
                }
                // The pointer at 120 Hz, stamped by the clock like the real one.
                let perFrame = Self.pointerRate / frameRate
                for sub in 0..<perFrame {
                    let sampleTime = time + CMTime(value: CMTimeValue(sub), timescale: CMTimeScale(Self.pointerRate))
                    cursor.append(CursorSample(t: clock.elapsed(at: sampleTime),
                                               x: Double(index), y: Double(sub), shape: .arrow))
                }
            }
            framesWritten += 1
        }
    }

    /// Stops the way `RecordingSession.stop()` does: sidecars, then each sound, then the
    /// picture, then the manifest, then the marker goes.
    func finish() async throws -> RecordingManifest {
        queue.sync { _ = cursor.close() }
        try await systemAudio.finish()
        try await microphone.finish()
        let duration = try await screen.finish()
        let manifest = manifest(duration: duration.seconds)
        try package.write(manifest)
        package.removeMarker()
        return manifest
    }

    private func videoBuffer(frame: Int, at time: CMTime) -> CMSampleBuffer? {
        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
        guard let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let width = Int(pixelSize.width), height = Int(pixelSize.height)
            memset(bytes, 60, row * height)
            let bar = 40
            let x = (frame * 8) % max(1, width - bar)
            for y in (height / 4)..<(height * 3 / 4) {
                memset(bytes + y * row + x * 4, 230, bar * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    private func audioBuffer(at time: CMTime) -> CMSampleBuffer? {
        var asbd = audioFormat.audioStreamBasicDescription!
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.audioChunk))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(Self.audioChunk)
        if let channels = pcm.floatChannelData {
            for channel in 0..<2 {
                for index in 0..<Self.audioChunk {
                    let n = Float(audioSamplesWritten + index)
                    channels[channel][index] = sin(n * 2 * .pi * 440 / Float(Self.sampleRate)) * 0.2
                }
            }
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: audioFormat, sampleCount: Self.audioChunk, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                                                              blockBufferMemoryAllocator: nil, flags: 0,
                                                              bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return sample
    }
}

enum ProbeError: Error {
    case setup(String)
}
