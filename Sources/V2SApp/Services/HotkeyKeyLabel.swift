import Carbon.HIToolbox
import Foundation

/// Text for a shortcut, as shown in Settings and the popover: "⌃⌥T".
enum HotkeyKeyLabel {
    static func displayString(
        for binding: HotkeyBinding,
        keyLabel: (UInt16) -> String? = currentLayoutLabel(forKeyCode:)
    ) -> String {
        binding.modifiers.symbols + (fixedLabels[binding.keyCode] ?? keyLabel(binding.keyCode) ?? "?")
    }

    /// The character the key produces in the active keyboard layout, so the label
    /// matches what is printed on the key (Z and Y swap on a German layout).
    static func currentLayoutLabel(forKeyCode keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }

            return UCKeyTranslate(
                layout,
                keyCode,
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

        guard status == noErr, length > 0 else {
            return nil
        }

        let label = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return label.isEmpty ? nil : label.uppercased()
    }

    /// Keys that produce no printable character, or whose name reads better than it.
    private static let fixedLabels: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
