import AppKit
import SwiftUI

/// Listens for the next key combination typed while the Settings window is in front.
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Why the last combination typed was turned down. Recording continues.
    @Published private(set) var issue: HotkeyBindingIssue?

    private let rules: HotkeyBindingRules
    private var onAccept: ((HotkeyBinding) -> Void)?
    private var keyMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []

    init(rules: HotkeyBindingRules = HotkeyBindingRules { SystemShortcutCatalog.enabledShortcuts() }) {
        self.rules = rules
    }

    func start(onAccept: @escaping (HotkeyBinding) -> Void) {
        guard isRecording == false else { return }

        self.onAccept = onAccept
        issue = nil
        isRecording = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.isARepeat == false {
                self.handleKey(keyCode: event.keyCode, flags: event.modifierFlags)
            }
            // Swallowed: the key must not also type into a field or trigger a menu.
            return nil
        }

        // Recording only makes sense while the window can receive keys.
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            focusObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.cancel()
                    }
                }
            )
        }
    }

    func cancel() {
        guard isRecording else { return }
        issue = nil
        finish()
    }

    func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }

        let functionModifierHeld = flags.contains(.function)
            && HotkeyKeyCode.keysCarryingFunctionFlag.contains(keyCode) == false

        switch rules.capture(
            keyCode: keyCode,
            modifiers: HotkeyModifiers(eventFlags: flags),
            functionModifierHeld: functionModifierHeld
        ) {
        case .cancelled:
            cancel()
        case .rejected(let issue):
            self.issue = issue
        case .accepted(let binding):
            let onAccept = onAccept
            issue = nil
            finish()
            onAccept?(binding)
        }
    }

    private func finish() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil

        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        focusObservers.removeAll()

        onAccept = nil
        isRecording = false
    }
}

extension HotkeyModifiers {
    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyModifiers = []
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}

/// The shortcut card in Settings: the shortcut itself and how a toggle is confirmed.
struct ShortcutSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hotkeyService: HotkeyService
    var recorder: HotkeyRecorder?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HotkeyRecorderRow(model: model, hotkeyService: hotkeyService, recorder: recorder)
            Text(model.localized(.shortcutHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            toggleRow(model.localized(.toggleLabelSetting), isOn: $model.showsToggleLabel)
            Divider()
            toggleRow(model.localized(.toggleSoundSetting), isOn: $model.playsToggleSound)
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        SettingsControlRow(label: label) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// Settings row that shows the shortcut, records a new one and clears it.
struct HotkeyRecorderRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hotkeyService: HotkeyService
    @StateObject private var recorder: HotkeyRecorder

    init(model: AppModel, hotkeyService: HotkeyService, recorder: HotkeyRecorder? = nil) {
        self.model = model
        self.hotkeyService = hotkeyService
        _recorder = StateObject(wrappedValue: recorder ?? HotkeyRecorder())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.localized(.toggleSubtitlesShortcut))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: toggleRecording) {
                    Text(fieldText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(recorder.isRecording || model.toggleHotkey == nil ? .secondary : .primary)
                        .frame(minWidth: 120)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: recorder.isRecording ? 2 : 0)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(model.localized(.shortcutRecordHelp))
                Button(model.localized(.clear)) {
                    recorder.cancel()
                    model.toggleHotkey = nil
                }
                .controlSize(.small)
                .disabled(model.toggleHotkey == nil)
            }
            if let message = issueMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            // The shortcut is released while it is being re-typed, so pressing the
            // current combination records it instead of toggling subtitles.
            if isRecording {
                hotkeyService.suspend()
            } else {
                hotkeyService.resume()
            }
        }
        .onDisappear {
            recorder.cancel()
            hotkeyService.resume()
        }
    }

    private var fieldText: String {
        if recorder.isRecording {
            return model.localized(.shortcutRecordingPrompt)
        }

        return model.toggleHotkeyDisplayText ?? model.localized(.shortcutNone)
    }

    private var issueMessage: String? {
        if recorder.isRecording {
            switch recorder.issue {
            case .needsModifier:
                return model.localized(.shortcutNeedsModifier)
            case .usesFunctionModifier:
                return model.localized(.shortcutFnNotAllowed)
            case .usedBySystem:
                return model.localized(.shortcutUsedBySystem)
            case .commonlyUsed:
                return model.localized(.shortcutCommonlyUsed)
            case nil:
                return nil
            }
        }

        if case .unavailable = hotkeyService.status {
            return model.localized(.shortcutUnavailable)
        }

        return nil
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.cancel()
        } else {
            recorder.start { binding in
                model.toggleHotkey = binding
            }
        }
    }
}
