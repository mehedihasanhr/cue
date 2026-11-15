import CoreAudio
import Foundation

/// Whether a process is playing sound, asked of CoreAudio.
///
/// Cue needs this for a browser that will not run its JavaScript: the tab says what
/// is loaded, never whether it is playing, and an open YouTube tab had been taken for
/// a playing one. The system knows, because the audio engine knows who is feeding it.
enum AudioActivity {
    /// True while `pid` is playing something out, false while it is silent, nil when
    /// the system will not say — before macOS 14.2, or for a process with no audio of
    /// its own.
    static func isPlayingOutput(pid: pid_t) -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var wanted = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &wanted, &size, &object) == noErr,
              object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        address.mSelector = kAudioProcessPropertyIsRunningOutput
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }
}
