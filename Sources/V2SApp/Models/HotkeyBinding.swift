import Foundation

/// Modifier keys a global shortcut can use. Fn is deliberately absent: macOS cannot
/// register it as part of a system-wide shortcut, and Wispr Flow uses it for
/// push-to-talk.
struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let control = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let shift = HotkeyModifiers(rawValue: 1 << 2)
    static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// The modifiers in the order macOS writes them: ⌃⌥⇧⌘.
    var symbols: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        return symbols
    }
}

/// A key combination, stored by key position (virtual key code) so it stays on the same
/// physical key whatever keyboard layout is active.
struct HotkeyBinding: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: HotkeyModifiers

    /// ⌃⌥T.
    static let defaultToggle = HotkeyBinding(keyCode: HotkeyKeyCode.t, modifiers: [.control, .option])
    /// ⌃⌥↑.
    static let defaultCatchUp = HotkeyBinding(keyCode: HotkeyKeyCode.upArrow, modifiers: [.control, .option])
    /// ⌃⌥C.
    static let defaultCopyRecent = HotkeyBinding(keyCode: HotkeyKeyCode.c, modifiers: [.control, .option])
}

/// The shortcut as stored in settings. A settings file written before the shortcut
/// existed has no entry and gets the default; `binding == nil` is the user's own
/// choice to have no shortcut, and has to survive a relaunch.
struct HotkeySetting: Codable, Equatable, Sendable {
    var binding: HotkeyBinding?

    static let defaultToggle = HotkeySetting(binding: .defaultToggle)
    static let defaultCatchUp = HotkeySetting(binding: .defaultCatchUp)
    static let defaultCopyRecent = HotkeySetting(binding: .defaultCopyRecent)
    static let cleared = HotkeySetting(binding: nil)
}

/// Virtual key codes the shortcut rules need by name.
enum HotkeyKeyCode {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let f: UInt16 = 3
    static let h: UInt16 = 4
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let q: UInt16 = 12
    static let w: UInt16 = 13
    static let t: UInt16 = 17
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
    static let o: UInt16 = 31
    static let p: UInt16 = 35
    static let returnKey: UInt16 = 36
    static let comma: UInt16 = 43
    static let n: UInt16 = 45
    static let m: UInt16 = 46
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let grave: UInt16 = 50
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let upArrow: UInt16 = 126

    /// Keys whose events always carry the Fn flag, whether or not Fn is held: the
    /// function row, the arrows and the navigation cluster.
    static let keysCarryingFunctionFlag: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1-F12
        105, 107, 113, 106, 64, 79, 80, 90, // F13-F20
        123, 124, 125, 126, // arrows
        115, 119, 116, 121, 117, 114, // home, end, page up, page down, forward delete, help
    ]
}

/// Why a key combination cannot be the shortcut.
enum HotkeyBindingIssue: Equatable, Sendable {
    /// No Control, Option or Command: the key would stop working for typing.
    case needsModifier
    /// Fn was held. Wispr Flow's push-to-talk key stays out of our shortcuts.
    case usesFunctionModifier
    /// A shortcut macOS itself has switched on (Spotlight, Mission Control, screenshots).
    case usedBySystem
    /// A shortcut nearly every app relies on, such as ⌘C or ⌘Q.
    case commonlyUsed
    /// Another of this app's own shortcuts already uses the combination.
    case usedByThisApp
}

/// What the shortcut recorder makes of one key press.
enum HotkeyCapture: Equatable, Sendable {
    case cancelled
    case accepted(HotkeyBinding)
    case rejected(HotkeyBindingIssue)
}

/// Decides which key combinations may become the shortcut.
struct HotkeyBindingRules: Sendable {
    /// Shortcuts macOS currently has enabled, read when a combination is checked so a
    /// change in System Settings is picked up.
    var systemShortcuts: @Sendable () -> Set<HotkeyBinding>

    init(systemShortcuts: @escaping @Sendable () -> Set<HotkeyBinding> = { [] }) {
        self.systemShortcuts = systemShortcuts
    }

    func issue(for binding: HotkeyBinding) -> HotkeyBindingIssue? {
        guard binding.modifiers.isDisjoint(with: [.control, .option, .command]) == false else {
            return .needsModifier
        }

        if systemShortcuts().contains(binding) {
            return .usedBySystem
        }

        if Self.commonShortcuts.contains(binding) {
            return .commonlyUsed
        }

        return nil
    }

    /// - Parameter functionModifierHeld: Fn was held as a modifier. The caller leaves
    ///   out the Fn flag that function-row and arrow keys always carry.
    func capture(keyCode: UInt16, modifiers: HotkeyModifiers, functionModifierHeld: Bool) -> HotkeyCapture {
        if keyCode == HotkeyKeyCode.escape, modifiers.isEmpty, functionModifierHeld == false {
            return .cancelled
        }

        if functionModifierHeld {
            return .rejected(.usesFunctionModifier)
        }

        let binding = HotkeyBinding(keyCode: keyCode, modifiers: modifiers)
        if let issue = issue(for: binding) {
            return .rejected(issue)
        }

        return .accepted(binding)
    }

    /// Shortcuts that are not system settings but that taking over would break in
    /// almost every app.
    static let commonShortcuts: Set<HotkeyBinding> = {
        let commandKeys: [UInt16] = [
            HotkeyKeyCode.q, HotkeyKeyCode.w, HotkeyKeyCode.h, HotkeyKeyCode.m,
            HotkeyKeyCode.c, HotkeyKeyCode.v, HotkeyKeyCode.x, HotkeyKeyCode.z,
            HotkeyKeyCode.a, HotkeyKeyCode.s, HotkeyKeyCode.n, HotkeyKeyCode.o,
            HotkeyKeyCode.p, HotkeyKeyCode.f, HotkeyKeyCode.t, HotkeyKeyCode.comma,
            HotkeyKeyCode.tab, HotkeyKeyCode.space, HotkeyKeyCode.grave,
        ]
        var shortcuts = Set(commandKeys.map { HotkeyBinding(keyCode: $0, modifiers: .command) })
        shortcuts.formUnion([
            HotkeyBinding(keyCode: HotkeyKeyCode.z, modifiers: [.command, .shift]),
            HotkeyBinding(keyCode: HotkeyKeyCode.tab, modifiers: [.command, .shift]),
            HotkeyBinding(keyCode: HotkeyKeyCode.grave, modifiers: [.command, .shift]),
            HotkeyBinding(keyCode: HotkeyKeyCode.h, modifiers: [.command, .option]),
            HotkeyBinding(keyCode: HotkeyKeyCode.escape, modifiers: [.command, .option]),
            HotkeyBinding(keyCode: HotkeyKeyCode.q, modifiers: [.command, .control]),
            HotkeyBinding(keyCode: HotkeyKeyCode.f, modifiers: [.command, .control]),
            HotkeyBinding(keyCode: HotkeyKeyCode.space, modifiers: [.command, .control]),
            HotkeyBinding(keyCode: HotkeyKeyCode.three, modifiers: [.command, .shift]),
            HotkeyBinding(keyCode: HotkeyKeyCode.four, modifiers: [.command, .shift]),
            HotkeyBinding(keyCode: HotkeyKeyCode.five, modifiers: [.command, .shift]),
        ])
        return shortcuts
    }()
}
