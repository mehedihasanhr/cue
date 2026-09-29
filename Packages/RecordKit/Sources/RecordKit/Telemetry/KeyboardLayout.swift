import Carbon.HIToolbox
import Foundation

/// What the current keyboard layout prints on a key.
///
/// A table lookup in the layout the system already has loaded — the same one that turns
/// a key code into a character for every app — so it needs no permission and reads
/// nothing the person typed. It is asked only for a key that may be named (see
/// `KeyRecorder`), and only for the key's *unmodified* legend: what is printed on the
/// cap, not what ⌥ or ⇧ would have made of it.
///
/// Main actor because the Text Input Sources functions insist on it, and because the
/// event monitor that asks is already there.
public enum KeyboardLayout {
    /// The unmodified character for a key code on the layout in use, or `nil` when the
    /// layout has none for it — a named key, a key the layout does not map, or an input
    /// method with no layout data at all.
    @MainActor
    public static func character(forKeyCode keyCode: UInt16) -> String? {
        // The layout in use, and failing that the nearest ASCII-capable one: an input
        // method for Japanese or Chinese carries no key layout of its own, but it sits
        // on top of one that does.
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for source in sources {
            guard let source = source?.takeRetainedValue(),
                  let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                continue
            }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
            if let printed = translate(keyCode, in: data) { return printed }
        }
        return nil
    }

    /// One key through one layout, with no modifiers held and dead keys resolved: the
    /// legend on the cap rather than the accent it would start.
    private static func translate(_ keyCode: UInt16, in layout: Data) -> String? {
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(base, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                  characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
