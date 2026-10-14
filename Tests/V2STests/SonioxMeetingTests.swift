import AVFoundation
import MeetingKit
import XCTest
@testable import v2s

private func token(_ text: String, _ speaker: String?, _ start: Int, _ end: Int) -> SpeakerToken {
    SpeakerToken(text: text, speaker: speaker, startMilliseconds: start, endMilliseconds: end)
}

final class SpeakerTokenAssemblerTests: XCTestCase {
    func testPiecesBecomeWordsAndSpeakerChangesEndSegments() {
        var assembler = SpeakerTokenAssembler()

        let output = assembler.update(
            final: [
                token("Gu", "1", 0, 200), token("ten", "1", 200, 400), token(" Morgen", "1", 450, 900),
                token(" Hi", "2", 1_500, 1_700), token(" there", "2", 1_750, 2_000),
            ],
            provisional: [token(" how", "2", 2_100, 2_300)],
            offset: 10
        )

        XCTAssertEqual(output.finals.map(\.text), ["Guten Morgen"])
        XCTAssertEqual(output.finals.first?.speaker, "1")
        XCTAssertEqual(output.finals.first?.start ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(output.finals.first?.end ?? 0, 10.9, accuracy: 0.001)
        XCTAssertEqual(output.draft?.text, "Hi there how")
        XCTAssertEqual(output.draft?.speaker, "2")
    }

    func testASentenceEndIsFinalOnceSomethingFollowsAndFlushKeepsTheRest() {
        var assembler = SpeakerTokenAssembler()
        XCTAssertTrue(assembler.update(final: [token("Ja.", "1", 0, 300)], provisional: [], offset: 0).finals.isEmpty)

        let next = assembler.update(final: [token(" Und", "1", 500, 700)], provisional: [], offset: 0)
        XCTAssertEqual(next.finals.map(\.text), ["Ja."])

        XCTAssertEqual(assembler.flush().map(\.text), ["Und"])
        XCTAssertTrue(assembler.flush().isEmpty)
    }

    func testAPieceContinuesTheWordFromTheResponseBefore() {
        var assembler = SpeakerTokenAssembler()
        _ = assembler.update(final: [token("Zusam", "1", 0, 300)], provisional: [], offset: 0)
        let output = assembler.update(final: [token("men", "1", 300, 500), token(" gut.", "1", 600, 800), token(" Ok", "2", 1_000, 1_200)], provisional: [], offset: 0)

        XCTAssertEqual(output.finals.map(\.text), ["Zusammen gut."])
    }
}

/// Plays Soniox's recorded-file API, and records every request.
private final class FakeSoniox: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var polls = 0
    var failsTranscription = false
    var requests: [URLRequest] { lock.withLock { _requests } }

