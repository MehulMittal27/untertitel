import AppKit
import SwiftUI

/// Microphone and spoken language for meetings, shared by the popover and Settings.
struct MeetingControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingController
    @ObservedObject var models: MeetingModelsService

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
            if let notice = model.meetingLanguageNotice(modelsInstalled: models.isInstalled),
               model.meetingSettings.liveEngine == .onDevice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsControlRow(label: model.localized(.meetingLiveEngine)) {
                Picker(model.localized(.meetingLiveEngine), selection: model.meetingLiveEngineBinding) {
                    Text(model.localized(.meetingEngineOnDevice)).tag(MeetingLiveEngine.onDevice)
                    Text(model.localized(.meetingEngineSoniox)).tag(MeetingLiveEngine.soniox)
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(meeting.state.isBusy)
            SettingsControlRow(label: model.localized(.meetingFinalPassLabel)) {
                Picker(model.localized(.meetingFinalPassLabel), selection: model.meetingFinalPassBinding) {
                    Text(model.localized(.meetingFinalOnDevice)).tag(MeetingFinalPassChoice.onDevice)
                    Text(model.localized(.meetingFinalSonioxFile)).tag(MeetingFinalPassChoice.sonioxFile)
                    Text(model.localized(.meetingFinalOff)).tag(MeetingFinalPassChoice.off)
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(meeting.state.isBusy)
            if let notice = model.meetingSonioxKeyNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Saving transcripts in Settings: the switch, where they go, and deleting them.
struct MeetingSavingRow: View {
    @ObservedObject var model: AppModel
    var store = MeetingTranscriptStore()
    @State private var confirmsDeleteAll = false
    @State private var savedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsControlRow(label: model.localized(.meetingSaveTranscripts)) {
                Toggle("", isOn: model.meetingSavesTranscriptsBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(model.localized(.meetingSaveExplanationFormat, MeetingTranscriptStore.displayPath))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.localized(.meetingShowInFinder)) {
                    try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.folder)
                }
                Button(model.localized(.meetingDeleteAll), role: .destructive) {
                    confirmsDeleteAll = true
                }
                .disabled(savedCount == 0)
            }
            .controlSize(.small)
        }
        .onAppear { savedCount = store.transcripts().count }
        .confirmationDialog(model.localized(.meetingDeleteAllConfirm), isPresented: $confirmsDeleteAll) {
            Button(model.localized(.meetingDeleteAll), role: .destructive) {
                try? store.deleteAll()
                savedCount = store.transcripts().count
            }
            Button(model.localized(.cancel), role: .cancel) {}
        }
    }
}

/// Debug: keep the last meeting's audio for a day, for diagnosis.
struct MeetingDiagnosisRow: View {
    @ObservedObject var model: AppModel
    var store = MeetingDebugStore()
    @State private var hasFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsControlRow(label: model.localized(.meetingKeepDebugAudio)) {
                Toggle("", isOn: Binding(
                    get: { model.meetingSettings.keepsDiagnosisAudio },
                    set: { keeps in
                        model.meetingKeepsDiagnosisAudioBinding.wrappedValue = keeps
                        if keeps == false {
                            store.deleteAll()
                            hasFiles = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text(model.localized(.meetingKeepDebugAudioExplanation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hasFiles {
                HStack {
                    Spacer()
                    Button(model.localized(.meetingDebugAudioDeleteNow), role: .destructive) {
                        store.deleteAll()
                        hasFiles = false
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { hasFiles = store.hasFiles }
    }
}

/// The meeting models in Settings: whether they are here, download and delete.
struct MeetingModelsRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var models: MeetingModelsService

    static let credits = "FluidAudio (Apache-2.0); NVIDIA Parakeet (CC-BY-4.0) and Nemotron (OpenMDW-1.1); "
        + "pyannote community-1 (CC-BY-4.0); LS-EEND (MIT)."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsControlRow(label: model.localized(.meetingModelsTitle)) {
                HStack(spacing: 10) {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                        .lineLimit(1)
                    switch models.status {
                    case .notInstalled, .failed:
                        Button(model.localized(.meetingModelsDownload)) {
                            Task { await models.download() }
                        }
                    case .downloading:
                        EmptyView()
                    case .installed:
                        Button(model.localized(.meetingModelsDelete), role: .destructive) {
                            models.delete()
                        }
                    }
                }
            }
            if case .downloading(let fraction) = models.status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
            Text(model.localized(.meetingModelsExplanation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.credits)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusIsError: Bool {
        if case .failed = models.status { return true }
        return false
    }

    private var statusText: String {
        switch models.status {
        case .notInstalled:
            return model.localized(.meetingModelsNotInstalled)
        case .downloading(let fraction):
            return model.localized(.meetingModelsDownloadingFormat, fraction.formatted(.percent.precision(.fractionLength(0))))
        case .installed(let bytes):
            return model.localized(
                .meetingModelsInstalledFormat,
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            )
        case .failed(let message):
            return model.localized(.meetingModelsFailedFormat, message)
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
        .disabled(meeting.state == .finishing || meeting.state.isBusy && meeting.isActive == false)
    }
}
