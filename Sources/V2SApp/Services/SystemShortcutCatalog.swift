import Carbon.HIToolbox
import Foundation

/// The keyboard shortcuts macOS itself has switched on in System Settings: Spotlight,
/// Mission Control, screenshots, input-source switching and the like.
enum SystemShortcutCatalog {
    static func enabledShortcuts() -> Set<HotkeyBinding> {
        var unmanagedShortcuts: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanagedShortcuts) == noErr,
              let entries = unmanagedShortcuts?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }

        return shortcuts(from: entries)
    }

    static func shortcuts(from entries: [[String: Any]]) -> Set<HotkeyBinding> {
        var shortcuts = Set<HotkeyBinding>()
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let keyCode = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  // An action with no key assigned is listed with key code 65535.
                  (0..<Int(UInt16.max)).contains(keyCode) else {
                continue
            }

            shortcuts.insert(
                HotkeyBinding(
                    keyCode: UInt16(keyCode),
                    modifiers: HotkeyModifiers(carbonFlags: UInt32(truncatingIfNeeded: modifiers))
                )
            )
        }
        return shortcuts
    }
}
