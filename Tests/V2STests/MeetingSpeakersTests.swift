import AVFoundation
import MeetingKit
import XCTest
@testable import v2s

private func words(_ spec: [(String, Double, Double)]) -> [TimedWord] {
    spec.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
}

final class LiveWordSegmenterTests: XCTestCase {
    func testAFinishedSentenceIsFinalOnceTheNextWordArrives() {
        var segmenter = LiveWordSegmenter()

        let first = segmenter.update(words: words([("Guten", 0, 0.4), ("Morgen.", 0.5, 1.0)]), audioTime: 1.2)
        XCTAssertTrue(first.finals.isEmpty, "the sentence may still change")
        XCTAssertEqual(first.draft?.text, "Guten Morgen.")

        let second = segmenter.update(
            words: words([("Guten", 0, 0.4), ("Morgen.", 0.5, 1.0), ("Wie", 1.3, 1.5)]),
            audioTime: 1.7
        )
        XCTAssertEqual(second.finals.map(\.text), ["Guten Morgen."])
        XCTAssertEqual(second.finals.first?.start, 0)
        XCTAssertEqual(second.finals.first?.end, 1.0)
        XCTAssertEqual(second.draft?.text, "Wie")
    }

    func testASentenceAlsoEndsAfterSilenceOrAPause() {
        var segmenter = LiveWordSegmenter()
        let settled = segmenter.update(words: words([("Okay.", 0, 0.5)]), audioTime: 1.6)
        XCTAssertEqual(settled.finals.map(\.text), ["Okay."])
        XCTAssertNil(settled.draft)

        var paused = LiveWordSegmenter()
        let output = paused.update(words: words([("so", 0, 0.3), ("then", 0.4, 0.6), ("next", 2.0, 2.3)]), audioTime: 2.4)
        XCTAssertEqual(output.finals.map(\.text), ["so then"])
        XCTAssertEqual(output.draft?.text, "next")
    }

    func testFlushCommitsTheRest() {
        var segmenter = LiveWordSegmenter()
        _ = segmenter.update(words: words([("und", 0, 0.2)]), audioTime: 0.3)

        let output = segmenter.update(words: words([("und", 0, 0.2), ("dann", 0.3, 0.5)]), audioTime: 0.6, flush: true)

        XCTAssertEqual(output.finals.map(\.text), ["und dann"])
        XCTAssertNil(output.draft)
    }
}

final class MeetingAlignmentTests: XCTestCase {
    private let turns = [
        SpeakerTurn(speaker: "B", start: 0, end: 4),
        SpeakerTurn(speaker: "A", start: 4.2, end: 9),
        SpeakerTurn(speaker: "B", start: 9.5, end: 12),
    ]

    func testAStretchBelongsToWhoeverTalksMostInIt() {
        XCTAssertEqual(MeetingAlignment.speaker(from: 3, to: 6, in: turns), "A")
        XCTAssertEqual(MeetingAlignment.speaker(from: 1, to: 3, in: turns), "B")
        XCTAssertEqual(MeetingAlignment.speaker(from: 9.35, to: 9.45, in: turns), "B", "nearest turn within a second")
        XCTAssertEqual(MeetingAlignment.speaker(from: 9.1, to: 9.2, in: turns), "A")
        XCTAssertNil(MeetingAlignment.speaker(from: 20, to: 21, in: turns))
    }

