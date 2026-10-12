import Carbon.HIToolbox
import XCTest
@testable import v2s

final class HotkeyBindingTests: XCTestCase {
    private let rules = HotkeyBindingRules(systemShortcuts: {
        // Spotlight, as macOS reports it.
        [HotkeyBinding(keyCode: HotkeyKeyCode.space, modifiers: .command)]
    })

    func testDefaultShortcutIsControlOptionTAndIsAllowed() {
        let binding = HotkeyBinding.defaultToggle

        XCTAssertEqual(binding.keyCode, UInt16(kVK_ANSI_T))
        XCTAssertEqual(binding.modifiers, [.control, .option])
        XCTAssertNil(rules.issue(for: binding))
        XCTAssertNil(HotkeyBindingRules().issue(for: binding))
    }

    func testAKeyAloneOrWithShiftOnlyIsRejected() {
        XCTAssertEqual(rules.issue(for: HotkeyBinding(keyCode: HotkeyKeyCode.t, modifiers: [])), .needsModifier)
        XCTAssertEqual(rules.issue(for: HotkeyBinding(keyCode: HotkeyKeyCode.t, modifiers: .shift)), .needsModifier)
        // F5 alone: the function row does not get a pass either.
        XCTAssertEqual(rules.issue(for: HotkeyBinding(keyCode: 96, modifiers: [])), .needsModifier)
    }

    func testShortcutsMacOSHasEnabledAreRejected() {
        XCTAssertEqual(
            rules.issue(for: HotkeyBinding(keyCode: HotkeyKeyCode.space, modifiers: .command)),
            .usedBySystem
        )
    }

    func testShortcutsEveryAppReliesOnAreRejected() {
        for keyCode in [HotkeyKeyCode.c, HotkeyKeyCode.v, HotkeyKeyCode.q, HotkeyKeyCode.w, HotkeyKeyCode.tab] {
            XCTAssertEqual(
                HotkeyBindingRules().issue(for: HotkeyBinding(keyCode: keyCode, modifiers: .command)),
                .commonlyUsed,
                "⌘ + key code \(keyCode)"
            )
        }
        // The same letters with more modifiers are free.
        XCTAssertNil(HotkeyBindingRules().issue(for: HotkeyBinding(keyCode: HotkeyKeyCode.c, modifiers: [.control, .option])))
    }

    func testCaptureAcceptsAValidCombination() {
        XCTAssertEqual(
            rules.capture(keyCode: HotkeyKeyCode.s, modifiers: [.control, .option], functionModifierHeld: false),
            .accepted(HotkeyBinding(keyCode: HotkeyKeyCode.s, modifiers: [.control, .option]))
        )
    }

    func testCaptureNeverAcceptsFn() {
        // Fn alone with a key, and Fn added to an otherwise fine combination.
        XCTAssertEqual(
            rules.capture(keyCode: HotkeyKeyCode.t, modifiers: [], functionModifierHeld: true),
            .rejected(.usesFunctionModifier)
        )
        XCTAssertEqual(
            rules.capture(keyCode: HotkeyKeyCode.t, modifiers: [.control, .option], functionModifierHeld: true),
            .rejected(.usesFunctionModifier)
        )
    }

    func testEscapeAloneCancelsButEscapeWithModifiersIsACombination() {
        XCTAssertEqual(
            rules.capture(keyCode: HotkeyKeyCode.escape, modifiers: [], functionModifierHeld: false),
            .cancelled
        )
        XCTAssertEqual(
            rules.capture(keyCode: HotkeyKeyCode.escape, modifiers: [.control, .option], functionModifierHeld: false),
            .accepted(HotkeyBinding(keyCode: HotkeyKeyCode.escape, modifiers: [.control, .option]))
        )
    }

    func testDisplayStringListsModifiersInSystemOrder() {
        let everything = HotkeyBinding(keyCode: HotkeyKeyCode.t, modifiers: [.command, .shift, .option, .control])

        XCTAssertEqual(HotkeyKeyLabel.displayString(for: .defaultToggle, keyLabel: { _ in "T" }), "⌃⌥T")
        XCTAssertEqual(HotkeyKeyLabel.displayString(for: everything, keyLabel: { _ in "T" }), "⌃⌥⇧⌘T")
    }

    func testDisplayStringNamesKeysWithoutACharacter() {
        let noLayout: (UInt16) -> String? = { _ in nil }

        XCTAssertEqual(
            HotkeyKeyLabel.displayString(for: HotkeyBinding(keyCode: HotkeyKeyCode.space, modifiers: .control), keyLabel: noLayout),
            "⌃Space"
        )
        XCTAssertEqual(
            HotkeyKeyLabel.displayString(for: HotkeyBinding(keyCode: 126, modifiers: [.control, .option]), keyLabel: noLayout),
            "⌃⌥↑"
        )
        XCTAssertEqual(
            HotkeyKeyLabel.displayString(for: HotkeyBinding(keyCode: 96, modifiers: .command), keyLabel: noLayout),
            "⌘F5"
        )
        XCTAssertEqual(
            HotkeyKeyLabel.displayString(for: HotkeyBinding(keyCode: 200, modifiers: .command), keyLabel: noLayout),
            "⌘?"
        )
    }

    func testCurrentLayoutLabelsTheDefaultKey() throws {
        // Every Latin layout has T on key 17; a non-Latin layout shows its own letter.
        let label = try XCTUnwrap(HotkeyKeyLabel.currentLayoutLabel(forKeyCode: HotkeyKeyCode.t))
        XCTAssertEqual(label.count, 1)
        XCTAssertEqual(label, label.uppercased())
    }

    func testCarbonFlagsRoundTrip() {
        let modifiers: HotkeyModifiers = [.control, .option]

        XCTAssertEqual(modifiers.carbonFlags, UInt32(controlKey | optionKey))
        XCTAssertEqual(HotkeyModifiers(carbonFlags: UInt32(cmdKey | shiftKey)), [.command, .shift])
        XCTAssertEqual(HotkeyModifiers(carbonFlags: modifiers.carbonFlags), modifiers)
    }

    func testSystemShortcutCatalogKeepsOnlyEnabledShortcutsWithAKey() {
        let entries: [[String: Any]] = [
            [
                kHISymbolicHotKeyCode as String: 49,
                kHISymbolicHotKeyModifiers as String: cmdKey,
                kHISymbolicHotKeyEnabled as String: true,
            ],
            [
                kHISymbolicHotKeyCode as String: 20,
                kHISymbolicHotKeyModifiers as String: cmdKey | shiftKey,
                kHISymbolicHotKeyEnabled as String: false,
            ],
            [
                // An action with no key assigned.
                kHISymbolicHotKeyCode as String: 65535,
                kHISymbolicHotKeyModifiers as String: 0,
                kHISymbolicHotKeyEnabled as String: true,
            ],
        ]

        XCTAssertEqual(
            SystemShortcutCatalog.shortcuts(from: entries),
            [HotkeyBinding(keyCode: 49, modifiers: .command)]
        )
    }

    func testSystemShortcutCatalogReadsThisMacWithoutFailing() {
        // What is enabled differs per Mac; the call itself must work and return key codes.
        for shortcut in SystemShortcutCatalog.enabledShortcuts() {
            XCTAssertLessThan(shortcut.keyCode, UInt16.max)
        }
    }
}
