import XCTest
@testable import v2s

/// Stands in for the server: records what the client sends and lets a test push events.
private final class FakeTranslateSocket: OpenAITranslateSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _sentData: [Data] = []
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

    func send(data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { _sentData.append(data) }
        completion(nil)
    }

    var sentData: [Data] { lock.withLock { _sentData } }

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
    private var _transcribedSeconds: TimeInterval = 0
    private var _connectionEvents: [CloudConnectionEvent] = []
    private var _now: TimeInterval = 1_000
    private var _wallNow = Date(timeIntervalSince1970: 1_800_000_000)

    var sockets: [FakeTranslateSocket] { lock.withLock { _sockets } }
    var outputs: [TranslateDeltaAssembler.Output] { lock.withLock { _outputs } }
    var states: [CloudEngineState] { lock.withLock { _states } }
    var failures: [CloudEngineFailure] { lock.withLock { _failures } }
    var streamedSeconds: TimeInterval { lock.withLock { _streamedSeconds } }
    var transcribedSeconds: TimeInterval { lock.withLock { _transcribedSeconds } }
    var connectionEvents: [CloudConnectionEvent] { lock.withLock { _connectionEvents } }
    let registry = CloudConnectionRegistry()
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
    func add(seconds: TimeInterval, transcribed: TimeInterval) {
        lock.withLock {
            _streamedSeconds += seconds
            _transcribedSeconds += transcribed
        }
    }
    func add(event: CloudConnectionEvent) { lock.withLock { _connectionEvents.append(event) } }
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

private final class CountLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []

    var values: [Int] { lock.withLock { _values } }
    func append(_ value: Int) { lock.withLock { _values.append(value) } }
}

final class OpenAITranslateClientTests: XCTestCase {
    private static let created = #"{"type":"session.created","session":{"id":"sess_1"}}"#
    private static let updated = #"{"type":"session.updated","session":{"id":"sess_1"}}"#

    /// 200 ms of audio that counts as sound, and 200 ms that counts as silence.
    private static let sound = [Int16](repeating: 2_000, count: 4_800)
    private static let silence = [Int16](repeating: 0, count: 4_800)

    private func makeClient(
        recorder: Recorder,
        configure: (inout OpenAITranslateClient.Configuration) -> Void = { _ in }
    ) -> OpenAITranslateClient {
        var configuration = OpenAITranslateClient.Configuration(targetLanguageCode: "en")
        configuration.runsTimer = false
        configuration.usageReportChunkCount = 1
        configure(&configuration)

        var handlers = OpenAITranslateClient.Handlers()
        handlers.outputs = { recorder.add(outputs: $0) }
        handlers.stateChanged = { recorder.add(state: $0) }
        handlers.failed = { recorder.add(failure: $0) }
        handlers.streamedAudio = { recorder.add(seconds: $0, transcribed: $1) }
        handlers.connectionEvent = { recorder.add(event: $0) }

        return OpenAITranslateClient(
            apiKey: "sk-test",
            configuration: configuration,
            handlers: handlers,
            makeSocket: { _ in
                let socket = FakeTranslateSocket()
                recorder.addSocket(socket)
                return socket
            },
            registry: recorder.registry,
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

    private func socket(_ index: Int, recorder: Recorder, client: OpenAITranslateClient) throws -> FakeTranslateSocket {
        drain(client)
        guard recorder.sockets.count > index else {
            XCTFail("the client never opened socket \(index)")
            throw CancellationError()
        }
        return recorder.sockets[index]
    }

    private func accept(_ socket: FakeTranslateSocket, client: OpenAITranslateClient, created: String = created) {
        socket.push(created)
        drain(client)
        socket.push(Self.updated)
        drain(client)
    }

    private func send(_ samples: [Int16], to client: OpenAITranslateClient) {
        client.appendSamples(samples)
        drain(client)
    }

    /// A started client that has not heard anything yet: no connection.
    private func waitingClient(
        recorder: Recorder,
        configure: (inout OpenAITranslateClient.Configuration) -> Void = { _ in }
    ) -> OpenAITranslateClient {
        let client = makeClient(recorder: recorder, configure: configure)
        client.start()
        drain(client)
        return client
    }

    /// A client connected by one chunk of sound, which has been sent as its first audio.
    private func streamingClient(
        recorder: Recorder,
        created: String = created,
        configure: (inout OpenAITranslateClient.Configuration) -> Void = { _ in }
    ) throws -> (OpenAITranslateClient, FakeTranslateSocket) {
        let client = waitingClient(recorder: recorder, configure: configure)
        send(Self.sound, to: client)
        let socket = try socket(0, recorder: recorder, client: client)
        accept(socket, client: client, created: created)
        return (client, socket)
    }

    private func tick(_ client: OpenAITranslateClient) {
        client.queue.sync { client.tick() }
        drain(client)
    }

    // MARK: Connecting only when there is sound

    func testStartingOpensNoConnection() {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)

        XCTAssertTrue(recorder.sockets.isEmpty)
        XCTAssertEqual(recorder.states, [.waitingForAudio])
        XCTAssertEqual(recorder.registry.openCount, 0)

        tick(client)
        XCTAssertTrue(recorder.sockets.isEmpty, "time passing does not connect either")
    }

    func testSilenceFromTheCaptureOpensNoConnectionAndIsNotBilled() {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)

        for _ in 0..<50 {
            send(Self.silence, to: client)
            recorder.advance(by: 0.2)
            tick(client)
        }

        XCTAssertTrue(recorder.sockets.isEmpty)
        XCTAssertEqual(recorder.streamedSeconds, 0)
        XCTAssertTrue(recorder.connectionEvents.isEmpty)
    }

