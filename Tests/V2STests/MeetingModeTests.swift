import AVFoundation
import XCTest
@testable import v2s

// MARK: - Fakes

private final class FakeMeetingSource: MeetingAudioSource {
    var started = false
    var stopped = false
    var failsToStart = false
    var onAudio: ((AVAudioPCMBuffer) -> Void)?

    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if failsToStart { throw MicrophoneMeetingAudioSource.CaptureError.noMicrophone }
        started = true
        self.onAudio = onAudio
    }

    func stop() {
        stopped = true
        onAudio = nil
    }
}

private final class FakeMeetingRecognizer: MeetingSpeechRecognizer {
    var onUpdate: (@MainActor (MeetingRecognitionUpdate) -> Void)?
    var appendedFrames: AVAudioFrameCount = 0
    var finished = false
    /// Delivered when finish() is called, like the last words of a real recognizer.
    var finalWords: MeetingRecognitionUpdate?

    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {
        self.onUpdate = onUpdate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        appendedFrames += buffer.frameLength
    }

    func finish() async {
        if let finalWords { await onUpdate?(finalWords) }
        finished = true
    }
}

@MainActor
final class MeetingModeTests: XCTestCase {
    private var settings = MeetingSettings.default
    private var source = FakeMeetingSource()
    private var recognizer = FakeMeetingRecognizer()
    private var microphoneAllowed = true
    private var subtitlesRunning = false
    private var subtitlesStopped = false
    private var recognizerLanguages: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        settings = .default
        source = FakeMeetingSource()
        recognizer = FakeMeetingRecognizer()
        microphoneAllowed = true
        subtitlesRunning = false
        subtitlesStopped = false
        recognizerLanguages = []
    }

    private func makeController() -> MeetingController {
        MeetingController(environment: MeetingController.Environment(
            settings: { [unowned self] in self.settings },
            interfaceLanguageID: { "en" },
            makeAudioSource: { [unowned self] _ in self.source },
            makeRecognizer: { [unowned self] languageID in
                self.recognizerLanguages.append(languageID)
                return languageID == "xx" ? nil : self.recognizer
            },
            requestMicrophoneAccess: { [unowned self] in self.microphoneAllowed },
            areSubtitlesRunning: { [unowned self] in self.subtitlesRunning },
            stopSubtitles: { [unowned self] in self.subtitlesStopped = true },
            now: { [unowned self] in self.clock }
        ))
    }

    private func silence(seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * MeetingAudioFormat.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: MeetingAudioFormat.format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    // MARK: Consent and start

    func testAMeetingStartsOnlyFromTheConsentNote() async {
        settings.languageID = "de"
        let meeting = makeController()
        var windowRequests = 0
        meeting.onNeedsWindow = { windowRequests += 1 }

        meeting.toggleFromHotkey()
        XCTAssertEqual(meeting.state, .consent, "the shortcut shows the note, it does not start")
        XCTAssertEqual(windowRequests, 1)
        XCTAssertFalse(source.started)

        await meeting.start()
        XCTAssertEqual(meeting.state, .running)
        XCTAssertTrue(meeting.isActive)
        XCTAssertTrue(source.started)
        XCTAssertEqual(recognizerLanguages, ["de"])
    }

    func testCancellingTheNoteStartsNothing() {
        let meeting = makeController()
        meeting.prepareToStart()

        meeting.cancelConsent()

        XCTAssertEqual(meeting.state, .idle)
        XCTAssertFalse(source.started)
    }

    func testAutoDetectWaitsForTheMeetingModels() async {
        let meeting = makeController()
        meeting.prepareToStart()

        await meeting.start()

        XCTAssertEqual(
            meeting.state,
            .failed("Auto-detect needs the meeting models. Download them in Settings > Meeting, or choose the spoken language.")
        )
        XCTAssertFalse(source.started)
    }

    func testALanguageTheMacCannotTranscribeLiveIsRefused() async {
        settings.languageID = "xx"
        let meeting = makeController()
        meeting.prepareToStart()

        await meeting.start()

        XCTAssertEqual(meeting.state, .failed("This Mac cannot transcribe that language live. Choose another spoken language."))
    }

    func testWithoutMicrophoneAccessNothingStarts() async {
        settings.languageID = "en"
        microphoneAllowed = false
        let meeting = makeController()
        meeting.prepareToStart()

        await meeting.start()

        guard case .failed(let message) = meeting.state else { return XCTFail("\(meeting.state)") }
        XCTAssertTrue(message.contains("Privacy & Security > Microphone"))
        XCTAssertFalse(source.started)
    }

    func testAMissingMicrophoneStopsTheRecognizerAgain() async {
        settings.languageID = "en"
        source.failsToStart = true
        let meeting = makeController()
        meeting.prepareToStart()

        await meeting.start()

        XCTAssertEqual(meeting.state, .failed("The microphone could not be started. Check that it is connected."))
        XCTAssertTrue(recognizer.finished)
    }

    func testStartingAMeetingStopsSubtitles() async {
        settings.languageID = "de"
        subtitlesRunning = true
        let meeting = makeController()
        meeting.prepareToStart()

        await meeting.start()

        XCTAssertTrue(subtitlesStopped)
        XCTAssertEqual(meeting.state, .running)
    }

    // MARK: Transcript and stop

    func testMicrophoneAudioReachesTheRecognizerAndTextTheTranscript() async {
        settings.languageID = "de"
        let meeting = makeController()
        meeting.prepareToStart()
        await meeting.start()

        source.onAudio?(silence(seconds: 0.5))
        meeting.apply(.volatile(text: "Guten Mor", start: 0.2, end: 0.9))
        XCTAssertEqual(meeting.transcript.draft?.text, "Guten Mor")
        meeting.apply(.final(text: "Guten Morgen zusammen.", start: 0.2, end: 1.4))

        XCTAssertEqual(recognizer.appendedFrames, 8_000)
        XCTAssertEqual(meeting.transcript.segments.map(\.text), ["Guten Morgen zusammen."])
        XCTAssertNil(meeting.transcript.draft)
    }

    func testStopKeepsTheLastWordsAndTheTranscript() async {
        settings.languageID = "de"
        let meeting = makeController()
        meeting.prepareToStart()
        await meeting.start()
        meeting.apply(.final(text: "Erster Punkt.", start: 0, end: 2))
        meeting.apply(.volatile(text: "Zweiter", start: 3, end: 3.5))
        recognizer.finalWords = .final(text: "Zweiter Punkt.", start: 3, end: 4.2)
        clock = clock.addingTimeInterval(125)

        meeting.toggleFromHotkey()
        await waitUntil { meeting.state == .idle }

        XCTAssertTrue(source.stopped, "the microphone is released")
        XCTAssertTrue(recognizer.finished)
        XCTAssertEqual(meeting.transcript.segments.map(\.text), ["Erster Punkt.", "Zweiter Punkt."])
        XCTAssertNil(meeting.transcript.draft)
        XCTAssertEqual(meeting.elapsed(at: clock.addingTimeInterval(500)), 125, "the clock stops with the meeting")
        XCTAssertEqual(meeting.copyText, "[0:00] Erster Punkt.\n[0:03] Zweiter Punkt.")
    }

    func testQuittingReleasesTheMicrophoneAtOnce() async {
        settings.languageID = "en"
        let meeting = makeController()
        meeting.prepareToStart()
        await meeting.start()

        meeting.stopImmediately()

        XCTAssertTrue(source.stopped)
        XCTAssertFalse(meeting.isActive)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where condition() == false {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }

    // MARK: Transcript model

    func testTranscriptTextNamesSpeakersOnceTheyAreKnown() {
        var transcript = MeetingTranscript()
        transcript.applyFinal(text: "  Hallo.  ", start: 3_725, end: 3_727, speaker: 1)
        transcript.applyFinal(text: "Hi.", start: 3_728, end: 3_729, speaker: 2)
        transcript.applyFinal(text: "   ", start: 3_730, end: 3_731)
        transcript.speakerNames[2] = "Anna"

        XCTAssertEqual(transcript.speakers, [1, 2])
        XCTAssertEqual(
            transcript.plainText { transcript.speakerNames[$0] ?? "Speaker \($0)" },
            "[1:02:05] Speaker 1: Hallo.\n[1:02:08] Anna: Hi."
        )
    }

    func testTimecodesStayShortUnderAnHour() {
        XCTAssertEqual(MeetingTimecode.string(0), "0:00")
        XCTAssertEqual(MeetingTimecode.string(65.9), "1:05")
        XCTAssertEqual(MeetingTimecode.string(3_600), "1:00:00")
    }

    func testAudioIsConvertedToSixteenKilohertzMono() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let converter = MeetingAudioConverter()

        let first = try XCTUnwrap(converter.convert(buffer))
        let second = try XCTUnwrap(converter.convert(buffer))

        XCTAssertEqual(first.format, MeetingAudioFormat.format)
        // The resampler holds back a few milliseconds it delivers with later audio.
        XCTAssertEqual(Int(first.frameLength + second.frameLength), 3_200, accuracy: 256)
    }

    // MARK: Settings, shortcut, icon

    func testMeetingSettingsDefaultToAutoDetectAndControlOptionM() {
        XCTAssertEqual(MeetingSettings.default.languageID, "auto")
        XCTAssertNil(MeetingSettings.default.microphoneID)
        XCTAssertEqual(MeetingSettings.default.hotkey.binding, HotkeyBinding(keyCode: 46, modifiers: [.control, .option]))
        XCTAssertEqual(AppSettings.default.appMode, .subtitles)
    }

    func testAnOlderSettingsFileGetsMeetingDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"inputLanguageID":"de"}"#.utf8))
        XCTAssertEqual(decoded.meeting, .default)
        XCTAssertEqual(decoded.appMode, .subtitles)

        let partial = try JSONDecoder().decode(MeetingSettings.self, from: Data(#"{"languageID":"de"}"#.utf8))
        XCTAssertEqual(partial.languageID, "de")
        XCTAssertEqual(partial.hotkey, .defaultMeeting)
    }

    func testTheMenuBarShowsAMeetingInRedButBillingStillWins() {
        let meeting = StatusItemAppearance.resolve(sessionState: .idle, cloudEngineState: nil, isMeetingActive: true)
        XCTAssertEqual(meeting.tint, .recording)
        XCTAssertEqual(meeting.symbolName, "waveform.circle.fill")

        let billing = StatusItemAppearance.resolve(
            sessionState: .idle,
            cloudEngineState: nil,
            hasOpenCloudConnection: true,
            isMeetingActive: true
        )
        XCTAssertEqual(billing.tint, .billing)
    }

    func testTheConsentNoteExistsInEnglishAndGerman() {
        let meeting = makeController()
        let english = meeting.consentText(in: "en")
        let german = meeting.consentText(in: "de")

        XCTAssertTrue(english.contains("on my Mac"))
        XCTAssertTrue(english.contains("no audio or text is sent anywhere"))
        XCTAssertTrue(german.contains("auf meinem Mac"))
        XCTAssertNotEqual(english, german)
        XCTAssertFalse(english.contains("\u{2014}") || german.contains("\u{2014}"))
    }

    func testTheMeetingTextsExistInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .subtitlesMode, .meetingMode, .meetingStart, .meetingStop, .meetingTranscribing, .meetingFinishing,
            .meetingWindowTitle, .meetingDefaultMicrophone, .meetingShortcut, .meetingAutoNeedsModels,
            .meetingLanguageNotAvailable, .meetingMicrophoneDenied, .meetingMicrophoneUnavailable, .meetingIsRunning,
            .meetingSpeakerFormat, .meetingConsentTitle, .meetingConsentIntro, .meetingCopyTranscript,
            .meetingTranscriptCopied, .meetingListening, .meetingTryAgain, .meetingShowWindow, .meetingNoteLanguage,
            .meetingSection, .meetingModeHint, .cancel,
        ]
        for language in LanguageCatalog.interface {
            for key in keys {
                let text = AppLocalization.string(key, languageID: language.id)
                XCTAssertNotEqual(text, key.rawValue, "\(language.id) \(key)")
                XCTAssertFalse(text.contains("\u{2014}"), "\(language.id) \(key)")
            }
            XCTAssertTrue(AppLocalization.string(.meetingSpeakerFormat, languageID: language.id, 3).contains("3"))
        }
    }
}