    func testWordsAreGroupedBySpeakerAndNumberedInOrderOfAppearance() {
        let segments = MeetingAlignment.segments(
            words: words([
                ("Hallo", 0.5, 0.9), ("zusammen.", 1.0, 1.6),
                ("Hi,", 4.5, 4.8), ("thanks.", 4.9, 5.4),
                ("Gern.", 10, 10.5),
            ]),
            turns: turns
        )

        XCTAssertEqual(segments.map(\.text), ["Hallo zusammen.", "Hi, thanks.", "Gern."])
        XCTAssertEqual(segments.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(segments[1].start, 4.5)
        XCTAssertEqual(segments[1].end, 5.4)
    }

    func testALongPauseStartsANewSegment() {
        let segments = MeetingAlignment.segments(
            words: words([("eins", 0, 0.5), ("zwei", 2.5, 3)]),
            turns: [SpeakerTurn(speaker: "A", start: 0, end: 3)]
        )
        XCTAssertEqual(segments.map(\.text), ["eins", "zwei"])
    }

    func testNamesFollowTheSpeakerWhoSaidTheSameThings() {
        let live = [
            MeetingSegment(start: 0, end: 4, text: "a", speaker: 1),
            MeetingSegment(start: 4, end: 9, text: "b", speaker: 2),
        ]
        let final = [
            MeetingSegment(start: 0, end: 4, text: "a", speaker: 2),
            MeetingSegment(start: 4, end: 9, text: "b", speaker: 1),
        ]

        XCTAssertEqual(
            MeetingAlignment.carryNames(names: [1: "Anna", 2: "Ben"], live: live, final: final),
            [2: "Anna", 1: "Ben"]
        )
        XCTAssertEqual(MeetingAlignment.carryNames(names: [:], live: live, final: final), [:])
    }
}

final class MeetingAudioSpoolTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("untertitel-spool-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheAudioComesBackAndIsNotReadableOnDisk() throws {
        let spool = try MeetingAudioSpool(folder: folder)
        let tone = (0..<50_000).map { Float(sin(Double($0) / 10)) * 0.5 }
        spool.append(Array(tone[..<20_000]))
        spool.append(Array(tone[20_000...]))

        let back = try spool.readAll()

        XCTAssertEqual(back.count, tone.count)
        XCTAssertEqual(zip(back, tone).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 0.0001)

        // The file holds no run of the plain 16-bit samples.
        let onDisk = try Data(contentsOf: spool.fileURL)
        let plain = tone[1_000..<1_008].map { Int16(($0 * Float(Int16.max)).rounded()).littleEndian }
        let pattern = plain.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertNil(onDisk.range(of: pattern))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: spool.fileURL.path)[.posixPermissions] as? Int, 0o600)
    }

    func testDeleteRemovesTheFileAndLeftoversAreCleanedUp() throws {
        let spool = try MeetingAudioSpool(folder: folder)
        spool.append([0.1, 0.2])
        spool.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.fileURL.path))

        let crashed = try MeetingAudioSpool(folder: folder)
        crashed.append(Array(repeating: 0.1, count: 40_000))
        _ = try crashed.readAll()
        MeetingAudioSpool.removeLeftovers(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.fileURL.path))
        XCTAssertEqual(try URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}

// MARK: - Controller with speakers and the pass after Stop

private final class FakeSource: MeetingAudioSource {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws { self.onAudio = onAudio }
    func stop() { onAudio = nil }
}

private final class FakeRecognizer: MeetingSpeechRecognizer {
    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async {}
}

private final class FakeTracker: MeetingSpeakerTracking {
    var turns: [SpeakerTurn] = []
    var received = 0
    func append(_ samples: [Float]) { received += samples.count }
}

private final class FakeSpool: MeetingAudioSpooling {
    var samples: [Float] = []
    var deleted = false
    func append(_ samples: [Float]) { self.samples += samples }
    func readAll() throws -> [Float] { samples }
    func delete() { deleted = true }
}

@MainActor
final class MeetingControllerSpeakerTests: XCTestCase {
    private let source = FakeSource()
    private let tracker = FakeTracker()
    private let spool = FakeSpool()
    private var languageID = "de"
    private var installed = true
    private var requestedLanguages: [String] = []
    private var finalPass: Result<FinalMeetingPass.Result, Error> = .success(FinalMeetingPass.Result(words: [], turns: []))
    private var passInput: [Float] = []

    private func makeController() -> MeetingController {
        MeetingController(environment: MeetingController.Environment(
            settings: { [unowned self] in MeetingSettings(hotkey: .defaultMeeting, languageID: self.languageID, microphoneID: nil) },
            interfaceLanguageID: { "en" },
            makeAudioSource: { [unowned self] _ in self.source },
            makeRecognizer: { [unowned self] in self.requestedLanguages.append($0); return FakeRecognizer() },
            requestMicrophoneAccess: { true },
            areSubtitlesRunning: { false },
            stopSubtitles: {},
            now: Date.init,
            modelsInstalled: { [unowned self] in self.installed },
            makeSpeakerTracker: { [unowned self] in self.tracker },
            makeAudioSpool: { [unowned self] in self.spool },
            runFinalPass: { [unowned self] samples, progress in
                self.passInput = samples
                progress(0.5)
                return try self.finalPass.get()
            }
        ))
    }

    private func started() async -> MeetingController {
        let meeting = makeController()
        meeting.prepareToStart()
        await meeting.start()
        return meeting
    }