    func testTheFirstSoundOpensTheConnectionAndIsSentWithTheMomentBeforeIt() throws {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)

        for _ in 0..<10 {
            send(Self.silence, to: client)
        }
        send(Self.sound, to: client)

        let socket = try socket(0, recorder: recorder, client: client)
        XCTAssertEqual(recorder.states, [.waitingForAudio, .reconnecting])
        XCTAssertEqual(recorder.registry.openCount, 1)
        XCTAssertEqual(recorder.connectionEvents, [.opened(.sessionStart)])
        XCTAssertTrue(socket.audioMessages.isEmpty, "nothing is sent before the session is configured")

        accept(socket, client: client)

        XCTAssertEqual(recorder.states, [.waitingForAudio, .reconnecting, .streaming])
        XCTAssertTrue(socket.sent[0].contains("session.update"))
        XCTAssertEqual(socket.audioMessages.count, 5, "one second kept: four silent chunks and the first sound")
        XCTAssertEqual(recorder.streamedSeconds, 1.0, accuracy: 0.0001)
    }

    func testAudioIsSentInCaptureOrderIn200MillisecondChunks() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        let alreadySent = socket.audioMessages.count

        client.appendSamples([Int16](repeating: 1, count: 3_000))
        client.appendSamples([Int16](repeating: 2, count: 3_000))
        client.appendSamples([Int16](repeating: 3, count: 3_600))
        drain(client)

        let chunks = try socket.audioMessages.dropFirst(alreadySent).map { message -> [UInt8] in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String])
            return Array(try XCTUnwrap(json["audio"].flatMap { Data(base64Encoded: $0) }))
        }

        XCTAssertEqual(chunks.map(\.count), [9_600, 9_600])
        XCTAssertEqual(chunks[0].first, 1)
        XCTAssertEqual(chunks[0].last, 0, "high byte of the sample 2")
        XCTAssertEqual(chunks[0][9_598], 2)
        XCTAssertEqual(chunks[1][9_598], 3)
    }

    func testTranscriptDeltasBecomeADraftAndThenASentence() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

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

    func testTranslatedAudioProducesNoOutputAtAll() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        let sentBefore = socket.sent.count

        socket.push(#"{"type":"session.output_audio.delta","delta":"AAAAAAAA","sample_rate":24000}"#)
        socket.push(#"{"type":"session.some_future_event"}"#)
        drain(client)

        XCTAssertTrue(recorder.outputs.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(socket.sent.count, sentBefore, "nothing is sent in response")
    }

    // MARK: Stopping

    func testStopClosesTheConnectionAtOnce() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        XCTAssertEqual(recorder.registry.openCount, 1)

        client.stop()
        drain(client)

        XCTAssertTrue(socket.isCancelled, "closed without waiting for the server")
        XCTAssertEqual(socket.sent.last, OpenAITranslateProtocol.sessionCloseMessage)
        XCTAssertEqual(recorder.registry.openCount, 0)
        XCTAssertEqual(recorder.connectionEvents.last, .closed(.stopped, audioSeconds: 0.2))

        send(Self.sound, to: client)
        tick(client)
        XCTAssertEqual(recorder.sockets.count, 1, "a stopped client never connects again")
        XCTAssertEqual(socket.audioMessages.count, 1, "and sends no more audio")
    }

    func testStopWhileConnectingClosesTheConnectionToo() throws {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)
        send(Self.sound, to: client)
        let socket = try socket(0, recorder: recorder, client: client)

        client.stop()
        drain(client)

        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
        XCTAssertTrue(recorder.failures.isEmpty, "stopping is not a failure")
    }

    func testAClientThatIsDroppedWithoutBeingStoppedLeavesNoConnection() throws {
        let recorder = Recorder()
        var client: OpenAITranslateClient? = waitingClient(recorder: recorder)
        send(Self.sound, to: client!)
        let socket = try socket(0, recorder: recorder, client: client!)
        XCTAssertEqual(recorder.registry.openCount, 1)

        client = nil

        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
    }

    func testTheRegistryCanCloseEveryConnectionWhoeverOwnsIt() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        let counts = CountLog()
        let observer = recorder.registry.observe { counts.append($0) }
        defer { recorder.registry.removeObserver(observer) }

        XCTAssertEqual(recorder.registry.closeAll(), 1)

        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
        XCTAssertEqual(counts.values, [0])
        XCTAssertEqual(recorder.registry.closeAll(), 0, "nothing left to close")
        client.stop()
        drain(client)
    }

    // MARK: Failures

    func testRejectedKeyIsReportedAsAFailure() throws {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)
        send(Self.sound, to: client)
        let socket = try socket(0, recorder: recorder, client: client)

        socket.handshakeStatusCode = 401
        socket.fail()
        drain(client)

        XCTAssertEqual(recorder.failures, [.authenticationFailed])
        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
    }

    /// OpenAI accepts the connection and then refuses an invalid key with this event.
    func testInvalidKeyErrorEventIsReportedAsARejectedKey() throws {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)
        send(Self.sound, to: client)
        let socket = try socket(0, recorder: recorder, client: client)

        socket.handshakeStatusCode = 101
        socket.push(
            #"{"type":"error","event_id":"event_1","error":{"type":"invalid_request_error","code":"invalid_api_key","message":"Incorrect API key provided.","param":null,"event_id":null}}"#
        )
        drain(client)

        XCTAssertEqual(recorder.failures, [.authenticationFailed])
        XCTAssertTrue(socket.isCancelled)
    }

    func testUnreachableServerIsReportedAsAFailure() throws {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)
        send(Self.sound, to: client)
        let socket = try socket(0, recorder: recorder, client: client)

        socket.fail()
        drain(client)

        XCTAssertEqual(recorder.failures, [.connectionFailed])
    }

    func testErrorBeforeTheSessionIsConfiguredIsReportedAsAFailure() throws {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)
        send(Self.sound, to: client)
        let socket = try socket(0, recorder: recorder, client: client)

        socket.push(Self.created)
        drain(client)
        socket.push(#"{"type":"error","error":{"type":"invalid_request_error","message":"Unsupported language"}}"#)
        drain(client)

        XCTAssertEqual(recorder.failures, [.rejected("Unsupported language")])
    }

    func testErrorWhileStreamingKeepsTheSessionOpen() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        let sentBefore = socket.audioMessages.count

        socket.push(#"{"type":"error","error":{"type":"invalid_request_error","message":"Bad event"}}"#)
        drain(client)
        send(Self.sound, to: client)

        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(socket.audioMessages.count, sentBefore + 1)
    }

    func testDroppedConnectionIsReportedOnceAndNotRetried() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        let sentBefore = socket.audioMessages.count

        socket.fail()
        drain(client)
        tick(client)
        send(Self.sound, to: client)

        XCTAssertEqual(recorder.failures, [.connectionLost])
        XCTAssertEqual(recorder.sockets.count, 1, "no reconnect loop")
        XCTAssertEqual(socket.audioMessages.count, sentBefore)
        XCTAssertEqual(recorder.registry.openCount, 0)
    }

    // MARK: Silence

    func testSilenceIsSentWhenTheCaptureStallsBriefly() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        let sentBefore = socket.audioMessages.count

        recorder.advance(by: 0.2)
        tick(client)
        XCTAssertEqual(socket.audioMessages.count, sentBefore, "a short gap is not a stall")

        recorder.advance(by: 0.3)
        tick(client)

        XCTAssertEqual(socket.audioMessages.count, sentBefore + 1)
        XCTAssertEqual(
            socket.audioMessages.last,
            OpenAITranslateProtocol.appendAudioMessage(
                pcm16: PCM16Encoding.littleEndianData(from: PCM16Chunker.silentChunk())
            )
        )
    }

    func testTwentySecondsOfSilenceCloseTheConnectionAndSoundReopensIt() throws {
        let recorder = Recorder()
        let (client, firstSocket) = try streamingClient(recorder: recorder)

        // 19 s of silence from the capture: still connected.
        for _ in 0..<95 {
            recorder.advance(by: 0.2)
            send(Self.silence, to: client)
            tick(client)
        }
        XCTAssertEqual(recorder.states.last, .streaming)
        XCTAssertFalse(firstSocket.isCancelled)

        for _ in 0..<6 {
            recorder.advance(by: 0.2)
            send(Self.silence, to: client)
            tick(client)
        }

        XCTAssertEqual(recorder.states.last, .waitingForAudio)
        XCTAssertTrue(firstSocket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
        guard case .closed(.noAudio, _)? = recorder.connectionEvents.last else {
            return XCTFail("expected the connection to be closed for silence, got \(recorder.connectionEvents)")
        }

        // Silence after that is neither sent nor counted.
        let billedBefore = recorder.streamedSeconds
        for _ in 0..<50 {
            recorder.advance(by: 0.2)
            send(Self.silence, to: client)
            tick(client)
        }
        XCTAssertEqual(recorder.streamedSeconds, billedBefore)
        XCTAssertEqual(recorder.sockets.count, 1)

        send(Self.sound, to: client)
        let secondSocket = try socket(1, recorder: recorder, client: client)
        accept(secondSocket, client: client)

        XCTAssertEqual(recorder.states.suffix(3), [.waitingForAudio, .reconnecting, .streaming])
        XCTAssertEqual(recorder.connectionEvents.last, .opened(.audioReturned))
        XCTAssertEqual(secondSocket.audioMessages.count, 5, "one second of pre-roll is replayed")
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    func testSoundKeepsTheConnectionOpenPastTwentySeconds() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        for _ in 0..<150 {
            recorder.advance(by: 0.2)
            send(Self.sound, to: client)
            tick(client)
        }

        XCTAssertEqual(recorder.states.last, .streaming)
        XCTAssertFalse(socket.isCancelled)
    }

    func testACaptureReportedAsSilentClosesTheConnectionImmediately() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        client.noteCaptureSilent()
        drain(client)

        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(recorder.states.last, .waitingForAudio)
        XCTAssertEqual(recorder.registry.openCount, 0)
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    // MARK: Idle pause

    /// Sound with no speech in it, such as music, for the given time.
    private func playSoundWithoutSpeech(for seconds: TimeInterval, client: OpenAITranslateClient, recorder: Recorder) {
        for _ in 0..<Int(seconds) {
            recorder.advance(by: 1)
            send(Self.sound, to: client)
            tick(client)
        }
    }

    func testThreeMinutesWithoutSpeechPausesAndSpeechDoesNotResumeByItself() throws {
        let recorder = Recorder()
        let (client, firstSocket) = try streamingClient(recorder: recorder)

        playSoundWithoutSpeech(for: 179, client: client, recorder: recorder)
        XCTAssertEqual(recorder.states.last, .streaming, "not idle long enough")

        playSoundWithoutSpeech(for: 2, client: client, recorder: recorder)

        XCTAssertEqual(recorder.states.last, .pausedNoAudio)
        XCTAssertTrue(firstSocket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
        let billedBeforePause = recorder.streamedSeconds

        // A video that starts playing by itself: speech, sound, time passing.
        for _ in 0..<20 {
            recorder.advance(by: 1)
            client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
            send(Self.sound, to: client)
            tick(client)
        }

        XCTAssertEqual(recorder.sockets.count, 1, "no new connection, so no new billing")
        XCTAssertEqual(recorder.states.last, .pausedNoAudio)
        XCTAssertEqual(recorder.streamedSeconds, billedBeforePause)
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    func testAPausedSessionCarriesOnWhenTheUserResumesIt() throws {
        let recorder = Recorder()
        let (client, _) = try pausedClient(recorder: recorder)

        client.resume()
        drain(client)
        XCTAssertEqual(recorder.states.last, .waitingForAudio)
        XCTAssertEqual(recorder.sockets.count, 1, "resuming alone does not connect: there is nothing to send yet")

        send(Self.sound, to: client)
        let secondSocket = try socket(1, recorder: recorder, client: client)
        accept(secondSocket, client: client)

        XCTAssertEqual(recorder.states.last, .streaming)
        XCTAssertEqual(recorder.connectionEvents.suffix(1), [.opened(.manualResume)])
    }

    func testWithAutomaticResumeSwitchedOnSpeechReopensTheConnection() throws {
        let recorder = Recorder()
        let (client, _) = try pausedClient(recorder: recorder) { $0.resumesAutomatically = true }

        for _ in 0..<8 {
            send(Self.sound, to: client)
        }
        XCTAssertEqual(recorder.sockets.count, 1, "sound alone is not speech")

        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        let secondSocket = try socket(1, recorder: recorder, client: client)
        accept(secondSocket, client: client)

        XCTAssertEqual(recorder.states.suffix(3), [.pausedNoAudio, .reconnecting, .streaming])
        XCTAssertEqual(recorder.connectionEvents.last, .opened(.automaticResume))
        XCTAssertEqual(secondSocket.audioMessages.count, 5, "one second of pre-roll is replayed")
    }

    func testNoSoundForThreeMinutesAfterStartingPausesWithoutEverConnecting() {
        let recorder = Recorder()
        let client = waitingClient(recorder: recorder)

        recorder.advance(by: 181)
        send(Self.silence, to: client)
        tick(client)

        XCTAssertEqual(recorder.states, [.waitingForAudio, .pausedNoAudio])
        XCTAssertTrue(recorder.sockets.isEmpty)

        send(Self.sound, to: client)
        tick(client)
        XCTAssertTrue(recorder.sockets.isEmpty, "sound much later does not open a forgotten session")
    }

    private func pausedClient(
        recorder: Recorder,
        configure: (inout OpenAITranslateClient.Configuration) -> Void = { _ in }
    ) throws -> (OpenAITranslateClient, FakeTranslateSocket) {
        let (client, socket) = try streamingClient(recorder: recorder, configure: configure)
        playSoundWithoutSpeech(for: 181, client: client, recorder: recorder)
        XCTAssertEqual(recorder.states.last, .pausedNoAudio)
        return (client, socket)
    }

    func testFifteenMinutesPausedStopsTheSessionForGood() throws {
        let recorder = Recorder()
        let (client, _) = try pausedClient(recorder: recorder)

        // The pause began one second before `pausedClient` returned.
        recorder.advance(by: 898)
        tick(client)
        XCTAssertEqual(recorder.states.last, .pausedNoAudio, "not paused long enough")

        recorder.advance(by: 2)
        tick(client)
        XCTAssertEqual(recorder.states.last, .stoppedAfterLongPause)

        // Nothing reopens the connection after that, not even a resume.
        client.resume()
        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        send(Self.sound, to: client)
        tick(client)

        XCTAssertEqual(recorder.sockets.count, 1)
        XCTAssertEqual(recorder.states.last, .stoppedAfterLongPause)
        XCTAssertTrue(recorder.failures.isEmpty, "stopping is not a failure, so nothing falls back")
    }

    func testSpeechRightAfterTheMacWakesFromALongSleepStopsInsteadOfResuming() throws {
        let recorder = Recorder()
        let (client, _) = try pausedClient(recorder: recorder) { $0.resumesAutomatically = true }

        // Lid closed for eight hours, then audio arrives before the next timer tick.
        recorder.sleepMac(for: 8 * 3_600)
        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        drain(client)

        XCTAssertEqual(recorder.states.last, .stoppedAfterLongPause)
        XCTAssertEqual(recorder.sockets.count, 1, "no new connection, so no new billing")
    }

    func testWithoutAVoiceDetectorAudibleAudioCountsAsActivity() throws {
        let recorder = Recorder()
        let (client, _) = try streamingClient(recorder: recorder) { $0.hasVoiceActivitySignal = false }

        playSoundWithoutSpeech(for: 185, client: client, recorder: recorder)

        XCTAssertEqual(recorder.states.last, .streaming, "audible audio keeps the session open")
    }

    // MARK: Session time limit

    func testSessionCloseToExpiryIsReplacedAtAPause() throws {
        let recorder = Recorder()
        let expiresAt = recorder.wallNow.timeIntervalSince1970 + 600
        let created = #"{"type":"session.created","session":{"id":"sess_1","expires_at":\#(expiresAt)}}"#
        let (client, firstSocket) = try streamingClient(recorder: recorder, created: created)

        recorder.advance(by: 100)
        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        send(Self.sound, to: client)
        tick(client)
        XCTAssertEqual(recorder.sockets.count, 1, "plenty of time left")

        recorder.advance(by: 420)
        client.noteVoiceActivity(isSpeaking: true, onset: false, offset: false)
        send(Self.sound, to: client)
        tick(client)
        XCTAssertEqual(recorder.sockets.count, 1, "80 s left, but someone is speaking")

        client.noteVoiceActivity(isSpeaking: false, onset: false, offset: true)
        send(Self.sound, to: client)
        tick(client)

        let secondSocket = try socket(1, recorder: recorder, client: client)
        XCTAssertTrue(firstSocket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 1, "the old connection is gone before the new one counts")

        // Audio captured while the replacement opens is queued, then sent.
        client.appendSamples([Int16](repeating: 2_000, count: 9_600))
        drain(client)
        XCTAssertTrue(secondSocket.audioMessages.isEmpty)
        accept(secondSocket, client: client)

        XCTAssertEqual(secondSocket.audioMessages.count, 2)
        XCTAssertEqual(recorder.connectionEvents.last, .opened(.renewal))
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    func testSessionAtItsDeadlineIsReplacedEvenMidSpeech() throws {
        let recorder = Recorder()
        let expiresAt = recorder.wallNow.timeIntervalSince1970 + 600
        let created = #"{"type":"session.created","session":{"id":"sess_1","expires_at":\#(expiresAt)}}"#
        let (client, _) = try streamingClient(recorder: recorder, created: created)

        client.noteVoiceActivity(isSpeaking: true, onset: true, offset: false)
        recorder.advance(by: 590)
        client.noteVoiceActivity(isSpeaking: true, onset: false, offset: false)
        send(Self.sound, to: client)
        tick(client)

        XCTAssertEqual(recorder.sockets.count, 2)
    }

    // MARK: Source transcription (the second, separately billed model)

    private func transcriptionSetting(in message: String) throws -> Any? {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        return input["transcription"]
    }

    func testWithTheOriginalLineOnTheSourceIsTranscribedAndCountedForBothModels() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        let setting = try XCTUnwrap(transcriptionSetting(in: socket.sent[0]) as? [String: Any])
        XCTAssertEqual(setting["model"] as? String, "gpt-realtime-whisper")

        send(Self.sound, to: client)
        XCTAssertEqual(recorder.streamedSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(recorder.transcribedSeconds, 0.4, accuracy: 0.0001)
    }

    func testWithTheOriginalLineOffNoTranscriptionIsRequestedOrCounted() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder) { $0.transcribesSource = false }

        XCTAssertTrue(try transcriptionSetting(in: socket.sent[0]) is NSNull, "transcription is switched off explicitly")

        send(Self.sound, to: client)
        XCTAssertEqual(recorder.streamedSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(recorder.transcribedSeconds, 0, "the second model is not billed")

        // Source text the server sends anyway is not shown.
        socket.push(#"{"type":"session.input_transcript.delta","delta":"Das passt."}"#)
        socket.push(#"{"type":"session.output_transcript.delta","delta":"That works."}"#)
        drain(client)
        client.noteVoiceActivity(isSpeaking: false, onset: false, offset: true)
        drain(client)
        recorder.advance(by: 1)
        tick(client)

        XCTAssertEqual(recorder.sentences.map(\.translatedText), ["That works."])
        XCTAssertEqual(recorder.sentences.map(\.sourceText), ["That works."], "no German: the translation stands alone")
    }

    func testSwitchingTheOriginalLineMidSessionReconfiguresTheSessionAndTheCount() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)
        XCTAssertEqual(recorder.transcribedSeconds, 0.2, accuracy: 0.0001)

        client.setSourceTranscription(false)
        drain(client)

        let update = try XCTUnwrap(socket.sent.last)
        XCTAssertTrue(update.contains("session.update"))
        XCTAssertTrue(try transcriptionSetting(in: update) is NSNull)

        send(Self.sound, to: client)
        XCTAssertEqual(recorder.streamedSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(recorder.transcribedSeconds, 0.2, accuracy: 0.0001, "no longer counted")

        client.setSourceTranscription(true)
        drain(client)
        XCTAssertNotNil(try transcriptionSetting(in: XCTUnwrap(socket.sent.last)) as? [String: Any])

        send(Self.sound, to: client)
        XCTAssertEqual(recorder.transcribedSeconds, 0.4, accuracy: 0.0001)
    }

    func testAReconnectUsesTheCurrentTranscriptionSetting() throws {
        let recorder = Recorder()
        let (client, _) = try streamingClient(recorder: recorder)
        client.setSourceTranscription(false)
        client.noteCaptureSilent()
        drain(client)

        send(Self.sound, to: client)
        let secondSocket = try socket(1, recorder: recorder, client: client)
        accept(secondSocket, client: client)

        XCTAssertTrue(try transcriptionSetting(in: secondSocket.sent[0]) is NSNull)
    }

    // MARK: Connection log

    func testEveryConnectionIsLoggedWithItsReasonAndTheAudioItCarried() throws {
        let recorder = Recorder()
        let (client, _) = try streamingClient(recorder: recorder)
        send(Self.sound, to: client)
        send(Self.sound, to: client)

        client.stop()
        drain(client)

        XCTAssertEqual(recorder.connectionEvents.count, 2)
        XCTAssertEqual(recorder.connectionEvents[0], .opened(.sessionStart))
        guard case .closed(.stopped, let audioSeconds) = recorder.connectionEvents[1] else {
            return XCTFail("expected a close, got \(recorder.connectionEvents[1])")
        }
        XCTAssertEqual(audioSeconds, 0.6, accuracy: 0.0001)
        XCTAssertEqual(recorder.streamedSeconds, 0.6, accuracy: 0.0001, "the usage record agrees")
    }
}

/// The same client with Soniox's wire format: configuration up front, binary audio,
/// provisional tokens, errors that end the connection.
final class SonioxClientTests: XCTestCase {
    private static let sound = [Int16](repeating: 2_000, count: 4_800)

    private func makeClient(recorder: Recorder, glossary: [String: String] = [:]) -> OpenAITranslateClient {
        var configuration = OpenAITranslateClient.Configuration(targetLanguageCode: "en")
        configuration.wire = SonioxWire(sourceLanguageCode: "de", targetLanguageCode: "en", glossary: glossary)
        configuration.runsTimer = false
        configuration.usageReportChunkCount = 1

        var handlers = OpenAITranslateClient.Handlers()
        handlers.outputs = { recorder.add(outputs: $0) }
        handlers.stateChanged = { recorder.add(state: $0) }
        handlers.failed = { recorder.add(failure: $0) }
        handlers.streamedAudio = { recorder.add(seconds: $0, transcribed: $1) }
        handlers.connectionEvent = { recorder.add(event: $0) }

        return OpenAITranslateClient(
            apiKey: "soniox-test-key",
            configuration: configuration,
            handlers: handlers,
            makeSocket: { _ in
                let socket = FakeTranslateSocket()
                recorder.addSocket(socket)
                return socket
            },
            registry: recorder.registry,
            clock: { recorder.now },
            wallClock: { recorder.wallNow }
        )
    }

    private func drain(_ client: OpenAITranslateClient) {
        for _ in 0..<3 {
            client.queue.sync {}
        }
    }

    private func tick(_ client: OpenAITranslateClient) {
        client.queue.sync { client.tick() }
        drain(client)
    }

    private func streamingClient(recorder: Recorder) throws -> (OpenAITranslateClient, FakeTranslateSocket) {
        let client = makeClient(recorder: recorder)
        client.start()
        drain(client)
        XCTAssertTrue(recorder.sockets.isEmpty, "no connection before there is sound")
        client.appendSamples(Self.sound)
        drain(client)
        return (client, try XCTUnwrap(recorder.sockets.first))
    }

    private var lastDraft: (Recorder) -> TranslateDeltaAssembler.Draft? {
        { recorder in
            for output in recorder.outputs.reversed() {
                if case .draft(let draft) = output { return draft }
            }
            return nil
        }
    }

    func testTheFirstSoundConnectsSendsTheConfigurationThenBinaryAudio() throws {
        let recorder = Recorder()
        // Held on to: a client that is dropped closes its connection.
        let (client, socket) = try streamingClient(recorder: recorder)
        defer { client.stop() }

        XCTAssertEqual(socket.sent.count, 1, "the configuration, as text")
        XCTAssertTrue(socket.sent[0].contains(#""model":"stt-rt-v5""#))
        XCTAssertEqual(socket.sentData.count, 1, "the audio follows at once, as binary")
        XCTAssertEqual(socket.sentData[0].count, 9_600)
        XCTAssertEqual(recorder.states, [.waitingForAudio, .reconnecting, .streaming])
        XCTAssertEqual(recorder.connectionEvents, [.opened(.sessionStart)])
        XCTAssertEqual(recorder.registry.openCount, 1)
    }

    func testProvisionalWordsShowAtOnceAndAreReplacedUntilFinal() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        socket.push(#"{"tokens":[{"text":"Das","is_final":false,"translation_status":"original"},{"text":" past","is_final":false,"translation_status":"original"}]}"#)
        drain(client)
        XCTAssertEqual(lastDraft(recorder)?.sourceText, "Das past")

        // The engine changes its mind about the second word and starts translating.
        socket.push(#"{"tokens":[{"text":"Das","is_final":true,"translation_status":"original"},{"text":" passt.","is_final":false,"translation_status":"original"},{"text":"That","is_final":false,"translation_status":"translation"}]}"#)
        drain(client)
        XCTAssertEqual(lastDraft(recorder)?.sourceText, "Das passt.")
        XCTAssertEqual(lastDraft(recorder)?.translatedText, "That")
        XCTAssertTrue(recorder.sentences.isEmpty)

        socket.push(#"{"tokens":[{"text":" passt.","is_final":true,"translation_status":"original"},{"text":"That works.","is_final":true,"translation_status":"translation"},{"text":"<end>","is_final":true}]}"#)
        drain(client)
        recorder.advance(by: 1.5)
        tick(client)

        XCTAssertEqual(recorder.sentences.map(\.sourceText), ["Das passt."])
        XCTAssertEqual(recorder.sentences.map(\.translatedText), ["That works."])
    }

    func testARejectedKeyEndsTheSessionAsAnAuthenticationFailure() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        socket.push(#"{"error_code":401,"error_type":"unauthorized","error_message":"Invalid API key."}"#)
        drain(client)

        XCTAssertEqual(recorder.failures, [.authenticationFailed])
        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
    }

    func testAnEmptyBalanceIsReportedLikeARejectedKeyNotRetried() throws {
        let recorder = Recorder()
        let (client, _) = try streamingClient(recorder: recorder)

        recorder.sockets[0].push(#"{"error_code":402,"error_type":"balance_exhausted","error_message":"No balance."}"#)
        drain(client)
        client.appendSamples(Self.sound)
        drain(client)

        XCTAssertEqual(recorder.failures, [.authenticationFailed])
        XCTAssertEqual(recorder.sockets.count, 1, "no reconnect")
    }

    func testAServerErrorEndsTheSessionSoTheAppCanFallBack() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        socket.push(#"{"error_code":500,"error_type":"internal_error","error_message":"Try again."}"#)
        drain(client)

        XCTAssertEqual(recorder.failures, [.rejected("Try again.")])
        XCTAssertTrue(socket.isCancelled)
    }

    func testReachingTheConnectionLimitOpensANewConnectionInsteadOfFailing() throws {
        let recorder = Recorder()
        let (client, firstSocket) = try streamingClient(recorder: recorder)

        firstSocket.push(#"{"error_code":413,"error_type":"max_duration_reached","error_message":"Limit."}"#)
        drain(client)

        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertTrue(firstSocket.isCancelled)
        XCTAssertEqual(recorder.sockets.count, 2)
        XCTAssertEqual(recorder.connectionEvents.last, .opened(.renewal))
        XCTAssertEqual(recorder.registry.openCount, 1)
    }

    func testStopEndsTheStreamAndClosesTheConnectionAtOnce() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        client.stop()
        drain(client)

        XCTAssertEqual(socket.sent.last, "", "an empty text frame ends a Soniox stream")
        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(recorder.registry.openCount, 0)
    }

    func testTheSameSilenceAndPauseRulesApply() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        for _ in 0..<105 {
            recorder.advance(by: 0.2)
            client.appendSamples([Int16](repeating: 0, count: 4_800))
            drain(client)
            tick(client)
        }

        XCTAssertTrue(socket.isCancelled, "20 seconds of silence close the connection: Soniox bills while it is open")
        XCTAssertEqual(recorder.states.last, .waitingForAudio)
    }

    func testThereIsNoSecondModelToCountOrSwitchOff() throws {
        let recorder = Recorder()
        let (client, socket) = try streamingClient(recorder: recorder)

        client.setSourceTranscription(false)
        drain(client)
        client.appendSamples(Self.sound)
        drain(client)

        XCTAssertEqual(socket.sent.count, 1, "nothing is reconfigured")
        XCTAssertEqual(recorder.streamedSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(recorder.transcribedSeconds, 0)
    }
}

/// Soniox for meetings: speakers, no translation, and silence that does not close.
final class SonioxMeetingClientTests: XCTestCase {
    private static let sound = [Int16](repeating: 2_000, count: 4_800)
    private static let silence = [Int16](repeating: 0, count: 4_800)

    private final class Tokens: @unchecked Sendable {
        private let lock = NSLock()
        private var _received: [(final: [SpeakerToken], offset: TimeInterval)] = []
        var received: [(final: [SpeakerToken], offset: TimeInterval)] { lock.withLock { _received } }
        func add(_ final: [SpeakerToken], _ offset: TimeInterval) { lock.withLock { _received.append((final, offset)) } }
    }

    private func makeClient(recorder: Recorder, tokens: Tokens) -> OpenAITranslateClient {
        var configuration = SonioxMeetingRecognizer.configuration(languageCode: "de", resumesAutomatically: false)
        configuration.runsTimer = false
        var handlers = OpenAITranslateClient.Handlers()
        handlers.stateChanged = { recorder.add(state: $0) }
        handlers.connectionEvent = { recorder.add(event: $0) }
        handlers.speakerTokens = { final, _, offset in tokens.add(final, offset) }
        return OpenAITranslateClient(
            apiKey: "soniox-test-key",
            configuration: configuration,
            handlers: handlers,
            makeSocket: { _ in
                let socket = FakeTranslateSocket()
                recorder.addSocket(socket)
                return socket
            },
            registry: recorder.registry,
            clock: { recorder.now },
            wallClock: { recorder.wallNow }
        )
    }

    private func drain(_ client: OpenAITranslateClient) {
        for _ in 0..<3 { client.queue.sync {} }
    }

    func testTheMeetingConfigurationAsksForSpeakersWithoutTranslationOrEndpoints() throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, tokens: Tokens())
        client.start()
        client.appendSamples(Self.sound)
        drain(client)

        let opening = try XCTUnwrap(recorder.sockets.first?.sent.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(opening.utf8)) as? [String: Any])
        XCTAssertEqual(json["enable_speaker_diarization"] as? Bool, true)
        XCTAssertEqual(json["enable_endpoint_detection"] as? Bool, false)
        XCTAssertNil(json["translation"])
        XCTAssertEqual(json["language_hints"] as? [String], ["de"])
        client.stop()
        drain(client)
    }

    func testSpeakerTokensArriveWithTheConnectionsPlaceInTheMeeting() throws {
        let recorder = Recorder()
        let tokens = Tokens()
        let client = makeClient(recorder: recorder, tokens: tokens)
        client.start()
        drain(client)
        recorder.advance(by: 5)
        client.appendSamples(Self.sound)
        drain(client)
        let socket = try XCTUnwrap(recorder.sockets.first)

        socket.push(#"{"tokens":[{"text":"Hal","is_final":true,"speaker":"1","start_ms":100,"end_ms":300},{"text":"lo","is_final":true,"speaker":"1","start_ms":300,"end_ms":500}]}"#)
        drain(client)

        let first = try XCTUnwrap(tokens.received.first)
        XCTAssertEqual(first.final.map(\.text), ["Hal", "lo"])
        XCTAssertEqual(first.final.first?.speaker, "1")
        XCTAssertEqual(first.offset, 4.8, accuracy: 0.01, "five seconds in, minus the 0.2 s of audio queued while connecting")
        client.stop()
        drain(client)
    }

    func testSilenceKeepsTheConnectionButThreeMinutesWithoutSpeechPauseIt() throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, tokens: Tokens())
        client.start()
        client.appendSamples(Self.sound)
        drain(client)

        for _ in 0..<150 {
            recorder.advance(by: 0.2)
            client.appendSamples(Self.silence)
            client.queue.sync { client.tick() }
        }
        drain(client)
        XCTAssertFalse(recorder.connectionEvents.contains { if case .closed = $0 { return true }; return false },
                       "30 s of silence: still connected, so speaker numbers stay")

        for _ in 0..<800 {
            recorder.advance(by: 0.2)
            client.appendSamples(Self.silence)
            client.queue.sync { client.tick() }
        }
        drain(client)
        XCTAssertTrue(recorder.connectionEvents.contains { if case .closed(.idlePause, _) = $0 { return true }; return false })
        XCTAssertEqual(recorder.states.last, .pausedNoAudio)
        client.stop()
        drain(client)
    }
}
