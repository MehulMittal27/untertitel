import XCTest
@testable import v2s

/// Stands in for the server: records what the client sends and lets a test push events.
private final class FakeTranslateSocket: OpenAITranslateSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _handshakeStatusCode: Int?
    private var _isCancelled = false
    private var pendingReceive: (@Sendable (Result<String, Error>) -> Void)?
    private var inbox: [Result<String, Error>] = []

    var sent: [String] { lock.withLock { _sent } }
    var isCancelled: Bool { lock.withLock { _isCancelled } }
    var handshakeStatusCode: Int? {
        get { lock.withLock { _handshakeStatusCode } }
        set { lock.withLock { _handshakeStatusCode = newValue } }
    }

    var audioMessages: [String] {
        sent.filter { $0.contains("session.input_audio_buffer.append") }
    }

    func resume() {}

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { _sent.append(text) }
        completion(nil)
    }

    func receive(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        let ready: Result<String, Error>? = lock.withLock {
            if inbox.isEmpty {
                pendingReceive = completion
                return nil
            }
            return inbox.removeFirst()
        }
        if let ready { completion(ready) }
    }

    func cancel() {
        lock.withLock { _isCancelled = true }
    }

    func push(_ message: String) {
        deliver(.success(message))
    }

    func fail() {
        deliver(.failure(URLError(.networkConnectionLost)))
    }

    private func deliver(_ result: Result<String, Error>) {
        let waiting: (@Sendable (Result<String, Error>) -> Void)? = lock.withLock {
            guard let pendingReceive else {
                inbox.append(result)
                return nil
            }
            self.pendingReceive = nil
            return pendingReceive
        }
        waiting?(result)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeTranslateSocket] = []
    private var _outputs: [TranslateDeltaAssembler.Output] = []
    private var _states: [CloudEngineState] = []
    private var _failures: [CloudEngineFailure] = []
    private var _streamedSeconds: TimeInterval = 0
    private var _now: TimeInterval = 1_000
    private var _wallNow = Date(timeIntervalSince1970: 1_800_000_000)

    var sockets: [FakeTranslateSocket] { lock.withLock { _sockets } }
    var outputs: [TranslateDeltaAssembler.Output] { lock.withLock { _outputs } }
    var states: [CloudEngineState] { lock.withLock { _states } }
    var failures: [CloudEngineFailure] { lock.withLock { _failures } }
    var streamedSeconds: TimeInterval { lock.withLock { _streamedSeconds } }
    var now: TimeInterval { lock.withLock { _now } }
    var wallNow: Date { lock.withLock { _wallNow } }

    var sentences: [TranslateDeltaAssembler.Sentence] {
        outputs.compactMap { output in
            if case .sentence(let sentence) = output { return sentence }
            return nil
        }
    }

    func addSocket(_ socket: FakeTranslateSocket) { lock.withLock { _sockets.append(socket) } }
    func add(outputs: [TranslateDeltaAssembler.Output]) { lock.withLock { _outputs.append(contentsOf: outputs) } }
    func add(state: CloudEngineState) { lock.withLock { _states.append(state) } }
    func add(failure: CloudEngineFailure) { lock.withLock { _failures.append(failure) } }
    func add(seconds: TimeInterval) { lock.withLock { _streamedSeconds += seconds } }
    func advance(by interval: TimeInterval) {
        lock.withLock {
            _now += interval
            _wallNow += interval
        }
    }

    /// Time that passes while the Mac sleeps: the wall clock moves, the uptime clock does not.
    func sleepMac(for interval: TimeInterval) {
        lock.withLock { _wallNow += interval }
    }
}

final class OpenAITranslateClientTests: XCTestCase {
    private static let created = #"{"type":"session.created","session":{"id":"sess_1"}}"#
    private static let updated = #"{"type":"session.updated","session":{"id":"sess_1"}}"#

