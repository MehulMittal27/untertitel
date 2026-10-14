import AppKit
import MeetingKit
import SwiftUI

/// The meeting window: the consent note before a meeting, then its live transcript.
struct MeetingWindowView: View {
    @ObservedObject var meeting: MeetingController
    @ObservedObject var model: AppModel
    let copyText: (String) -> Void

    var body: some View {
        Group {
            switch meeting.state {
            case .consent:
                MeetingConsentView(meeting: meeting, model: model, copyText: copyText)
            case .failed(let message):
                MeetingFailureView(message: message, model: model) {
                    meeting.prepareToStart()
                }
            case .idle, .starting, .running, .finishing, .improving:
                MeetingTranscriptView(meeting: meeting, model: model, copyText: copyText)
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .environment(\.locale, model.interfaceLocale)
    }
}

/// The note to read out or paste before a meeting, with Start in it: one click.
struct MeetingConsentView: View {
    @ObservedObject var meeting: MeetingController
    @ObservedObject var model: AppModel
    let copyText: (String) -> Void
    @State private var noteLanguageID: String = "en"
    @State private var justCopied = false

    static let noteLanguageIDs = ["en", "de"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.localized(.meetingConsentTitle))
                .font(.title3.weight(.semibold))
            Text(model.localized(.meetingConsentIntro))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(model.localized(.meetingNoteLanguage), selection: $noteLanguageID) {
                ForEach(Self.noteLanguageIDs, id: \.self) { languageID in
                    Text(model.disclosureLanguageName(for: languageID)).tag(languageID)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if meeting.hasUnsavedTranscript {
                Label(model.localized(.meetingConsentUnsavedWarning), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text(model.localized(.meetingSpeakerCount))
                    .font(.callout)
                Picker(model.localized(.meetingSpeakerCount), selection: model.meetingSpeakerHintBinding) {
                    Text(model.localized(.meetingSpeakerCountAuto)).tag(SpeakerCountHint.auto)
                    Text("2").tag(SpeakerCountHint.two)
                    Text("3").tag(SpeakerCountHint.three)
                    Text("4+").tag(SpeakerCountHint.fourOrMore)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(model.localized(.meetingSpeakerCountHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(meeting.consentText(in: noteLanguageID))
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    copyText(meeting.consentText(in: noteLanguageID))
                    flashCopied($justCopied)
                } label: {
                    Label(
                        justCopied ? model.localized(.disclosureCopied) : model.localized(.copy),
                        systemImage: justCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                Spacer()
                Button(model.localized(.cancel)) {
                    meeting.cancelConsent()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task { await meeting.start() }
                } label: {
                    Label(model.localized(.meetingStart), systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            noteLanguageID = model.meetingSettings.languageID == "de" ? "de" : "en"
        }
    }
}

struct MeetingFailureView: View {
    let message: String
    @ObservedObject var model: AppModel
    let tryAgain: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.localized(.meetingTryAgain), action: tryAgain)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The live transcript: a clock and Stop while the meeting runs, one row per segment.
struct MeetingTranscriptView: View {
    @ObservedObject var meeting: MeetingController
    @ObservedObject var model: AppModel
    let copyText: (String) -> Void
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            cloudBar
            if let outcome = meeting.saveOutcome, meeting.state == .idle {
                saveBar(outcome)
            }
            Divider()
            transcript
        }
    }

    /// Soniox's state and cost while a meeting uses it, and a Resume after the pause.
    @ViewBuilder
    private var cloudBar: some View {
        let paused = meeting.cloudState == .pausedNoAudio
        if paused || meeting.liveNotice != nil || meeting.cloudCostText != nil {
            HStack(spacing: 10) {
                if paused {
                    Label(model.localized(.meetingCloudPaused), systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(model.localized(.meetingResume)) { meeting.resumeCloud() }
                        .controlSize(.small)
                } else if let notice = meeting.liveNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let cost = meeting.cloudCostText {
                    Label(cost, systemImage: "dollarsign.circle")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// Where the transcript was saved, with Show in Finder and a one-click delete.
    private func saveBar(_ outcome: MeetingController.SaveOutcome) -> some View {
        HStack(spacing: 10) {
            switch outcome {
            case .saved(let url):
                Label(model.localized(.meetingSavedFormat, url.lastPathComponent), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(model.localized(.meetingShowInFinder)) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
                Button(role: .destructive) {
                    meeting.deleteSavedTranscript()
                } label: {
                    Label(model.localized(.meetingDeleteTranscript), systemImage: "trash")
                }
                .controlSize(.small)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if meeting.isActive {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                Text(meeting.state == .finishing ? model.localized(.meetingFinishing) : model.localized(.meetingTranscribing))
                    .font(.headline)
            } else if case .improving(let fraction) = meeting.state {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(model.localized(.meetingImproving))
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)
            } else {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text(model.localized(.meetingWindowTitle))
                    .font(.headline)
            }
            if isImproving == false {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingTimecode.string(meeting.elapsed(at: context.date)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                copyText(meeting.copyText)
                flashCopied($justCopied)
            } label: {
                Label(
                    justCopied ? model.localized(.meetingTranscriptCopied) : model.localized(.meetingCopyTranscript),
                    systemImage: justCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(meeting.transcript.segments.isEmpty)
            if meeting.isActive {
                Button(role: .destructive) {
                    Task { await meeting.stop() }
                } label: {
                    Label(model.localized(.meetingStop), systemImage: "stop.circle")
                }
                .disabled(meeting.state == .finishing)
            } else if isImproving == false {
                Button {
                    meeting.prepareToStart()
                } label: {
                    Label(model.localized(.meetingStart), systemImage: "record.circle")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var isImproving: Bool {
        if case .improving = meeting.state { return true }
        return false
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if meeting.transcript.isEmpty {
                        Text(meeting.startedAt == nil ? model.localized(.meetingNoMeetingYet) : model.localized(.meetingListening))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    } else if meeting.transcript.speakers.isEmpty == false {
                        Text(meeting.showsProvisionalSpeakersNote
                            ? model.localized(.meetingSpeakersProvisional) + " " + model.localized(.meetingRenameHint)
                            : model.localized(.meetingRenameHint))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(meeting.transcript.segments) { segment in
                        MeetingSegmentRow(segment: segment, isDraft: false, meeting: meeting, model: model)
                            .id(segment.id)
                    }
                    if let draft = meeting.transcript.draft {
                        MeetingSegmentRow(segment: draft, isDraft: true, meeting: meeting, model: model)
                            .id(draft.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: meeting.transcript) { _, _ in
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private static let bottomID = "bottom"
}

struct MeetingSegmentRow: View {
    let segment: MeetingSegment
    let isDraft: Bool
    @ObservedObject var meeting: MeetingController
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MeetingTimecode.string(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 38, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                if let speaker = segment.speaker {
                    HStack(spacing: 4) {
                        SpeakerNameButton(speaker: speaker, meeting: meeting, model: model)
                        if segment.overlapping {
                            Text(model.localized(.meetingOverlapping))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Live labels can be wrong: shown dimmed until the pass after Stop.
                    .opacity(meeting.transcript.speakersAreFinal ? 1 : 0.55)
                } else if meeting.transcript.speakers.isEmpty == false {
                    Text(model.localized(.meetingSpeakerUnknown))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text)
                    .foregroundStyle(isDraft ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A speaker's name; a click opens a field to rename them everywhere.
struct SpeakerNameButton: View {
    let speaker: Int
    @ObservedObject var meeting: MeetingController
    @ObservedObject var model: AppModel
    @State private var isEditing = false
    @State private var draftName = ""

    var body: some View {
        Button {
            draftName = meeting.transcript.speakerNames[speaker] ?? ""
            isEditing = true
        } label: {
            Text(meeting.speakerName(speaker))
                .font(.caption.weight(.semibold))
                .foregroundStyle(MeetingSpeakerColor.color(for: speaker))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.localized(.meetingRenameTitleFormat, meeting.speakerName(speaker)))
                    .font(.callout.weight(.medium))
                TextField(model.localized(.meetingRenamePlaceholder), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button(model.localized(.done), action: save)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func save() {
        meeting.renameSpeaker(speaker, to: draftName)
        isEditing = false
    }
}

/// Shows "copied" on a button for a moment.
@MainActor
func flashCopied(_ flag: Binding<Bool>) {
    flag.wrappedValue = true
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        flag.wrappedValue = false
    }
}

/// A steady color per speaker number, so a speaker is recognizable at a glance.
enum MeetingSpeakerColor {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red]

    static func color(for speaker: Int) -> Color {
        palette[(max(speaker, 1) - 1) % palette.count]
    }
}

/// The meeting window. It follows the user to whichever desktop is in front.
@MainActor
final class MeetingWindowController: NSWindowController, NSWindowDelegate {
    private let meeting: MeetingController

    init(meeting: MeetingController, model: AppModel, copyText: @escaping (String) -> Void) {
        self.meeting = meeting
        let hosting = NSHostingController(
            rootView: MeetingWindowView(meeting: meeting, model: model, copyText: copyText)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = model.localized(.meetingWindowTitle)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 560))
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the window during the consent note cancels it. A running meeting goes
    /// on: the menu-bar icon shows it, and the window comes back from the popover.
    func windowWillClose(_ notification: Notification) {
        meeting.cancelConsent()
    }
}
