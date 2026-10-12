import Carbon.HIToolbox
import Foundation
import os.log

private extension Logger {
    static let hotkey = Logger(subsystem: "com.franklioxygen.v2s", category: "hotkey")
}

enum HotkeyRegistrationResult: Equatable, Sendable {
    case registered
    case failed(status: Int32)
}

/// Registers one system-wide shortcut with macOS.
protocol HotkeyRegistrar: AnyObject {
    /// Replaces any earlier registration. `onPress` runs on the main thread.
    func register(_ binding: HotkeyBinding, onPress: @escaping () -> Void) -> HotkeyRegistrationResult
    func unregister()
}

/// Keeps the global shortcut registered and reports presses.
@MainActor
final class HotkeyService: ObservableObject {
    enum Status: Equatable {
        /// No shortcut is set, or it is suspended while the recorder listens.
        case off
        case active(HotkeyBinding)
        /// macOS refused the registration, so pressing the shortcut does nothing.
        case unavailable(HotkeyBinding)
    }

    @Published private(set) var status: Status = .off
    var onPress: (() -> Void)?

    private let registrar: HotkeyRegistrar
    private var binding: HotkeyBinding?
    private var isSuspended = false

    init(registrar: HotkeyRegistrar) {
        self.registrar = registrar
    }

    func setBinding(_ binding: HotkeyBinding?) {
        guard self.binding != binding else {
            return
        }

        self.binding = binding
        applyRegistration()
    }

    /// Releases the shortcut while the recorder listens, so the current combination
    /// can be typed again instead of toggling subtitles.
    func suspend() {
        guard isSuspended == false else { return }
        isSuspended = true
        applyRegistration()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        applyRegistration()
    }

    private func applyRegistration() {
        guard let binding, isSuspended == false else {
            registrar.unregister()
            status = .off
            return
        }

        let result = registrar.register(binding) { [weak self] in
            MainActor.assumeIsolated {
                Logger.hotkey.info("Global shortcut pressed")
                self?.onPress?()
            }
        }

        switch result {
        case .registered:
            Logger.hotkey.log(
                "Global shortcut registered: key \(binding.keyCode) modifiers \(binding.modifiers.rawValue)"
            )
            status = .active(binding)
        case .failed(let failure):
            Logger.hotkey.error("macOS refused the global shortcut: status \(failure)")
            status = .unavailable(binding)
        }
    }
}

/// Carbon's `RegisterEventHotKey`: the one system API for a global shortcut that needs
/// no Accessibility permission and works for an app without a Dock icon. Use it from
/// the main thread only.
///
/// macOS does not report a combination another app has already registered: the call
/// succeeds for both, so a clash with another app cannot be detected here.
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private static let signature: OSType = 0x5632_5348 // "V2SH"

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var onPress: (() -> Void)?
    // A new identifier per registration, unique in the app: a press still queued for
    // an earlier registration, or meant for another registrar, must not fire this one.
    private static var lastIdentifier: UInt32 = 0
    private var currentIdentifier: UInt32 = 0

    deinit {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(_ binding: HotkeyBinding, onPress: @escaping () -> Void) -> HotkeyRegistrationResult {
        unregister()

        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            return .failed(status: handlerStatus)
        }

        Self.lastIdentifier &+= 1
        currentIdentifier = Self.lastIdentifier
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: currentIdentifier),
            GetEventDispatcherTarget(),
            0,
            &registered
        )

        guard status == noErr, let registered else {
            return .failed(status: status == noErr ? OSStatus(eventInternalErr) : status)
        }

        hotKey = registered
        self.onPress = onPress
        return .registered
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }

        hotKey = nil
        onPress = nil
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else {
            return noErr
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        return InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                return registrar.handle(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )

        guard status == noErr,
              identifier.signature == Self.signature,
              identifier.id == currentIdentifier,
              let onPress else {
            return OSStatus(eventNotHandledErr)
        }

        onPress()
        return noErr
    }

#if DEBUG
    /// Delivers the event macOS sends when the registered shortcut is pressed, through
    /// the same dispatcher. Tests cannot press real keys.
    func simulatePressForTesting(identifierOffset: UInt32 = 0) -> OSStatus {
        var event: EventRef?
        let createStatus = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            0,
            EventAttributes(kEventAttributeNone),
            &event
        )
        guard createStatus == noErr, let event else {
            return createStatus
        }
        defer { ReleaseEvent(event) }

        var identifier = EventHotKeyID(signature: Self.signature, id: currentIdentifier &+ identifierOffset)
        let parameterStatus = SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &identifier
        )
        guard parameterStatus == noErr else {
            return parameterStatus
        }

        return SendEventToEventTarget(event, GetEventDispatcherTarget())
    }
#endif
}

extension HotkeyModifiers {
    var carbonFlags: UInt32 {
        var flags = 0
        if contains(.control) { flags |= controlKey }
        if contains(.option) { flags |= optionKey }
        if contains(.shift) { flags |= shiftKey }
        if contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    init(carbonFlags: UInt32) {
        var modifiers: HotkeyModifiers = []
        let flags = Int(carbonFlags)
        if flags & controlKey != 0 { modifiers.insert(.control) }
        if flags & optionKey != 0 { modifiers.insert(.option) }
        if flags & shiftKey != 0 { modifiers.insert(.shift) }
        if flags & cmdKey != 0 { modifiers.insert(.command) }
        self = modifiers
    }
}