    private func feed(seconds: Double) {
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: MeetingAudioFormat.format, frameCapacity: frames)!
        buffer.frameLength = frames
        source.onAudio?(buffer)
    }

    func testWithTheModelsAutoDetectStartsAndAudioReachesSpeakersAndSpool() async {
        languageID = "auto"
        let meeting = await started()

        feed(seconds: 1)

        XCTAssertEqual(meeting.state, .running)
        XCTAssertEqual(requestedLanguages, ["auto"])
        XCTAssertEqual(tracker.received, 16_000)
        XCTAssertEqual(spool.samples.count, 16_000)
    }

    func testWithoutTheModelsNoAudioIsKept() async {
        installed = false
        let meeting = await started()
        feed(seconds: 1)

        XCTAssertEqual(meeting.state, .running)
        XCTAssertTrue(spool.samples.isEmpty)
        XCTAssertEqual(tracker.received, 0)

        await meeting.stop()
        XCTAssertEqual(meeting.state, .idle)
    }

    func testLiveSegmentsGetSpeakersNumberedByFirstAppearance() async {
        let meeting = await started()
        tracker.turns = [SpeakerTurn(speaker: "7", start: 0, end: 3), SpeakerTurn(speaker: "2", start: 3, end: 6)]

        meeting.apply(.final(text: "Hallo.", start: 0.5, end: 2))
        meeting.apply(.final(text: "Hi.", start: 3.5, end: 5))
        meeting.apply(.volatile(text: "Und", start: 5.2, end: 5.8))

        XCTAssertEqual(meeting.transcript.segments.map(\.speaker), [1, 2])
        XCTAssertEqual(meeting.transcript.draft?.speaker, 2)
        XCTAssertEqual(meeting.speakerName(2), "Speaker 2")
        meeting.renameSpeaker(2, to: "  Anna ")
        XCTAssertEqual(meeting.speakerName(2), "Anna")
        meeting.renameSpeaker(2, to: "")
        XCTAssertEqual(meeting.speakerName(2), "Speaker 2")
    }

    func testThePassAfterStopReplacesTheTranscriptKeepsNamesAndDeletesTheAudio() async {
        let meeting = await started()
        tracker.turns = [SpeakerTurn(speaker: "x", start: 0, end: 3), SpeakerTurn(speaker: "y", start: 3, end: 6)]
        feed(seconds: 2)
        meeting.apply(.final(text: "halo zusamen", start: 0.5, end: 2))
        meeting.apply(.final(text: "hi tanks", start: 3.5, end: 5))
        meeting.renameSpeaker(2, to: "Anna")
        finalPass = .success(FinalMeetingPass.Result(
            words: words([("Hallo", 0.5, 1), ("zusammen.", 1.1, 2), ("Hi,", 3.5, 4), ("thanks.", 4.1, 5)]),
            turns: [SpeakerTurn(speaker: "S1", start: 3, end: 6), SpeakerTurn(speaker: "S2", start: 0, end: 3)]
        ))

        await meeting.stop()

        XCTAssertEqual(passInput.count, 32_000)
        XCTAssertTrue(spool.deleted)
        XCTAssertEqual(meeting.state, .idle)
        XCTAssertEqual(meeting.transcript.segments.map(\.text), ["Hallo zusammen.", "Hi, thanks."])
        XCTAssertEqual(meeting.copyText, "[0:00] Speaker 1: Hallo zusammen.\n[0:03] Anna: Hi, thanks.")
    }

    func testAFailedPassKeepsTheLiveTranscriptAndStillDeletesTheAudio() async {
        let meeting = await started()
        feed(seconds: 1)
        meeting.apply(.final(text: "Live text.", start: 0, end: 1))
        finalPass = .failure(CocoaError(.fileReadCorruptFile))

        await meeting.stop()

        XCTAssertTrue(spool.deleted)
        XCTAssertEqual(meeting.transcript.segments.map(\.text), ["Live text."])
        XCTAssertEqual(meeting.state, .idle)
    }

    func testQuittingDeletesTheAudio() async {
        let meeting = await started()
        feed(seconds: 1)

        meeting.stopImmediately()

        XCTAssertTrue(spool.deleted)
    }
}

@MainActor
final class MeetingModelsServiceTests: XCTestCase {
    func testDownloadReportsProgressThenTheSize() async {
        var installed = false
        let service = MeetingModelsService(
            isInstalled: { installed },
            measure: { 1_300_000_000 },
            download: { progress in
                progress(0.4)
                installed = true
            },
            delete: { installed = false }
        )
        XCTAssertEqual(service.status, .notInstalled)

        await service.download()

        XCTAssertEqual(service.status, .installed(bytes: 1_300_000_000))
        XCTAssertTrue(service.isInstalled)
        service.delete()
        XCTAssertEqual(service.status, .notInstalled)
    }

    func testAFailedDownloadSaysWhy() async {
        let service = MeetingModelsService(
            isInstalled: { false },
            measure: { 0 },
            download: { _ in throw URLError(.notConnectedToInternet) },
            delete: {}
        )

        await service.download()

        guard case .failed = service.status else { return XCTFail("\(service.status)") }
        XCTAssertFalse(service.isInstalled)
    }

    func testTheModelTextsExistInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .meetingModelsTitle, .meetingModelsNotInstalled, .meetingModelsInstalledFormat,
            .meetingModelsDownloadingFormat, .meetingModelsFailedFormat, .meetingModelsDownload,
            .meetingModelsDelete, .meetingModelsExplanation, .meetingImproving, .meetingRenameTitleFormat,
            .meetingRenamePlaceholder, .meetingRenameHint,
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
