import AVFoundation
import FluidAudio
import MeetingKit
import XCTest
@testable import v2s

final class SpeakerHintTests: XCTestCase {
    func testTheHintReachesTheSpeakerPass() {
        let auto = FinalMeetingPass.diarizerConfig(hint: .auto)
        XCTAssertNil(auto.clustering.numSpeakers)
        XCTAssertNil(auto.clustering.minSpeakers)
        XCTAssertEqual(auto.clustering.threshold, 0.6, "community-1 default, unchanged")

        XCTAssertEqual(FinalMeetingPass.diarizerConfig(hint: .two).clustering.numSpeakers, 2)
        XCTAssertEqual(FinalMeetingPass.diarizerConfig(hint: .three).clustering.numSpeakers, 3)
        let many = FinalMeetingPass.diarizerConfig(hint: .fourOrMore)
        XCTAssertNil(many.clustering.numSpeakers)
        XCTAssertEqual(many.clustering.minSpeakers, 4)
    }

    func testTranscriptButtonsOpenTheMeetingInMeetingMode() {
        XCTAssertEqual(TranscriptDestination.resolve(appMode: .meeting, isMeetingActive: false), .meeting)
        XCTAssertEqual(TranscriptDestination.resolve(appMode: .subtitles, isMeetingActive: true), .meeting)
        XCTAssertEqual(TranscriptDestination.resolve(appMode: .subtitles, isMeetingActive: false), .subtitles)
    }

