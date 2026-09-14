import AppKit
import Carbon

/// Human-readable names for virtual key codes, resolved through the current
/// keyboard layout so a French or Dvorak user sees their own key caps.
enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        if let special = specials[Int(keyCode)] {
            return special
        }
        if let translated = translate(keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// The lowercase character for `NSMenuItem.keyEquivalent`, or `""` when the
    /// key has no printable form.
    static func menuKeyEquivalent(for keyCode: UInt32) -> String {
        if let function = functionKeyEquivalents[Int(keyCode)] {
            return function
        }
        return translate(keyCode)?.lowercased() ?? ""
    }

    private static let specials: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let functionKeyEquivalents: [Int: String] = [
        kVK_Return: "\r", kVK_Tab: "\t", kVK_Space: " ", kVK_Delete: "\u{8}", kVK_Escape: "\u{1B}",
        kVK_ForwardDelete: String(UnicodeScalar(NSDeleteFunctionKey)!),
        kVK_LeftArrow: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        kVK_RightArrow: String(UnicodeScalar(NSRightArrowFunctionKey)!),
        kVK_UpArrow: String(UnicodeScalar(NSUpArrowFunctionKey)!),
        kVK_DownArrow: String(UnicodeScalar(NSDownArrowFunctionKey)!),
        kVK_Home: String(UnicodeScalar(NSHomeFunctionKey)!),
        kVK_End: String(UnicodeScalar(NSEndFunctionKey)!),
        kVK_PageUp: String(UnicodeScalar(NSPageUpFunctionKey)!),
        kVK_PageDown: String(UnicodeScalar(NSPageDownFunctionKey)!),
        kVK_F1: String(UnicodeScalar(NSF1FunctionKey)!), kVK_F2: String(UnicodeScalar(NSF2FunctionKey)!),
        kVK_F3: String(UnicodeScalar(NSF3FunctionKey)!), kVK_F4: String(UnicodeScalar(NSF4FunctionKey)!),
        kVK_F5: String(UnicodeScalar(NSF5FunctionKey)!), kVK_F6: String(UnicodeScalar(NSF6FunctionKey)!),
        kVK_F7: String(UnicodeScalar(NSF7FunctionKey)!), kVK_F8: String(UnicodeScalar(NSF8FunctionKey)!),
        kVK_F9: String(UnicodeScalar(NSF9FunctionKey)!), kVK_F10: String(UnicodeScalar(NSF10FunctionKey)!),
        kVK_F11: String(UnicodeScalar(NSF11FunctionKey)!), kVK_F12: String(UnicodeScalar(NSF12FunctionKey)!),
    ]

    private static func translate(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
