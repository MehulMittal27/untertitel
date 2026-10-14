import AVFoundation
import Combine
import Foundation
import MeetingKit
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
        /// The microphone is off; the whole meeting is transcribed again and its
        /// speakers told apart, on this Mac. 0...1.
        case improving(Double)
        case failed(String)

        /// True from Start until the last words are in: the microphone is in use.
        var isActive: Bool {
            switch self {
            case .starting, .running, .finishing: return true
            case .idle, .consent, .improving, .failed: return false
            }
        }

        /// True until the meeting's transcript is complete: no new meeting starts.
        var isBusy: Bool {
            if case .improving = self { return true }
            return isActive
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
        /// Whether the FluidAudio meeting models are on this Mac. Without them a
        /// meeting has Apple's live text only: no speakers and no pass after Stop.
        var modelsInstalled: @MainActor () -> Bool = { false }
        var makeSpeakerTracker: @MainActor () async -> MeetingSpeakerTracking? = { nil }
        var makeAudioSpool: @MainActor () -> MeetingAudioSpooling? = { nil }
        var runFinalPass: @MainActor (_ samples: [Float], _ hint: SpeakerCountHint, _ progress: @escaping @Sendable (Double) -> Void) async throws
            -> FinalMeetingPass.Result = { _, _, _ in FinalMeetingPass.Result(words: [], turns: []) }
        /// Where the last meeting's audio goes when the user keeps it for diagnosis.
        var debugStore: MeetingDebugStore = MeetingDebugStore()
        /// Where saved transcripts go, when saving is on.
        var transcriptStore: MeetingTranscriptStore = MeetingTranscriptStore()
        /// The Soniox key from the Keychain, or nil.
        var sonioxAPIKey: @MainActor () -> String? = { nil }
        /// Whether a cloud pause ends by itself when speech returns (the user's setting).
        var cloudResumesAutomatically: @MainActor () -> Bool = { false }
        var makeSonioxRecognizer: @MainActor (_ apiKey: String, _ languageCode: String?, _ resumesAutomatically: Bool,
            _ callbacks: SonioxMeetingRecognizer.Callbacks) -> MeetingSpeechRecognizer = { key, code, resumes, callbacks in
            SonioxMeetingRecognizer(apiKey: key, languageCode: code, resumesAutomatically: resumes, callbacks: callbacks)
        }
        var runSonioxFilePass: @MainActor (_ apiKey: String, _ languageCode: String?, _ samples: [Float],
            _ progress: @escaping @Sendable (Double) -> Void) async throws -> FinalMeetingPass.Result = { key, code, samples, progress in
            try await SonioxFilePass(apiKey: key, languageCode: code).run(samples: samples, progress: progress)
        }
        /// Seconds sent to Soniox: live, or as a file after Stop. For the cost record.
        var recordSonioxUsage: @MainActor (_ seconds: TimeInterval, _ isFile: Bool) -> Void = { _, _ in }
    }

    /// What became of saving the last meeting.
    enum SaveOutcome: Equatable {
        case saved(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = MeetingTranscript()
    @Published private(set) var startedAt: Date?
    @Published private(set) var stoppedAt: Date?
    /// Nil while nothing has been saved for this meeting, or saving is off.
    @Published private(set) var saveOutcome: SaveOutcome?
    /// The Soniox connection's state while a meeting is transcribed by Soniox.
    @Published private(set) var cloudState: CloudEngineState?
    /// Seconds of this meeting sent to Soniox, live and as a file.
    @Published private(set) var cloudSeconds: TimeInterval = 0
    @Published private(set) var fileSeconds: TimeInterval = 0
    /// Something the live transcription wants the user to know, such as Soniox failing.
    @Published private(set) var liveNotice: String?

    /// Asks for the meeting window to come to the front, for the consent note.
    var onNeedsWindow: (() -> Void)?

    private let environment: Environment
    private var audioSource: MeetingAudioSource?
    private var recognizer: MeetingSpeechRecognizer?
    private var speakerTracker: MeetingSpeakerTracking?
    private var audioSpool: MeetingAudioSpooling?
    /// Live speaker identities, numbered from 1 in order of first appearance.
    private var liveSpeakerNumbers: [String: Int] = [:]
    /// The live speaker model's turns at Stop, for the diagnosis file.
    private var lastLiveTurns: [SpeakerTurn] = []

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
        case .starting, .running, .finishing, .improving:
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
        } else if state.isBusy == false {
            prepareToStart()
        } else {
            onNeedsWindow?()
        }
    }

    /// The note's Start button.
    func start() async {
        guard state == .consent || state == .idle || isFailed else {
            return
        }

        let settings = environment.settings()
        let modelsInstalled = environment.modelsInstalled()
        let sonioxKey = environment.sonioxAPIKey()
        let usesSonioxLive = settings.liveEngine == .soniox
        let recognizer: MeetingSpeechRecognizer
        if usesSonioxLive {
            guard let sonioxKey else {
                state = .failed(localized(.meetingSonioxNeedsKey))
                return
            }
            recognizer = environment.makeSonioxRecognizer(
                sonioxKey,
                sonioxLanguageCode(settings.languageID),
                environment.cloudResumesAutomatically(),
                sonioxCallbacks()
            )
        } else {
            guard LanguageCatalog.isAutoDetect(settings.languageID) == false || modelsInstalled else {
                state = .failed(localized(.meetingAutoNeedsModels))
                return
            }
            guard let made = environment.makeRecognizer(settings.languageID) else {
                state = .failed(localized(.meetingLanguageNotAvailable))
                return
            }
            recognizer = made
        }
        if settings.finalPass == .sonioxFile, sonioxKey == nil {
            state = .failed(localized(.meetingSonioxNeedsKey))
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

        // Speakers live: Soniox labels them itself, otherwise the local model does.
        let tracker = modelsInstalled && usesSonioxLive == false ? await environment.makeSpeakerTracker() : nil
        // The audio is kept only when a pass after Stop will use it, or for diagnosis.
        let keepsAudio = (settings.finalPass == .onDevice && modelsInstalled) || settings.finalPass == .sonioxFile
            || settings.keepsDiagnosisAudio
        let spool = keepsAudio ? environment.makeAudioSpool() : nil
        // Speaker detection that is not there must not look like one speaker.
        var speakerNotice: String?
        if usesSonioxLive == false {
            if modelsInstalled == false {
                speakerNotice = localized(.meetingSpeakersNeedModels)
            } else if tracker == nil {
                speakerNotice = localized(.meetingSpeakersUnavailable)
            }
        }
        Logger.meeting.log(
            "Meeting setup: live=\(settings.liveEngine.rawValue, privacy: .public) language=\(settings.languageID, privacy: .public) models=\(modelsInstalled) liveSpeakers=\(tracker != nil || usesSonioxLive) audioKept=\(spool != nil) afterStop=\(settings.finalPass.rawValue, privacy: .public) speakerHint=\(settings.speakerHint.rawValue, privacy: .public) diagnosis=\(settings.keepsDiagnosisAudio)"
        )

        let source = environment.makeAudioSource(settings.microphoneID)
        do {
            try source.start { [recognizer, tracker, spool] buffer in
                recognizer.append(buffer)
                if tracker != nil || spool != nil {
                    let samples = buffer.monoSamples
                    tracker?.append(samples)
                    spool?.append(samples)
                }
            }
        } catch {
            Logger.meeting.error("Meeting microphone did not start: \(String(describing: error), privacy: .public)")
            await recognizer.finish()
            spool?.delete()
            state = .failed(localized(.meetingMicrophoneUnavailable))
            return
        }

        transcript = MeetingTranscript()
        saveOutcome = nil
        cloudState = nil
        cloudSeconds = 0
        fileSeconds = 0
        liveNotice = speakerNotice
        liveSpeakerNumbers = [:]
        self.recognizer = recognizer
        speakerTracker = tracker
        audioSpool = spool
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
        stoppedAt = environment.now()
        await recognizer?.finish()
        recognizer = nil
        transcript.clearDraft()
        labelSpeakers(since: 0)
        let liveSpeakers = speakerTracker?.speakerCount
        lastLiveTurns = speakerTracker?.turns ?? []
        speakerTracker = nil
        Logger.meeting.log(
            "Meeting transcription stopped: live speakers found=\(liveSpeakers.map(String.init) ?? "none", privacy: .public) segments=\(self.transcript.segments.count) labelled=\(Set(self.transcript.segments.compactMap(\.speaker)).count)"
        )

        cloudState = nil
        if let spool = audioSpool {
            audioSpool = nil
            await improveTranscript(from: spool)
        }
        saveIfWanted()
        state = .idle
    }

    // MARK: Saving

    /// Writes the transcript when saving is on. A meeting with no words is not saved.
    private func saveIfWanted() {
        guard environment.settings().savesTranscripts,
              transcript.segments.isEmpty == false,
              let startedAt else {
            return
        }

        let markdown = MeetingMarkdown.document(
            transcript: transcript,
            startedAt: startedAt,
            duration: elapsed(at: environment.now()),
            speakerName: speakerName
        )
        do {
            let url = try environment.transcriptStore.save(markdown, fileName: MeetingMarkdown.fileName(startedAt: startedAt))
            saveOutcome = .saved(url)
        } catch MeetingTranscriptStore.StoreError.folderIsSynced {
            saveOutcome = .failed(localized(.meetingSaveFailedSynced))
        } catch {
            Logger.meeting.error("Meeting transcript not saved: \(error.localizedDescription, privacy: .public)")
            saveOutcome = .failed(localized(.meetingSaveFailedFormat, error.localizedDescription))
        }
    }

    /// Deletes the saved file for good and clears the transcript from the window.
    func deleteSavedTranscript() {
        if case .saved(let url) = saveOutcome {
            try? environment.transcriptStore.delete(url)
        }
        saveOutcome = nil
        transcript = MeetingTranscript()
    }

    /// Whether starting a new meeting would clear words that were not saved.
    var hasUnsavedTranscript: Bool {
        guard transcript.segments.isEmpty == false else { return false }
        if case .saved = saveOutcome { return false }
        return true
    }

    /// Transcribes the whole meeting again and tells its speakers apart, then puts
    /// the result in place of the live transcript, keeping the names given. The
    /// audio is deleted as soon as it is read.
    private func improveTranscript(from spool: MeetingAudioSpooling) async {
        state = .improving(0)
        let samples: [Float]
        do {
            samples = try spool.readAll()
        } catch {
            Logger.meeting.error("Meeting audio could not be read: \(String(describing: error), privacy: .public)")
            spool.delete()
            return
        }
        spool.delete()
        guard samples.isEmpty == false else { return }

        let settings = environment.settings()
        var diagnosis: [String: Any] = [
            "liveSpeakerTurns": lastLiveTurns.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end] },
            "liveSpeakersFound": Set(lastLiveTurns.map(\.speaker)).count,
            "liveEngine": settings.liveEngine.rawValue,
            "afterStop": settings.finalPass.rawValue,
        ]
        if settings.keepsDiagnosisAudio {
            environment.debugStore.saveAudio(samples)
            environment.debugStore.saveDiagnostics(diagnosis)
        }
        let modelsInstalled = environment.modelsInstalled()
        let runsLocalPass = settings.finalPass == .onDevice && modelsInstalled
        let runsSonioxPass = settings.finalPass == .sonioxFile && environment.sonioxAPIKey() != nil
        guard runsLocalPass || runsSonioxPass else { return }

        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, case .improving = self.state else { return }
                self.state = .improving(fraction)
            }
        }
        do {
            let result: FinalMeetingPass.Result
            if runsSonioxPass, let key = environment.sonioxAPIKey() {
                let seconds = Double(samples.count) / MeetingAudioFormat.sampleRate
                result = try await environment.runSonioxFilePass(key, sonioxLanguageCode(settings.languageID), samples, progress)
                fileSeconds = seconds
                environment.recordSonioxUsage(seconds, true)
            } else {
                result = try await environment.runFinalPass(samples, settings.speakerHint, progress)
            }
            diagnosis["afterStopSpeakerTurns"] = result.turns.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end] }
            diagnosis["afterStopSpeakersFound"] = result.speakerCount
            diagnosis["afterStop"] = result.diagnostics
            if settings.keepsDiagnosisAudio {
                environment.debugStore.saveDiagnostics(diagnosis)
            }
            Logger.meeting.log("Pass after Stop found \(result.speakerCount) speakers in \(result.turns.count) turns")
            let segments = MeetingAlignment.segments(words: result.words, turns: result.turns)
            guard segments.isEmpty == false else { return }
            let names = MeetingAlignment.carryNames(
                names: transcript.speakerNames,
                live: transcript.segments,
                final: segments
            )
            transcript.replaceSegments(segments, speakerNames: names)
            Logger.meeting.log("Meeting transcript improved: \(segments.count) segments")
            if result.speakerCount <= 1, settings.speakerHint == .auto, settings.finalPass == .onDevice {
                liveNotice = localized(.meetingOneSpeakerFound)
            } else {
                liveNotice = nil
            }
        } catch {
            Logger.meeting.error("Pass after Stop failed, keeping the live transcript: \(String(describing: error), privacy: .public)")
            liveNotice = localized(.meetingFinalPassFailedFormat, error.localizedDescription)
        }
    }

    /// Stops the microphone on the spot, without waiting for the last words: the app
    /// is quitting.
    func stopImmediately() {
        audioSource?.stop()
        audioSource = nil
        recognizer = nil
        speakerTracker = nil
        audioSpool?.delete()
        audioSpool = nil
        if state.isBusy {
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
        case .volatile(let text, let start, let end, let identity):
            let speaker = identity.map(speakerNumber(for:)) ?? liveSpeaker(from: start, to: end)
            transcript.applyVolatile(text: text, start: start, end: end, speaker: speaker)
        case .final(let text, let start, let end, let identity):
            let speaker = identity.map(speakerNumber(for:)) ?? liveSpeaker(from: start, to: end)
            transcript.applyFinal(text: text, start: start, end: end, speaker: speaker)
            // The speaker model trails the words a little: label the last half
            // minute again with what it knows now.
            labelSpeakers(since: end - 30)
        }
    }

    private func liveSpeaker(from start: TimeInterval, to end: TimeInterval) -> Int? {
        guard let turns = speakerTracker?.turns,
              let identity = MeetingAlignment.speaker(from: start, to: end, in: turns) else {
            return nil
        }
        return speakerNumber(for: identity)
    }

    /// Speakers are numbered from 1 in the order they first speak.
    private func speakerNumber(for identity: String) -> Int {
        if let number = liveSpeakerNumbers[identity] {
            return number
        }
        let number = liveSpeakerNumbers.count + 1
        liveSpeakerNumbers[identity] = number
        return number
    }

    private func labelSpeakers(since time: TimeInterval) {
        guard speakerTracker != nil else { return }
        transcript.relabel { segment in
            segment.end >= time ? self.liveSpeaker(from: segment.start, to: segment.end) : nil
        }
    }

    // MARK: Soniox

    /// Soniox's code for the meeting's language, or nil for Auto-detect.
    private func sonioxLanguageCode(_ languageID: String) -> String? {
        LanguageCatalog.isAutoDetect(languageID) ? nil : LanguageCatalog.sonioxLanguageCode(for: languageID)
    }

    private func sonioxCallbacks() -> SonioxMeetingRecognizer.Callbacks {
        SonioxMeetingRecognizer.Callbacks(
            streamedSeconds: { [weak self] seconds in
                guard let self else { return }
                self.cloudSeconds += seconds
                self.environment.recordSonioxUsage(seconds, false)
            },
            stateChanged: { [weak self] state in
                self?.cloudState = state
            },
            failed: { [weak self] failure in
                guard let self else { return }
                self.cloudState = nil
                self.liveNotice = self.localized(.meetingSonioxStoppedFormat, Self.describe(failure))
            }
        )
    }

    private static func describe(_ failure: CloudEngineFailure) -> String {
        switch failure {
        case .authenticationFailed: return "API key"
        case .connectionFailed: return "connection"
        case .rejected(let message): return message
        default: return String(describing: failure)
        }
    }

    /// Takes a Soniox meeting out of its pause after three minutes without speech.
    func resumeCloud() {
        recognizer?.resume()
    }

    /// What this meeting has cost at Soniox so far.
    var cloudCostText: String? {
        guard cloudSeconds > 0 || fileSeconds > 0 else { return nil }
        let dollars = cloudSeconds / 60 * RecognitionEngine.sonioxUSDPerMinute
            + fileSeconds / 3600 * RecognitionEngine.sonioxFileUSDPerHour
        let minutes = Int(((cloudSeconds + fileSeconds) / 60).rounded(.up))
        return localized(.meetingCloudCostFormat, "\(minutes) min", String(format: "$%.2f", dollars))
    }

    /// Names a speaker everywhere in the transcript. An empty name goes back to
    /// "Speaker n".
    func renameSpeaker(_ speaker: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.speakerNames[speaker] = trimmed.isEmpty ? nil : trimmed
        // A saved transcript follows the new name.
        if case .saved = saveOutcome, isActive == false {
            saveIfWanted()
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

#if DEBUG
    func setTranscriptForTesting(_ transcript: MeetingTranscript) { self.transcript = transcript }
    func setStateForTesting(_ state: State) { self.state = state }
#endif

    // MARK: Consent note

    /// The note to read out or paste into the chat before starting, in `languageID`.
    func consentText(in languageID: String) -> String {
        let settings = environment.settings()
        let sendsLive = settings.liveEngine == .soniox
        let sendsFile = settings.finalPass == .sonioxFile
        var keys: [AppTextKey] = [.meetingConsentOpening]
        if sendsLive || sendsFile {
            keys.append(sendsLive ? .meetingConsentSonioxLive : .meetingConsentLocalLive)
            if sendsFile { keys.append(.meetingConsentSonioxFile) }
            if settings.keepsDiagnosisAudio { keys.append(.meetingConsentKeepsAudio) }
        } else {
            keys.append(settings.keepsDiagnosisAudio ? .meetingConsentLocalAllKeepsAudio : .meetingConsentLocalAll)
        }
        var sentences = keys.map { AppLocalization.string($0, languageID: languageID) }
        if settings.savesTranscripts {
            sentences.append(AppLocalization.string(.meetingConsentKeepsTranscript, languageID: languageID))
        }
        sentences.append(AppLocalization.string(.meetingConsentObjection, languageID: languageID))
        return sentences.joined(separator: " ")
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
                // Auto-detect: FluidAudio's live model, which finds the language itself.
                if LanguageCatalog.isAutoDetect(languageID) {
                    return MeetingModels.isInstalled ? FluidLiveRecognizer() : nil
                }
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
            now: Date.init,
            modelsInstalled: { MeetingModels.isInstalled },
            makeSpeakerTracker: { await FluidSpeakerTracker.load() },
            makeAudioSpool: {
                do {
                    return try MeetingAudioSpool()
                } catch {
                    Logger.meeting.error("Meeting audio cannot be kept: \(String(describing: error), privacy: .public)")
                    return nil
                }
            },
            runFinalPass: { samples, hint, progress in
                try await FinalMeetingPass.run(samples: samples, speakerHint: hint, progress: progress)
            },
            sonioxAPIKey: { [weak model] in model?.sonioxAPIKey },
            cloudResumesAutomatically: { [weak model] in model?.cloudResumesAutomatically ?? false },
            recordSonioxUsage: { [weak model] seconds, isFile in
                model?.recordMeetingSonioxUsage(seconds: seconds, isFile: isFile)
            }
        )
    }
}
