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
    private var reserved: Set<HotkeyBinding> = []
    private var keyMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []

    init(rules: HotkeyBindingRules = HotkeyBindingRules { SystemShortcutCatalog.enabledShortcuts() }) {
        self.rules = rules
    }

    /// - Parameter reserved: Combinations the app's other shortcuts already use.
    func start(reserved: Set<HotkeyBinding> = [], onAccept: @escaping (HotkeyBinding) -> Void) {
        guard isRecording == false else { return }

        self.reserved = reserved
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
            guard reserved.contains(binding) == false else {
                issue = .usedByThisApp
                return
            }
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

/// The app's global shortcuts. Kept together so all of them can be released while one
/// is being re-typed: otherwise typing a combination another one holds would trigger it.
@MainActor
final class AppHotkeys {
    let toggle: HotkeyService
    let catchUp: HotkeyService
    let copyRecent: HotkeyService

    init(toggle: HotkeyService, catchUp: HotkeyService, copyRecent: HotkeyService) {
        self.toggle = toggle
        self.catchUp = catchUp
        self.copyRecent = copyRecent
    }

    /// One service only: for previews and tests of the toggle shortcut.
    convenience init(toggle: HotkeyService, makeService: () -> HotkeyService) {
        self.init(toggle: toggle, catchUp: makeService(), copyRecent: makeService())
    }

    var all: [HotkeyService] { [toggle, catchUp, copyRecent] }

    func suspendAll() {
        all.forEach { $0.suspend() }
    }

    func resumeAll() {
        all.forEach { $0.resume() }
    }
}

/// The shortcut card in Settings: the shortcuts themselves and how a toggle is confirmed.
struct ShortcutSettingsSection: View {
    @ObservedObject var model: AppModel
    let hotkeys: AppHotkeys
    var recorder: HotkeyRecorder?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HotkeyRecorderRow(
                model: model,
                label: model.localized(.toggleSubtitlesShortcut),
                binding: $model.toggleHotkey,
                otherBindings: [model.catchUpHotkey, model.copyRecentHotkey],
                hotkeyService: hotkeys.toggle,
                hotkeys: hotkeys,
                recorder: recorder
            )
            Text(model.localized(.shortcutHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            toggleRow(model.localized(.toggleLabelSetting), isOn: $model.showsToggleLabel)
            Divider()
            toggleRow(model.localized(.toggleSoundSetting), isOn: $model.playsToggleSound)
            Divider()
            HotkeyRecorderRow(
                model: model,
                label: model.localized(.catchUpShortcut),
                binding: $model.catchUpHotkey,
                otherBindings: [model.toggleHotkey, model.copyRecentHotkey],
                hotkeyService: hotkeys.catchUp,
                hotkeys: hotkeys
            )
            Divider()
            HotkeyRecorderRow(
                model: model,
                label: model.localized(.copyRecentShortcut),
                binding: $model.copyRecentHotkey,
                otherBindings: [model.toggleHotkey, model.catchUpHotkey],
                hotkeyService: hotkeys.copyRecent,
                hotkeys: hotkeys
            )
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

/// Settings row that shows one shortcut, records a new one and clears it.
struct HotkeyRecorderRow: View {
    @ObservedObject var model: AppModel
    let label: String
    @Binding var binding: HotkeyBinding?
    /// What the app's other shortcuts are set to, so two cannot share a combination.
    let otherBindings: [HotkeyBinding?]
    @ObservedObject var hotkeyService: HotkeyService
    let hotkeys: AppHotkeys
    @StateObject private var recorder: HotkeyRecorder

    init(
        model: AppModel,
        label: String,
        binding: Binding<HotkeyBinding?>,
        otherBindings: [HotkeyBinding?],
        hotkeyService: HotkeyService,
        hotkeys: AppHotkeys,
        recorder: HotkeyRecorder? = nil
    ) {
        self.model = model
        self.label = label
        _binding = binding
        self.otherBindings = otherBindings
        self.hotkeyService = hotkeyService
        self.hotkeys = hotkeys
        _recorder = StateObject(wrappedValue: recorder ?? HotkeyRecorder())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: toggleRecording) {
                    Text(fieldText)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(recorder.isRecording || binding == nil ? .secondary : .primary)
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
                    binding = nil
                }
                .controlSize(.small)
                .disabled(binding == nil)
            }
            if let message = issueMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            // Every shortcut is released while one is being re-typed, so pressing a
            // combination records it instead of triggering whatever holds it.
            if isRecording {
                hotkeys.suspendAll()
            } else {
                hotkeys.resumeAll()
            }
        }
        .onDisappear {
            if recorder.isRecording {
                recorder.cancel()
                hotkeys.resumeAll()
            }
        }
    }

    private var fieldText: String {
        if recorder.isRecording {
            return model.localized(.shortcutRecordingPrompt)
        }

        return binding.map { HotkeyKeyLabel.displayString(for: $0) } ?? model.localized(.shortcutNone)
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
            case .usedByThisApp:
                return model.localized(.shortcutUsedByThisApp)
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
            recorder.start(reserved: Set(otherBindings.compactMap { $0 })) { accepted in
                binding = accepted
            }
        }
    }
}
