import SwiftUI

/// Microphone and spoken language for meetings, shared by the popover and Settings.
struct MeetingControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsControlRow(label: model.localized(.microphone)) {
                Picker(model.localized(.microphone), selection: model.meetingMicrophoneBinding) {
                    Text(model.localized(.meetingDefaultMicrophone)).tag(String?.none)
                    ForEach(model.microphoneSources) { microphone in
                        Text(microphone.name).tag(Optional(microphone.detail))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(meeting.isActive)
            SettingsControlRow(label: model.localized(.spokenLanguage)) {
                CommonLanguageMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    options: model.meetingLanguageOptions,
                    selection: model.meetingLanguageBinding
                )
            }
            .disabled(meeting.isActive)
            if let notice = model.meetingLanguageNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The popover's start and stop button for a meeting.
struct MeetingActionButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingController

    var body: some View {
        Button {
            if meeting.isActive {
                Task { await meeting.stop() }
            } else {
                meeting.prepareToStart()
            }
        } label: {
            SessionActionButtonLabel(
                title: meeting.isActive ? model.localized(.meetingStop) : model.localized(.meetingStart),
                symbolName: meeting.isActive ? "stop.circle.fill" : "record.circle",
                showsActivity: meeting.state == .starting || meeting.state == .finishing,
                shortcutHint: model.meetingSettings.hotkey.binding.map { HotkeyKeyLabel.displayString(for: $0) }
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(meeting.isActive ? .red : nil)
        .controlSize(.large)
        .disabled(meeting.state == .finishing)
    }
}