    func testOlderSettingsHaveAutoAndNoDiagnosisAudio() throws {
        let decoded = try JSONDecoder().decode(MeetingSettings.self, from: Data(#"{"languageID":"de"}"#.utf8))
        XCTAssertEqual(decoded.speakerHint, .auto)
        XCTAssertFalse(decoded.keepsDiagnosisAudio)
    }
}

final class MeetingDebugStoreTests: XCTestCase {
    func testFilesAreKeptPrivatelyAndGoneAfterADay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("untertitel-diagnosis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingDebugStore(folder: folder)

        store.saveAudio([0, 0.5, -0.5])
        store.saveDiagnostics(["speakersFound": 1])
        XCTAssertTrue(store.hasFiles)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.audioURL.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        store.removeExpired(now: Date().addingTimeInterval(3_600))
        XCTAssertTrue(store.hasFiles, "an hour old: kept")
        store.removeExpired(now: Date().addingTimeInterval(24 * 3_600 + 60))
        XCTAssertFalse(store.hasFiles, "a day old: deleted")
    }
}

private final class Source: MeetingAudioSource {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws { self.onAudio = onAudio }
    func stop() {}
}

private final class Recognizer: MeetingSpeechRecognizer {
    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async {}
}

private final class Tracker: MeetingSpeakerTracking {
    var turns: [SpeakerTurn] = [SpeakerTurn(speaker: "0", start: 0, end: 1)]
    func append(_ samples: [Float]) {}
}

private final class Spool: MeetingAudioSpooling {
    var samples: [Float] = []
    func append(_ samples: [Float]) { self.samples += samples }
    func readAll() throws -> [Float] { samples }
    func delete() {}
}

@MainActor
final class MeetingSpeakerNoticeTests: XCTestCase {
    private var settings = MeetingSettings(hotkey: .defaultMeeting, languageID: "de", microphoneID: nil)
    private var installed = true
    private var trackerLoads = true
    private let source = Source()
    private let spool = Spool()
    private var hints: [SpeakerCountHint] = []
    private var pass: Result<FinalMeetingPass.Result, Error> = .success(FinalMeetingPass.Result(words: [], turns: []))
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("untertitel-notice-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeController() -> MeetingController {
        MeetingController(environment: MeetingController.Environment(
            settings: { [unowned self] in self.settings },
            interfaceLanguageID: { "en" },
            makeAudioSource: { [unowned self] _ in self.source },
            makeRecognizer: { _ in Recognizer() },
            requestMicrophoneAccess: { true },
            areSubtitlesRunning: { false },
            stopSubtitles: {},
            now: Date.init,
            modelsInstalled: { [unowned self] in self.installed },
            makeSpeakerTracker: { [unowned self] in self.trackerLoads ? Tracker() : nil },
            makeAudioSpool: { [unowned self] in self.spool },
            runFinalPass: { [unowned self] _, hint, _ in
                self.hints.append(hint)
                return try self.pass.get()
            },
            debugStore: MeetingDebugStore(folder: folder)
        ))
    }

    private func run(_ meeting: MeetingController, words: Bool = true) async {
        meeting.prepareToStart()
        await meeting.start()
        let buffer = AVAudioPCMBuffer(pcmFormat: MeetingAudioFormat.format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        source.onAudio?(buffer)
        if words { meeting.apply(.final(text: "Hallo.", start: 0, end: 1)) }
    }

    func testMissingModelsAreShownInsteadOfOneSpeaker() async {
        installed = false
        let meeting = makeController()
        await run(meeting)
        XCTAssertEqual(meeting.liveNotice, "No speaker labels: download the meeting models in Settings > Meeting.")
    }

    func testASpeakerModelThatDidNotLoadIsShown() async {
        trackerLoads = false
        let meeting = makeController()
        await run(meeting)
        XCTAssertEqual(meeting.liveNotice, "Speaker detection unavailable: the speaker model did not load.")
    }

    func testTheHintIsPassedAndOneSpeakerFoundIsExplained() async {
        settings.speakerHint = .two
        let meeting = makeController()
        await run(meeting)
        pass = .success(FinalMeetingPass.Result(
            words: [TimedWord(text: "Hallo.", start: 0, end: 1)],
            turns: [SpeakerTurn(speaker: "S1", start: 0, end: 1)]
        ))
        await meeting.stop()
        XCTAssertEqual(hints, [.two])
        XCTAssertNil(meeting.liveNotice, "a hint was given: no advice to give one")

        settings.speakerHint = .auto
        let second = makeController()
        await run(second)
        await second.stop()
        XCTAssertEqual(second.liveNotice, "Only one speaker was found. If more people spoke, set the number of speakers before the next meeting.")
    }

    func testAFailedPassIsShown() async {
        let meeting = makeController()
        await run(meeting)
        pass = .failure(CocoaError(.fileReadCorruptFile))
        await meeting.stop()
        XCTAssertTrue(meeting.liveNotice?.hasPrefix("Improving the transcript failed (") == true)
        XCTAssertTrue(meeting.liveNotice?.hasSuffix("The live transcript is kept.") == true)
    }

    func testDiagnosisKeepsTheAudioAndFiguresEvenWithoutAPass() async throws {
        settings.keepsDiagnosisAudio = true
        settings.finalPass = .off
        let meeting = makeController()
        await run(meeting)
        await meeting.stop()

        let store = MeetingDebugStore(folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL.path))
        let figures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.diagnosticsURL)) as? [String: Any])
        XCTAssertEqual(figures["liveSpeakersFound"] as? Int, 1)
        XCTAssertTrue(hints.isEmpty, "no pass after Stop was chosen")
    }

    func testTheConsentNoteSaysTheAudioIsKeptForADay() {
        let meeting = makeController()
        XCTAssertTrue(meeting.consentText(in: "en").contains("the audio is deleted when the meeting ends"))

        settings.keepsDiagnosisAudio = true
        let english = meeting.consentText(in: "en")
        XCTAssertTrue(english.contains("stays on my Mac for a day"))
        XCTAssertFalse(english.contains("deleted when the meeting ends"))
        XCTAssertTrue(meeting.consentText(in: "de").contains("einen Tag auf meinem Mac"))
    }

    func testTheNewTextsExistInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .meetingSpeakersUnavailable, .meetingSpeakersNeedModels, .meetingFinalPassFailedFormat, .meetingOneSpeakerFound,
            .meetingSpeakerCount, .meetingSpeakerCountAuto, .meetingSpeakerCountHint, .meetingKeepDebugAudio,
            .meetingKeepDebugAudioExplanation, .meetingDebugAudioDeleteNow, .meetingNoMeetingYet,
        ]
        for language in LanguageCatalog.interface {
            for key in keys {
                let text = AppLocalization.string(key, languageID: language.id)
                XCTAssertNotEqual(text, key.rawValue, "\(language.id) \(key)")
                XCTAssertFalse(text.contains("\u{2014}"), "\(language.id) \(key)")
            }
        }
    }
}

