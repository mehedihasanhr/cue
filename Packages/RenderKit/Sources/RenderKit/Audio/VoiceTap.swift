import AVFoundation
import CoreMedia
import Foundation
import MediaToolbox

/// A `VoiceChain` hung on one track of the audio mix.
///
/// An `MTAudioProcessingTap` on the mix's input parameters, because that is the one place
/// both consumers of the mix run it: `AVPlayer` for the preview and
/// `AVAssetReaderAudioMixOutput` for the export each call the tap with the track's decoded
/// samples before applying the mix's volume. So there is one piece of code between the
/// file and the speakers in both cases, and the level slider still works on top of it.
///
/// Before the volume ("pre-effects"), so the source's own level and the ducking ramps
/// scale what the chain produced rather than feeding it — a voice turned down to 50% is
/// the cleaned voice at half level, not a quieter voice the expander now mistakes for hiss.
enum VoiceTap {
    /// What the tap's C callbacks find through their storage pointer.
    ///
    /// Only the audio thread touches `chain` once the tap is running; `prepare` is called
    /// before any `process` and `unprepare` after the last, by the same consumer.
    final class Context {
        let recipe: VoiceRecipe
        var chain: VoiceChain?
        var interleaved = false
        var channels = 0

        init(recipe: VoiceRecipe) { self.recipe = recipe }

        func prepare(_ format: AudioStreamBasicDescription) {
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            // Anything but 32-bit float passes through untouched. Every consumer on the
            // Mac hands a tap float, but if one ever did not, the honest failure is the
            // untreated voice rather than noise.
            guard format.mFormatID == kAudioFormatLinearPCM, isFloat, format.mBitsPerChannel == 32 else {
                chain = nil
                return
            }
            interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            channels = Int(format.mChannelsPerFrame)
            // A fresh chain every time the consumer starts, so two reads of the same mix —
            // or a preview and an export — begin from the same state.
            chain = VoiceChain(recipe: recipe, sampleRate: format.mSampleRate, channels: channels)
        }

        func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            guard chain != nil, frames > 0 else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            if interleaved {
                guard let data = buffers.first?.mData else { return }
                let base = data.assumingMemoryBound(to: Float.self)
                chain?.process((0..<channels).map { base + $0 }, stride: channels, frames: frames)
            } else {
                let pointers = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
                chain?.process(pointers, stride: 1, frames: frames)
            }
        }
    }

    /// A tap that runs `recipe`, or `nil` if the system would not make one — in which case
    /// the track plays untreated rather than not at all.
    static func make(_ recipe: VoiceRecipe) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(Context(recipe: recipe))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: { _, clientInfo, storage in
                storage.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, list, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, nil, framesOut) == noErr else {
                    return
                }
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().process(list, frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            context.release()
            return nil
        }
        return tap
    }
}
