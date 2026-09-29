import AVFoundation
import CoreMedia

/// The end of an export's sound, kept level with its picture.
///
/// A recording's own sound stops a few tens of milliseconds before its last frame — the
/// capture's audio simply ends there — and a sound laid under part of the edit stops where
/// it stops. Written as it came, the file's sound track was shorter than its picture: most
/// players shrug, but an editor importing the file sees two tracks of different lengths,
/// and anything appended to the end starts with a gap in the sound. So once the sound runs
/// out, silence is written in its place, up to where the picture has got to and finally to
/// the end of the edit.
final class SoundTail {
    /// Where the sound written so far ends.
    private(set) var end = CMTime.zero
    /// The shape of what has been written, which silence has to match.
    private var format: CMAudioFormatDescription?

    /// Notes a buffer the encoder has taken.
    func note(_ sample: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mSampleRate > 0 else { return }
        format = description
        let frames = CMSampleBufferGetNumSamples(sample)
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        guard start.isNumeric else { return }
        let length = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(stream.mSampleRate))
        end = max(end, start + length)
    }

    /// Writes silence from where the sound ends towards `time`, as much as the encoder will
    /// take now. `true` once it has reached `time`.
    @discardableResult
    func pad(_ input: AVAssetWriterInput, upTo time: CMTime) -> Bool {
        guard let format, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              stream.mBytesPerFrame > 0, stream.mSampleRate > 0 else { return true }
        let rate = CMTimeScale(stream.mSampleRate)
        while end < time {
            guard input.isReadyForMoreMediaData else { return false }
            let missing = CMTimeConvertScale(time - end, timescale: rate, method: .roundAwayFromZero).value
            let frames = Int(min(4_096, max(1, missing)))
            guard let silence = Self.silence(frames: frames, format: format, bytesPerFrame: Int(stream.mBytesPerFrame),
                                             at: CMTimeConvertScale(end, timescale: rate, method: .default)),
                  input.append(silence) else { return true }
            note(silence)
        }
        return true
    }

    /// `frames` of nothing, in the format the sound was written in.
    static func silence(frames: Int, format: CMAudioFormatDescription, bytesPerFrame: Int,
                        at time: CMTime) -> CMSampleBuffer? {
        let length = frames * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: length, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: length) == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
                                                                   dataBuffer: block,
                                                                   formatDescription: format,
                                                                   sampleCount: frames,
                                                                   presentationTimeStamp: time,
                                                                   packetDescriptions: nil,
                                                                   sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