/// Subtitles and a meeting never run together.
@MainActor
final class MeetingAndSubtitlesTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("untertitel-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() -> AppModel {
        let safari = InputSource(id: "app:com.apple.Safari", name: "Safari", detail: "com.apple.Safari", category: .application)
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: [safari], microphones: [])
            }),
            cloudConnectionRegistry: CloudConnectionRegistry()
        )
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"
        model.chooseSources([safari.id])
        return model
    }

    func testSubtitlesDoNotStartDuringAMeeting() {
        let model = makeModel()
        model.isMeetingActive = { true }
        var labels: [SessionToggleFeedback] = []
        let subscription = model.toggleFeedback.sink { labels.append($0) }
        defer { subscription.cancel() }

        model.toggleSessionFromHotkey()
        model.toggleSession()

        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertEqual(model.statusMessage, "A meeting is being transcribed. Stop it before starting subtitles.")
        XCTAssertTrue(labels.isEmpty, "no 'Subtitles on' label for a start that did not happen")
    }

    func testTheModeAndMeetingSettingsAreRemembered() {
        let model = makeModel()
        model.appMode = .meeting
        model.meetingLanguageBinding.wrappedValue = "de"
        model.meetingMicrophoneBinding.wrappedValue = "usb-mic"
        model.meetingHotkeyBinding.wrappedValue = nil

        let reloaded = SettingsStore(fileURL: directory.appendingPathComponent("settings.json")).load()

        XCTAssertEqual(reloaded.appMode, .meeting)
        XCTAssertEqual(reloaded.meeting.languageID, "de")
        XCTAssertEqual(reloaded.meeting.microphoneID, "usb-mic")
        XCTAssertNil(reloaded.meeting.hotkey.binding, "a cleared shortcut stays cleared")
    }

    func testTheMeetingLanguageListStartsWithAutoDetect() {
        let model = makeModel()

        XCTAssertEqual(model.meetingLanguageOptions.first?.id, "auto")
        XCTAssertNotNil(model.meetingLanguageNotice(modelsInstalled: false))
        XCTAssertNil(model.meetingLanguageNotice(modelsInstalled: true), "the models detect the language")
        model.meetingLanguageBinding.wrappedValue = "de"
        XCTAssertNil(model.meetingLanguageNotice(modelsInstalled: false))
    }
}
