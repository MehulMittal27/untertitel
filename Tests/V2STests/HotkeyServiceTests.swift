import XCTest
@testable import v2s

private final class FakeHotkeyRegistrar: HotkeyRegistrar {
    var result: HotkeyRegistrationResult = .registered
    private(set) var registered: HotkeyBinding?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private var onPress: (() -> Void)?

    func register(_ binding: HotkeyBinding, onPress: @escaping () -> Void) -> HotkeyRegistrationResult {
        registerCount += 1
        guard result == .registered else {
            registered = nil
            self.onPress = nil
            return result
        }

        registered = binding
        self.onPress = onPress
        return result
    }

    func unregister() {
        unregisterCount += 1
        registered = nil
        onPress = nil
    }

    func press() {
        onPress?()
    }
}

@MainActor
final class HotkeyServiceTests: XCTestCase {
    private let other = HotkeyBinding(keyCode: HotkeyKeyCode.s, modifiers: [.control, .command])

    func testSettingABindingRegistersItAndPressesReachTheHandler() {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        var presses = 0
        service.onPress = { presses += 1 }

        XCTAssertEqual(service.status, .off)
        service.setBinding(.defaultToggle)

        XCTAssertEqual(registrar.registered, .defaultToggle)
        XCTAssertEqual(service.status, .active(.defaultToggle))

        registrar.press()
        registrar.press()
        XCTAssertEqual(presses, 2)
    }

    func testChangingTheBindingReplacesTheRegistration() {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        service.setBinding(.defaultToggle)

        service.setBinding(other)

        XCTAssertEqual(registrar.registered, other)
        XCTAssertEqual(service.status, .active(other))
        XCTAssertEqual(registrar.registerCount, 2)

        // The same binding again is not registered a second time.
        service.setBinding(other)
        XCTAssertEqual(registrar.registerCount, 2)
    }

    func testClearingTheBindingLeavesNoShortcutActive() {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        var presses = 0
        service.onPress = { presses += 1 }
        service.setBinding(.defaultToggle)

        service.setBinding(nil)

        XCTAssertNil(registrar.registered)
        XCTAssertEqual(service.status, .off)
        registrar.press()
        XCTAssertEqual(presses, 0)
    }

    func testARefusedRegistrationIsReported() {
        let registrar = FakeHotkeyRegistrar()
        registrar.result = .failed(status: -9878)
        let service = HotkeyService(registrar: registrar)

        service.setBinding(.defaultToggle)

        XCTAssertEqual(service.status, .unavailable(.defaultToggle))
    }

    func testSuspendingReleasesTheShortcutAndResumingRestoresIt() {
        let registrar = FakeHotkeyRegistrar()
        let service = HotkeyService(registrar: registrar)
        var presses = 0
        service.onPress = { presses += 1 }
        service.setBinding(.defaultToggle)

        service.suspend()
        XCTAssertNil(registrar.registered, "the recorder must be able to hear the current combination")
        XCTAssertEqual(service.status, .off)

        // A binding chosen while suspended takes effect on resume.
        service.setBinding(other)
        XCTAssertNil(registrar.registered)

        service.resume()
        XCTAssertEqual(registrar.registered, other)
        XCTAssertEqual(service.status, .active(other))
        registrar.press()
        XCTAssertEqual(presses, 1)
    }
}

/// The real macOS registration. A key combination nobody uses (⌃⌥⇧⌘F19), registered
/// for the length of one test.
@MainActor
final class CarbonHotkeyRegistrarTests: XCTestCase {
    private let unusedBinding = HotkeyBinding(keyCode: 80, modifiers: [.control, .option, .shift, .command])

    func testRegistersWithMacOSAndDeliversAPress() {
        let registrar = CarbonHotkeyRegistrar()
        var presses = 0

        XCTAssertEqual(registrar.register(unusedBinding) { presses += 1 }, .registered)

        XCTAssertEqual(registrar.simulatePressForTesting(), noErr)
        XCTAssertEqual(presses, 1)
    }

    func testNothingFiresAfterUnregistering() {
        let registrar = CarbonHotkeyRegistrar()
        var presses = 0
        XCTAssertEqual(registrar.register(unusedBinding) { presses += 1 }, .registered)

        registrar.unregister()

        XCTAssertNotEqual(registrar.simulatePressForTesting(), noErr)
        XCTAssertEqual(presses, 0)
    }

    func testAPressQueuedForAnEarlierRegistrationDoesNotFireTheNewOne() {
        let registrar = CarbonHotkeyRegistrar()
        var firstPresses = 0
        var secondPresses = 0
        XCTAssertEqual(registrar.register(unusedBinding) { firstPresses += 1 }, .registered)
        XCTAssertEqual(registrar.register(unusedBinding) { secondPresses += 1 }, .registered)

        // The identifier of the registration that was replaced.
        XCTAssertNotEqual(registrar.simulatePressForTesting(identifierOffset: UInt32.max), noErr)
        XCTAssertEqual(firstPresses, 0)
        XCTAssertEqual(secondPresses, 0)

        XCTAssertEqual(registrar.simulatePressForTesting(), noErr)
        XCTAssertEqual(firstPresses, 0)
        XCTAssertEqual(secondPresses, 1)
    }

    func testTwoRegistrarsEachHearOnlyTheirOwnShortcut() {
        let first = CarbonHotkeyRegistrar()
        let second = CarbonHotkeyRegistrar()
        var firstPresses = 0
        var secondPresses = 0
        XCTAssertEqual(first.register(unusedBinding) { firstPresses += 1 }, .registered)
        // macOS refuses the same combination twice within one app.
        XCTAssertNotEqual(second.register(unusedBinding) { secondPresses += 1 }, .registered)

        XCTAssertEqual(first.simulatePressForTesting(), noErr)
        XCTAssertEqual(firstPresses, 1)
        XCTAssertEqual(secondPresses, 0)
    }
}