final class OverlapAlignmentTests: XCTestCase {
    private func words(_ spec: [(String, Double, Double)]) -> [TimedWord] {
        spec.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    /// B talks from 39 s to 48 s; A cuts in from 41.3 s to 43.1 s.
    private let turns = [
        SpeakerTurn(speaker: "A", start: 35.1, end: 39.1),
        SpeakerTurn(speaker: "B", start: 39.1, end: 48.1),
        SpeakerTurn(speaker: "A", start: 41.3, end: 43.1),
    ]

    func testAnInterruptionGoesToWhoeverStartedItAndIsMarked() {
        let segments = MeetingAlignment.segments(
            words: words([
                ("the", 39.4, 40.2), ("quarterly", 40.3, 41.2),
                ("sorry", 41.4, 41.6), ("one", 41.6, 41.7), ("quick", 41.7, 41.8), ("question", 41.8, 42.1),
                ("numbers", 43.4, 43.6), ("look", 43.6, 43.9), ("fine", 43.9, 44.4),
            ]),
            turns: turns
        )

        XCTAssertEqual(segments.map(\.text), ["the quarterly", "sorry one quick question", "numbers look fine"])
        XCTAssertEqual(segments.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(segments.map(\.overlapping), [false, true, false])
    }

    func testAWordWithOneTurnHasNoOverlap() {
        let assignment = MeetingAlignment.wordSpeaker(TimedWord(text: "Okay", start: 36, end: 36.4), in: turns)
        XCTAssertEqual(assignment.speaker, "A")
        XCTAssertFalse(assignment.overlapping)
        XCTAssertEqual(MeetingAlignment.wordSpeaker(TimedWord(text: "x", start: 60, end: 60.2), in: turns).speaker, nil)
    }

    func testOverlapsAreKeptByThePassAfterStop() {
        XCTAssertFalse(FinalMeetingPass.diarizerConfig(hint: .two).postProcessing.exclusiveSegments)
        XCTAssertTrue(FinalMeetingPass.diarizerConfig(hint: .two, keepsOverlaps: false).postProcessing.exclusiveSegments)
    }

    func testOverlapsShowInCopiedTextAndMarkdown() {
        var transcript = MeetingTranscript()
        transcript.replaceSegments([
            MeetingSegment(start: 39, end: 41, text: "the quarterly", speaker: 1),
            MeetingSegment(start: 41.4, end: 42.1, text: "sorry one quick question", speaker: 2, overlapping: true),
        ], speakerNames: [:])

        XCTAssertTrue(transcript.speakersAreFinal)
        XCTAssertEqual(
            transcript.plainText(speakerName: { "Speaker \($0)" }),
            "[0:39] Speaker 1: the quarterly\n[0:41] Speaker 2 (overlapping): sorry one quick question"
        )
        let markdown = MeetingMarkdown.document(transcript: transcript, startedAt: Date(), duration: 60, speakerName: { "Speaker \($0)" })
        XCTAssertTrue(markdown.contains("**Speaker 2** (overlapping) [0:41]"))
    }

    func testLiveSpeakersStayProvisionalUntilThePassAfterStop() {
        var transcript = MeetingTranscript()
        transcript.applyFinal(text: "Hallo.", start: 0, end: 1, speaker: 1)
        XCTAssertFalse(transcript.speakersAreFinal)
    }

    func testTheNewTextsExistInEveryInterfaceLanguage() {
        for language in LanguageCatalog.interface {
            for key in [AppTextKey.meetingOverlapping, .meetingSpeakersProvisional, .meetingSpeakerUnknown] {
                XCTAssertNotEqual(AppLocalization.string(key, languageID: language.id), key.rawValue, "\(language.id) \(key)")
            }
        }
    }
}

@MainActor
final class ProvisionalSpeakerNoteTests: XCTestCase {
    private final class Source: MeetingAudioSource {
        func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {}
        func stop() {}
    }
    private final class Recognizer: MeetingSpeechRecognizer {
        func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {}
        func append(_ buffer: AVAudioPCMBuffer) {}
        func finish() async {}
    }
    private final class Tracker: MeetingSpeakerTracking {
        var turns = [SpeakerTurn(speaker: "0", start: 0, end: 5)]
        func append(_ samples: [Float]) {}
    }
    private final class Spool: MeetingAudioSpooling {
        func append(_ samples: [Float]) {}
        func readAll() throws -> [Float] { [0.1, 0.2] }
        func delete() {}
    }

    func testTheNoteShowsWhileLiveLabelsAreUpAndGoesWhenTheyAreFinal() async {
        let meeting = MeetingController(environment: MeetingController.Environment(
            settings: { MeetingSettings(hotkey: .defaultMeeting, languageID: "de", microphoneID: nil) },
            interfaceLanguageID: { "en" },
            makeAudioSource: { _ in Source() },
            makeRecognizer: { _ in Recognizer() },
            requestMicrophoneAccess: { true },
            areSubtitlesRunning: { false },
            stopSubtitles: {},
            now: Date.init,
            modelsInstalled: { true },
            makeSpeakerTracker: { Tracker() },
            makeAudioSpool: { Spool() },
            runFinalPass: { _, _, _ in
                FinalMeetingPass.Result(
                    words: [TimedWord(text: "Hallo.", start: 0, end: 1)],
                    turns: [SpeakerTurn(speaker: "S1", start: 0, end: 1)]
                )
            }
        ))
        meeting.prepareToStart()
        await meeting.start()
        meeting.apply(.final(text: "Hallo.", start: 0, end: 1))
        XCTAssertTrue(meeting.showsProvisionalSpeakersNote)

        await meeting.stop()
        XCTAssertFalse(meeting.showsProvisionalSpeakersNote)
        XCTAssertTrue(meeting.transcript.speakersAreFinal)
    }
}
