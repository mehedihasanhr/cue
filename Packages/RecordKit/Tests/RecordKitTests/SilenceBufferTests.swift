import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import RecordKit

/// Making silence that matches a real audio buffer.
///
/// This is called from a capture callback with whatever ScreenCaptureKit or a microphone
/// hands over, and it used to be reached only on the rare mid-recording gap. It is now on
/// the ordinary path, which means a format it cannot cope with is a crash in the middle of
/// somebody's recording rather than a curiosity. `AVAudioPCMBuffer` raises an Objective-C
/// exception rather than returning nil, and an exception on a dispatch queue is an abort:
/// there is nothing to catch it.
struct SilenceBufferTests {
    /// A buffer shaped the way the system actually delivers audio.
    ///
    /// ScreenCaptureKit hands over non-interleaved 32-bit float at 48 kHz; a microphone
    /// through `AVCaptureAudioDataOutput` is usually interleaved. Both go through the same
    /// function.
    private func buffer(sampleRate: Double = 48_000,
                        channels: UInt32 = 2,
                        interleaved: Bool = false,
                        frames: Int = 1_024) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: interleaved ? 4 * channels : 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: interleaved ? 4 * channels : 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)

        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd,
                                                    layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &format)
        try #require(status == noErr)
        let description = try #require(format)

        let avFormat = try #require(AVAudioFormat(streamDescription: &asbd))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: avFormat,
                                                frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)

        var sample: CMSampleBuffer?
        try #require(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: CMItemCount(frames),
            presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr)
        let made = try #require(sample)
        try #require(CMSampleBufferSetDataBufferFromAudioBufferList(
            made, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList) == noErr)
        return made
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    @Test func silenceCanBeMadeForTheScreensOwnAudio() throws {
        let source = try buffer()
        let silence = try #require(SilenceBuffer.make(like: source, duration: time(0.1), at: .zero))
        #expect(silence.numSamples == 4_800)
    }

    @Test func silenceCanBeMadeForAMicrophone() throws {
        let source = try buffer(sampleRate: 44_100, channels: 1, interleaved: true)
        let silence = try #require(SilenceBuffer.make(like: source, duration: time(0.1), at: .zero))
        #expect(silence.numSamples == 4_410)
    }

    /// The shapes that must return `nil` rather than raise. Each of these was reachable
    /// from a capture callback, where a raise is an abort.
    @Test func anImpossibleLengthIsRefusedRatherThanRaised() throws {
        let source = try buffer()
        #expect(SilenceBuffer.make(like: source, duration: .zero, at: .zero) == nil)
        #expect(SilenceBuffer.make(like: source, duration: time(-1), at: .zero) == nil)
        #expect(SilenceBuffer.make(like: source, duration: .invalid, at: .zero) == nil)
        #expect(SilenceBuffer.make(like: source, duration: .indefinite, at: .zero) == nil)
        #expect(SilenceBuffer.make(like: source, duration: .positiveInfinity, at: .zero) == nil)
    }

    /// The one that crashed a recording: a length long enough that the buffer cannot be
    /// allocated. Whatever produced it, silence is not worth aborting over.
    @Test func anAbsurdLengthIsRefusedRatherThanRaised() throws {
        let source = try buffer()
        #expect(SilenceBuffer.make(like: source, duration: time(60 * 60 * 24), at: .zero) == nil)
        #expect(SilenceBuffer.make(like: source, duration: CMTime(value: .max, timescale: 1), at: .zero) == nil)
    }
}