    func respond(_ request: URLRequest) -> (Data, Int) {
        lock.withLock { _requests.append(request) }
        let path = request.url!.path
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "/v1/files"):
            return (Data(#"{"id":"file-1"}"#.utf8), 201)
        case ("POST", "/v1/transcriptions"):
            return (Data(#"{"id":"tr-1","status":"queued"}"#.utf8), 201)
        case ("GET", "/v1/transcriptions/tr-1"):
            polls += 1
            if failsTranscription { return (Data(#"{"status":"error","error_message":"bad audio"}"#.utf8), 200) }
            return (Data((polls < 2 ? #"{"status":"processing"}"# : #"{"status":"completed"}"#).utf8), 200)
        case ("GET", "/v1/transcriptions/tr-1/transcript"):
            return (Data(#"{"text":"Hallo. Hi.","tokens":[{"text":"Hal","start_ms":0,"end_ms":200,"speaker":"1"},{"text":"lo.","start_ms":200,"end_ms":500,"speaker":"1"},{"text":" Hi.","start_ms":900,"end_ms":1200,"speaker":"2"}]}"#.utf8), 200)
        case ("DELETE", _):
            return (Data(), 204)
        default:
            return (Data(#"{"message":"unexpected"}"#.utf8), 404)
        }
    }
}

final class SonioxFilePassTests: XCTestCase {
    private func pass(_ fake: FakeSoniox) -> SonioxFilePass {
        var pass = SonioxFilePass(apiKey: "soniox-key", languageCode: "de")
        pass.send = { request in fake.respond(request) }
        pass.sleep = { _ in }
        return pass
    }

    func testTheMeetingIsUploadedTranscribedWithSpeakersAndDeletedAtSoniox() async throws {
        let fake = FakeSoniox()

        let result = try await pass(fake).run(samples: [Float](repeating: 0.1, count: 16_000)) { _ in }

        XCTAssertEqual(result.words.map(\.text), ["Hallo.", "Hi."])
        XCTAssertEqual(result.turns.map(\.speaker), ["1", "2"])
        XCTAssertEqual(result.turns.last?.start ?? 0, 0.9, accuracy: 0.001)

        let calls = fake.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" }
        XCTAssertEqual(calls.first, "POST /v1/files")
        XCTAssertTrue(calls.contains("DELETE /v1/transcriptions/tr-1"))
        XCTAssertTrue(calls.contains("DELETE /v1/files/file-1"))
        XCTAssertTrue(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer soniox-key" })

        let create = try XCTUnwrap(fake.requests.first { $0.url!.path == "/v1/transcriptions" && $0.httpMethod == "POST" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "stt-async-v5")
        XCTAssertEqual(body["file_id"] as? String, "file-1")
        XCTAssertEqual(body["enable_speaker_diarization"] as? Bool, true)
        XCTAssertEqual(body["language_hints"] as? [String], ["de"])
    }

    func testAFailedTranscriptionStillDeletesEverythingAtSoniox() async {
        let fake = FakeSoniox()
        fake.failsTranscription = true

        do {
            _ = try await pass(fake).run(samples: [0, 0.1]) { _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? SonioxFilePass.PassError, .transcriptionFailed("bad audio"))
        }
        let calls = fake.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" }
        XCTAssertTrue(calls.contains("DELETE /v1/transcriptions/tr-1"))
        XCTAssertTrue(calls.contains("DELETE /v1/files/file-1"))
    }

    func testTheUploadIsAPlainSixteenKilohertzWAV() {
        let wav = SonioxFilePass.wav(samples: [0, 1, -1])

        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav.count, 44 + 6)
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
    }
}

// MARK: - Controller

private final class Source: MeetingAudioSource {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws { self.onAudio = onAudio }
    func stop() {}
}

private final class Recognizer: MeetingSpeechRecognizer {
    var resumed = false
    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async {}
    func resume() { resumed = true }
}

private final class Spool: MeetingAudioSpooling {
    var samples: [Float] = []
    func append(_ samples: [Float]) { self.samples += samples }
    func readAll() throws -> [Float] { samples }
    func delete() {}
}

@MainActor
final class SonioxMeetingControllerTests: XCTestCase {
    private var settings = MeetingSettings.default
    private var key: String? = "soniox-key"
    private let recognizer = Recognizer()
    private let source = Source()
    private let spool = Spool()
    private var sonioxRequests: [(key: String, code: String?)] = []
    private var callbacks: SonioxMeetingRecognizer.Callbacks?
    private var filePasses: [(String, String?, Int)] = []
    private var usage: [(TimeInterval, Bool)] = []
    private var localPasses = 0

    private func makeController() -> MeetingController {
        MeetingController(environment: MeetingController.Environment(
            settings: { [unowned self] in self.settings },
            interfaceLanguageID: { "en" },
            makeAudioSource: { [unowned self] _ in self.source },
            makeRecognizer: { [unowned self] _ in self.recognizer },
            requestMicrophoneAccess: { true },
            areSubtitlesRunning: { false },
            stopSubtitles: {},
            now: Date.init,
            modelsInstalled: { false },
            makeAudioSpool: { [unowned self] in self.spool },
            runFinalPass: { [unowned self] _, _ in
                self.localPasses += 1
                return FinalMeetingPass.Result(words: [], turns: [])
            },
            sonioxAPIKey: { [unowned self] in self.key },
            makeSonioxRecognizer: { [unowned self] key, code, _, callbacks in
                self.sonioxRequests.append((key, code))
                self.callbacks = callbacks
                return self.recognizer
            },
            runSonioxFilePass: { [unowned self] key, code, samples, _ in
                self.filePasses.append((key, code, samples.count))
                return FinalMeetingPass.Result(
                    words: [TimedWord(text: "Hallo.", start: 0, end: 0.5), TimedWord(text: "Hi.", start: 1, end: 1.4)],
                    turns: [SpeakerTurn(speaker: "1", start: 0, end: 0.6), SpeakerTurn(speaker: "2", start: 0.9, end: 1.5)]
                )
            },
            recordSonioxUsage: { [unowned self] seconds, isFile in self.usage.append((seconds, isFile)) }
        ))
    }

    private func start(_ meeting: MeetingController) async {
        meeting.prepareToStart()
        await meeting.start()
    }

    func testSonioxLiveNeedsAKey() async {
        settings.liveEngine = .soniox
        key = nil
        let meeting = makeController()

        await start(meeting)

        XCTAssertEqual(meeting.state, .failed("Soniox needs an API key: add it in Settings > Engine."))
        XCTAssertTrue(sonioxRequests.isEmpty)
    }

    func testSonioxLiveUsesItsSpeakersCostAndResume() async {
        settings.liveEngine = .soniox
        settings.languageID = "nb"
        settings.finalPass = .off
        let meeting = makeController()

        await start(meeting)
        XCTAssertEqual(meeting.state, .running)
        XCTAssertEqual(sonioxRequests.first?.code, "no", "Soniox's code for Norwegian")

        meeting.apply(.final(text: "Hallo.", start: 0, end: 1, speaker: "7"))
        meeting.apply(.final(text: "Hi.", start: 1, end: 2, speaker: "3"))
        XCTAssertEqual(meeting.transcript.segments.map(\.speaker), [1, 2])

        callbacks?.streamedSeconds(600)
        XCTAssertEqual(usage.first?.0, 600)
        XCTAssertEqual(usage.first?.1, false)
        XCTAssertEqual(meeting.cloudCostText, "Soniox: 10 min ≈ $0.02")

        callbacks?.stateChanged(.pausedNoAudio)
        XCTAssertEqual(meeting.cloudState, .pausedNoAudio)
        meeting.resumeCloud()
        XCTAssertTrue(recognizer.resumed)

        callbacks?.failed(.authenticationFailed)
        XCTAssertEqual(meeting.liveNotice, "Soniox stopped: API key")
        XCTAssertTrue(spool.samples.isEmpty, "no pass after Stop chosen: no audio kept")
    }

    func testTheSonioxFilePassRunsAfterStopEvenWithoutLocalModels() async {
        settings.languageID = "de"
        settings.finalPass = .sonioxFile
        let meeting = makeController()
        await start(meeting)
        let buffer = AVAudioPCMBuffer(pcmFormat: MeetingAudioFormat.format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        source.onAudio?(buffer)

        await meeting.stop()

        XCTAssertEqual(filePasses.count, 1)
        XCTAssertEqual(filePasses.first?.1, "de")
        XCTAssertEqual(filePasses.first?.2, 32_000)
        XCTAssertEqual(localPasses, 0)
        XCTAssertEqual(usage.last?.0 ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(usage.last?.1, true)
        XCTAssertEqual(meeting.transcript.segments.map(\.text), ["Hallo.", "Hi."])
        XCTAssertEqual(meeting.transcript.segments.map(\.speaker), [1, 2])
    }

    func testTheConsentNoteSaysWhatGoesToSoniox() {
        let meeting = makeController()
        XCTAssertTrue(meeting.consentText(in: "en").contains("no audio or text is sent anywhere"))

        settings.liveEngine = .soniox
        let live = meeting.consentText(in: "en")
        XCTAssertTrue(live.contains("sent to Soniox, a transcription service, while we talk"))
        XCTAssertFalse(live.contains("no audio or text is sent anywhere"))

        settings.liveEngine = .onDevice
        settings.finalPass = .sonioxFile
        let file = meeting.consentText(in: "de")
        XCTAssertTrue(file.contains("Während des Meetings läuft das auf meinem Mac."))
        XCTAssertTrue(file.contains("einmal an Soniox gesendet"))
        XCTAssertTrue(file.hasSuffix("bitte kurz Bescheid geben."))
    }

    func testOlderSettingsKeepEverythingOnTheMac() throws {
        let decoded = try JSONDecoder().decode(MeetingSettings.self, from: Data(#"{"languageID":"de"}"#.utf8))
        XCTAssertEqual(decoded.liveEngine, .onDevice)
        XCTAssertEqual(decoded.finalPass, .onDevice)
        let encoded = try JSONEncoder().encode(MeetingSettings.default)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSettings.self, from: encoded), .default)
    }

    func testTheSonioxMeetingTextsExistInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .meetingLiveEngine, .meetingEngineOnDevice, .meetingEngineSoniox, .meetingFinalPassLabel,
            .meetingFinalOnDevice, .meetingFinalSonioxFile, .meetingFinalOff, .meetingSonioxNeedsKey,
            .meetingCloudPaused, .meetingResume, .meetingCloudCostFormat, .meetingSonioxStoppedFormat,
        ]
        for language in LanguageCatalog.interface {
            for key in keys {
                XCTAssertNotEqual(AppLocalization.string(key, languageID: language.id), key.rawValue, "\(language.id) \(key)")
            }
        }
    }
}
