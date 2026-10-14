import AVFoundation
import Combine
import Foundation
import os.log
import Speech

private extension Logger {
    static let meeting = Logger(subsystem: "com.franklioxygen.v2s", category: "meeting")
}

/// Runs meeting transcription: the consent note, the microphone, the recognizer and
/// the transcript. Separate from call subtitles; only one of the two runs at a time.
@MainActor
final class MeetingController: ObservableObject {
    enum State: Equatable {
        case idle
        /// The consent note is showing. Its Start button starts the meeting.
        case consent
        case starting
        case running
        /// Stop was pressed; the last words are being recognized.
        case finishing
        case failed(String)

        /// True from Start until the last words are in: the microphone is in use.
        var isActive: Bool {
            switch self {
            case .starting, .running, .finishing: return true
            case .idle, .consent, .failed: return false
            }
        }
    }

    /// What starting a meeting needs from the rest of the app.
    struct Environment {
        var settings: @MainActor () -> MeetingSettings
        var interfaceLanguageID: @MainActor () -> String
        var makeAudioSource: @MainActor (_ microphoneID: String?) -> MeetingAudioSource
        /// Nil when the language cannot be recognized live on this Mac.
        var makeRecognizer: @MainActor (_ languageID: String) -> MeetingSpeechRecognizer?
        var requestMicrophoneAccess: @MainActor () async -> Bool
        /// Whether call subtitles are running, and a way to stop them.
        var areSubtitlesRunning: @MainActor () -> Bool
        var stopSubtitles: @MainActor () -> Void
        var now: @MainActor () -> Date
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = MeetingTranscript()
    @Published private(set) var startedAt: Date?
    @Published private(set) var stoppedAt: Date?

    /// Asks for the meeting window to come to the front, for the consent note.
    var onNeedsWindow: (() -> Void)?

    private let environment: Environment
    private var audioSource: MeetingAudioSource?
    private var recognizer: MeetingSpeechRecognizer?

    init(environment: Environment) {
        self.environment = environment
    }

    /// True from Start until the last words are in: the microphone is in use.
    var isActive: Bool {
        state.isActive
    }

    private func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: environment.interfaceLanguageID(), arguments: arguments)
    }

    // MARK: Starting and stopping

    /// Shows the consent note. A meeting only starts from its Start button.
    func prepareToStart() {
        switch state {
        case .idle, .failed, .consent:
            state = .consent
            onNeedsWindow?()
        case .starting, .running, .finishing:
            onNeedsWindow?()
        }
    }

    func cancelConsent() {
        guard state == .consent else { return }
        state = .idle
    }

    /// The shortcut: shows the consent note, or stops a meeting that is running.
    func toggleFromHotkey() {
        if isActive {
            Task { await stop() }
        } else {
            prepareToStart()
        }
    }

    /// The note's Start button.
    func start() async {
        guard state == .consent || state == .idle || isFailed else {
            return
        }

        let settings = environment.settings()
        guard LanguageCatalog.isAutoDetect(settings.languageID) == false else {
            state = .failed(localized(.meetingAutoNeedsModels))
            return
        }
        guard let recognizer = environment.makeRecognizer(settings.languageID) else {
            state = .failed(localized(.meetingLanguageNotAvailable))
            return
        }

        state = .starting
        if environment.areSubtitlesRunning() {
            environment.stopSubtitles()
        }

        guard await environment.requestMicrophoneAccess() else {
            state = .failed(localized(.meetingMicrophoneDenied))
            return
        }

        do {
            try await recognizer.start { [weak self] update in
                self?.apply(update)
            }
        } catch {
            Logger.meeting.error("Meeting recognizer did not start: \(String(describing: error), privacy: .public)")
            state = .failed(localized(.meetingLanguageNotAvailable))
            return
        }

        let source = environment.makeAudioSource(settings.microphoneID)
        do {
            try source.start { [recognizer] buffer in
                recognizer.append(buffer)
            }
        } catch {
            Logger.meeting.error("Meeting microphone did not start: \(String(describing: error), privacy: .public)")
            await recognizer.finish()
            state = .failed(localized(.meetingMicrophoneUnavailable))
            return
        }

        transcript = MeetingTranscript()
        self.recognizer = recognizer
        audioSource = source
        startedAt = environment.now()
        stoppedAt = nil
        state = .running
        Logger.meeting.log("Meeting transcription started")
    }

    /// Stops listening at once; the words already heard are still recognized.
    func stop() async {
        guard state == .running || state == .starting else {
            return
        }

        state = .finishing
        audioSource?.stop()
        audioSource = nil
        await recognizer?.finish()
        recognizer = nil
        transcript.clearDraft()
        stoppedAt = environment.now()
        state = .idle
        Logger.meeting.log("Meeting transcription stopped")
    }

    /// Stops the microphone on the spot, without waiting for the last words: the app
    /// is quitting.
    func stopImmediately() {
        audioSource?.stop()
        audioSource = nil
        recognizer = nil
        if isActive {
            state = .idle
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: Transcript

    func apply(_ update: MeetingRecognitionUpdate) {
        switch update {
        case .volatile(let text, let start, let end):
            transcript.applyVolatile(text: text, start: start, end: end)
        case .final(let text, let start, let end):
            transcript.applyFinal(text: text, start: start, end: end)
        }
    }

    /// How long the meeting has run, for the window's clock.
    func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (stoppedAt ?? date).timeIntervalSince(startedAt)
    }

    func speakerName(_ speaker: Int) -> String {
        transcript.speakerNames[speaker] ?? localized(.meetingSpeakerFormat, speaker)
    }

    var copyText: String {
        transcript.plainText(speakerName: speakerName)
    }

    // MARK: Consent note

    /// The note to read out or paste into the chat before starting, in `languageID`.
    func consentText(in languageID: String) -> String {
        AppLocalization.string(.meetingConsentOnDevice, languageID: languageID)
    }
}

extension MeetingController.Environment {
    /// The real microphone and Apple's recognizer.
    @MainActor
    static func live(model: AppModel) -> MeetingController.Environment {
        MeetingController.Environment(
            settings: { [weak model] in model?.meetingSettings ?? .default },
            interfaceLanguageID: { [weak model] in model?.resolvedInterfaceLanguageID ?? "en" },
            makeAudioSource: { MicrophoneMeetingAudioSource(deviceID: $0) },
            makeRecognizer: { [weak model] languageID in
                guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
                    return nil
                }
                let locale = model?.speechLocale(forMeetingLanguage: languageID)
                    ?? LanguageCatalog.speechLocaleIdentifier(for: languageID)
                return AppleMeetingRecognizer(locale: Locale(identifier: locale))
            },
            requestMicrophoneAccess: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return true
                case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
                default: return false
                }
            },
            areSubtitlesRunning: { [weak model] in model?.sessionState == .running },
            stopSubtitles: { [weak model] in model?.stopSession(trigger: .meetingStart) },
            now: Date.init
        )
    }
}