    private func makeClient(
        recorder: Recorder,
        configure: (inout OpenAITranslateClient.Configuration) -> Void = { _ in }
    ) -> OpenAITranslateClient {
        var configuration = OpenAITranslateClient.Configuration(targetLanguageCode: "en")
        configuration.runsTimer = false
        configuration.closeTimeout = 0.05
        configuration.usageReportChunkCount = 1
        configure(&configuration)

        var handlers = OpenAITranslateClient.Handlers()
        handlers.outputs = { recorder.add(outputs: $0) }
        handlers.stateChanged = { recorder.add(state: $0) }
        handlers.failed = { recorder.add(failure: $0) }
        handlers.streamedAudio = { recorder.add(seconds: $0) }

        return OpenAITranslateClient(
            apiKey: "sk-test",
            configuration: configuration,
            handlers: handlers,
            makeSocket: { _ in
                let socket = FakeTranslateSocket()
                recorder.addSocket(socket)
                return socket
            },
            clock: { recorder.now },
            wallClock: { recorder.wallNow }
        )
    }

    /// Runs everything already queued on the client's queue, including follow-up work.
    private func drain(_ client: OpenAITranslateClient) {
        for _ in 0..<3 {
            client.queue.sync {}
        }
    }

    private func waitForSocket(_ index: Int, recorder: Recorder, client: OpenAITranslateClient) async throws -> FakeTranslateSocket {
        for _ in 0..<400 {
            drain(client)
            if recorder.sockets.count > index {
                return recorder.sockets[index]
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the client never opened socket \(index)")
        throw CancellationError()
    }

    private func accept(_ socket: FakeTranslateSocket, client: OpenAITranslateClient, created: String = created) {
        socket.push(created)
        drain(client)
        socket.push(Self.updated)
        drain(client)
    }

    private func startedClient(
        recorder: Recorder,
        created: String = created,
        configure: (inout OpenAITranslateClient.Configuration) -> Void = { _ in }
    ) async throws -> (OpenAITranslateClient, FakeTranslateSocket) {
        let client = makeClient(recorder: recorder, configure: configure)
        let start = Task { try await client.start() }
        let socket = try await waitForSocket(0, recorder: recorder, client: client)
        accept(socket, client: client, created: created)
        try await start.value
        return (client, socket)
    }

    private func tick(_ client: OpenAITranslateClient) {
        client.queue.sync { client.tick() }
        drain(client)
    }

    func testStartConfiguresTheSessionBeforeAnyAudio() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertTrue(socket.sent[0].contains("session.update"))
        XCTAssertEqual(recorder.states, [.streaming])

        client.appendSamples([Int16](repeating: 7, count: 4_800))
        drain(client)

        XCTAssertEqual(socket.audioMessages.count, 1)
        XCTAssertEqual(recorder.streamedSeconds, 0.2, accuracy: 0.0001)
    }

    func testAudioIsSentInCaptureOrderIn200MillisecondChunks() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        client.appendSamples([Int16](repeating: 1, count: 3_000))
        client.appendSamples([Int16](repeating: 2, count: 3_000))
        client.appendSamples([Int16](repeating: 3, count: 3_600))
        drain(client)

        let chunks = try socket.audioMessages.map { message -> [UInt8] in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String])
            return Array(try XCTUnwrap(json["audio"].flatMap { Data(base64Encoded: $0) }))
        }

        XCTAssertEqual(chunks.map(\.count), [9_600, 9_600])
        XCTAssertEqual(chunks[0].first, 1)
        XCTAssertEqual(chunks[0].last, 0, "high byte of the sample 2")
        XCTAssertEqual(chunks[0][9_598], 2)
        XCTAssertEqual(chunks[1][9_598], 3)
    }

    func testTranscriptDeltasBecomeADraftAndThenASentence() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        socket.push(#"{"type":"session.input_transcript.delta","delta":"Das passt."}"#)
        socket.push(#"{"type":"session.output_transcript.delta","delta":"That works."}"#)
        drain(client)
        XCTAssertTrue(recorder.sentences.isEmpty)

        client.noteVoiceActivity(isSpeaking: false, onset: false, offset: true)
        drain(client)
        recorder.advance(by: 1)
        tick(client)

        XCTAssertEqual(recorder.sentences.map(\.sourceText), ["Das passt."])
        XCTAssertEqual(recorder.sentences.map(\.translatedText), ["That works."])
    }

    func testTranslatedAudioProducesNoOutputAtAll() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        socket.push(#"{"type":"session.output_audio.delta","delta":"AAAAAAAA","sample_rate":24000}"#)
        socket.push(#"{"type":"session.some_future_event"}"#)
        drain(client)

        XCTAssertTrue(recorder.outputs.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(socket.sent.count, 1, "nothing is sent in response")
    }

    func testStopAsksTheServerToCloseAndThenDropsTheSocket() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        client.stop()
        drain(client)

        XCTAssertEqual(socket.sent.last, OpenAITranslateProtocol.sessionCloseMessage)
        try await Task.sleep(nanoseconds: 200_000_000)
        drain(client)
        XCTAssertTrue(socket.isCancelled)

        client.appendSamples([Int16](repeating: 1, count: 4_800))
        drain(client)
        XCTAssertTrue(socket.audioMessages.isEmpty, "a stopped client sends no more audio")
    }

    func testRejectedKeyFailsTheStart() async throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder)
        let start = Task { try await client.start() }
        let socket = try await waitForSocket(0, recorder: recorder, client: client)

        socket.handshakeStatusCode = 401
        socket.fail()
        drain(client)

        do {
            try await start.value
            XCTFail("start should have thrown")
        } catch {
            XCTAssertEqual(error as? CloudEngineFailure, .authenticationFailed)
        }
        XCTAssertTrue(socket.isCancelled)
        XCTAssertTrue(recorder.failures.isEmpty, "a failed start is reported by the throw alone")
    }

    /// OpenAI accepts the connection and then refuses an invalid key with this event.
    func testInvalidKeyErrorEventFailsTheStartAsRejectedKey() async throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder)
        let start = Task { try await client.start() }
        let socket = try await waitForSocket(0, recorder: recorder, client: client)

        socket.handshakeStatusCode = 101
        socket.push(
            #"{"type":"error","event_id":"event_1","error":{"type":"invalid_request_error","code":"invalid_api_key","message":"Incorrect API key provided.","param":null,"event_id":null}}"#
        )
        drain(client)

        do {
            try await start.value
            XCTFail("start should have thrown")
        } catch {
            XCTAssertEqual(error as? CloudEngineFailure, .authenticationFailed)
        }
    }

    func testUnreachableServerFailsTheStart() async throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder)
        let start = Task { try await client.start() }
        let socket = try await waitForSocket(0, recorder: recorder, client: client)

        socket.fail()
        drain(client)

        do {
            try await start.value
            XCTFail("start should have thrown")
        } catch {
            XCTAssertEqual(error as? CloudEngineFailure, .connectionFailed)
        }
    }

    func testErrorBeforeTheSessionIsConfiguredFailsTheStart() async throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder)
        let start = Task { try await client.start() }
        let socket = try await waitForSocket(0, recorder: recorder, client: client)

        socket.push(Self.created)
        drain(client)
        socket.push(#"{"type":"error","error":{"type":"invalid_request_error","message":"Unsupported language"}}"#)
        drain(client)

        do {
            try await start.value
            XCTFail("start should have thrown")
        } catch {
            XCTAssertEqual(error as? CloudEngineFailure, .rejected("Unsupported language"))
        }
    }

    func testErrorWhileStreamingKeepsTheSessionOpen() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        socket.push(#"{"type":"error","error":{"type":"invalid_request_error","message":"Bad event"}}"#)
        drain(client)
        client.appendSamples([Int16](repeating: 1, count: 4_800))
        drain(client)

        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(socket.audioMessages.count, 1)
    }

    func testDroppedConnectionIsReportedOnceAndNotRetried() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        socket.fail()
        drain(client)
        tick(client)
        client.appendSamples([Int16](repeating: 1, count: 4_800))
        drain(client)

        XCTAssertEqual(recorder.failures, [.connectionLost])
        XCTAssertEqual(recorder.sockets.count, 1, "no reconnect loop")
        XCTAssertTrue(socket.audioMessages.isEmpty)
    }

    func testSilenceIsSentWhenTheCaptureStalls() async throws {
        let recorder = Recorder()
        let (client, socket) = try await startedClient(recorder: recorder)

        recorder.advance(by: 0.2)
        tick(client)
        XCTAssertTrue(socket.audioMessages.isEmpty, "a short gap is not a stall")

        recorder.advance(by: 0.3)
        tick(client)

        XCTAssertEqual(socket.audioMessages.count, 1)
        XCTAssertEqual(
            socket.audioMessages.first,
            OpenAITranslateProtocol.appendAudioMessage(
                pcm16: PCM16Encoding.littleEndianData(from: PCM16Chunker.silentChunk())
            )
        )
    }

    func testThreeMinutesWithoutSpeechPausesAndSpeechResumes() async throws {
        let recorder = Recorder()
        let (client, firstSocket) = try await startedClient(recorder: recorder)

        recorder.advance(by: 179)
        client.appendSamples([Int16](repeating: 0, count: 4_800))
        drain(client)
        tick(client)
        XCTAssertEqual(recorder.states, [.streaming], "not idle long enough")

        recorder.advance(by: 2)
        client.appendSamples([Int16](repeating: 0, count: 4_800))
        drain(client)
        tick(client)

        XCTAssertEqual(recorder.states, [.streaming, .pausedNoAudio])
        XCTAssertEqual(firstSocket.sent.last, OpenAITranslateProtocol.sessionCloseMessage)
        let audioSentBeforePause = firstSocket.audioMessages.count
        let secondsBilledBeforePause = recorder.streamedSeconds

        // Paused: audio is kept as a short pre-roll, not sent and not counted.
        for _ in 0..<8 {
            client.appendSamples([Int16](repeating: 5, count: 4_800))
        }
        drain(client)
        tick(client)
        XCTAssertEqual(firstSocket.audioMessages.count, audioSentBeforePause)
        XCTAssertEqual(recorder.streamedSeconds, secondsBilledBeforePause)
        XCTAssertEqual(recorder.sockets.count, 1)

        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        let secondSocket = try await waitForSocket(1, recorder: recorder, client: client)
        accept(secondSocket, client: client)

        XCTAssertEqual(recorder.states, [.streaming, .pausedNoAudio, .reconnecting, .streaming])
        XCTAssertEqual(secondSocket.audioMessages.count, 5, "one second of pre-roll is replayed")
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    private func pausedClient(recorder: Recorder) async throws -> (OpenAITranslateClient, FakeTranslateSocket) {
        let (client, socket) = try await startedClient(recorder: recorder)
        recorder.advance(by: 181)
        client.appendSamples([Int16](repeating: 0, count: 4_800))
        drain(client)
        tick(client)
        XCTAssertEqual(recorder.states, [.streaming, .pausedNoAudio])
        return (client, socket)
    }

    func testFifteenMinutesPausedStopsTheSessionForGood() async throws {
        let recorder = Recorder()
        let (client, _) = try await pausedClient(recorder: recorder)

        recorder.advance(by: 899)
        tick(client)
        XCTAssertEqual(recorder.states, [.streaming, .pausedNoAudio], "not paused long enough")

        recorder.advance(by: 2)
        tick(client)
        XCTAssertEqual(recorder.states, [.streaming, .pausedNoAudio, .stoppedAfterLongPause])

        // Speech after that must not reopen the connection.
        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        client.appendSamples([Int16](repeating: 9, count: 4_800))
        drain(client)
        tick(client)

        XCTAssertEqual(recorder.sockets.count, 1)
        XCTAssertEqual(recorder.states.last, .stoppedAfterLongPause)
        XCTAssertTrue(recorder.failures.isEmpty, "stopping is not a failure, so nothing falls back")
    }

    func testSpeechRightAfterTheMacWakesFromALongSleepStopsInsteadOfResuming() async throws {
        let recorder = Recorder()
        let (client, _) = try await pausedClient(recorder: recorder)

        // Lid closed for eight hours, then audio arrives before the next timer tick.
        recorder.sleepMac(for: 8 * 3_600)
        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        drain(client)

        XCTAssertEqual(recorder.states, [.streaming, .pausedNoAudio, .stoppedAfterLongPause])
        XCTAssertEqual(recorder.sockets.count, 1, "no new connection, so no new billing")
    }

    func testWithoutAVoiceDetectorAudibleAudioCountsAsActivity() async throws {
        let recorder = Recorder()
        let (client, _) = try await startedClient(recorder: recorder) { $0.hasVoiceActivitySignal = false }

        recorder.advance(by: 170)
        client.appendSamples([Int16](repeating: 2_000, count: 4_800))
        drain(client)
        recorder.advance(by: 20)
        client.appendSamples([Int16](repeating: 0, count: 4_800))
        drain(client)
        tick(client)

        XCTAssertEqual(recorder.states, [.streaming], "audible audio 20 s ago keeps the session open")
    }

    func testSessionCloseToExpiryIsReplacedAtAPause() async throws {
        let recorder = Recorder()
        let expiresAt = recorder.wallNow.timeIntervalSince1970 + 600
        let created = #"{"type":"session.created","session":{"id":"sess_1","expires_at":\#(expiresAt)}}"#
        let (client, firstSocket) = try await startedClient(recorder: recorder, created: created)

        recorder.advance(by: 100)
        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        client.appendSamples([Int16](repeating: 9, count: 4_800))
        drain(client)
        tick(client)
        XCTAssertEqual(recorder.sockets.count, 1, "plenty of time left")

        recorder.advance(by: 420)
        client.noteVoiceActivity(isSpeaking: true, onset: false, offset: false)
        client.appendSamples([Int16](repeating: 9, count: 4_800))
        drain(client)
        tick(client)
        XCTAssertEqual(recorder.sockets.count, 1, "80 s left, but someone is speaking")

        client.noteVoiceActivity(isSpeaking: false, onset: false, offset: true)
        client.appendSamples([Int16](repeating: 0, count: 4_800))
        drain(client)
        tick(client)

        let secondSocket = try await waitForSocket(1, recorder: recorder, client: client)
        XCTAssertEqual(firstSocket.sent.last, OpenAITranslateProtocol.sessionCloseMessage)

        // Audio captured while the replacement opens is queued, then sent.
        client.appendSamples([Int16](repeating: 4, count: 9_600))
        drain(client)
        XCTAssertTrue(secondSocket.audioMessages.isEmpty)
        accept(secondSocket, client: client)

        XCTAssertEqual(secondSocket.audioMessages.count, 2)
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    func testSessionAtItsDeadlineIsReplacedEvenMidSpeech() async throws {
        let recorder = Recorder()
        let expiresAt = recorder.wallNow.timeIntervalSince1970 + 600
        let created = #"{"type":"session.created","session":{"id":"sess_1","expires_at":\#(expiresAt)}}"#
        let (client, _) = try await startedClient(recorder: recorder, created: created)

        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        recorder.advance(by: 590)
        client.noteVoiceActivity(isSpeaking: true, onset: false, offset: false)
        client.appendSamples([Int16](repeating: 9, count: 4_800))
        drain(client)
        tick(client)

        XCTAssertEqual(recorder.sockets.count, 2)
    }
}
