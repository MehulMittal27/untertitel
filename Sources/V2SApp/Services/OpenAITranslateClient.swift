import Foundation
import os.log

private extension Logger {
    static let cloudEngine = Logger(subsystem: "com.franklioxygen.v2s", category: "cloudEngine")
}

/// The WebSocket the client talks through. A protocol so tests can script the server.
protocol OpenAITranslateSocket: AnyObject, Sendable {
    /// HTTP status of the handshake response, once there is one.
    var handshakeStatusCode: Int? { get }
    func resume()
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    func receive(completion: @escaping @Sendable (Result<String, Error>) -> Void)
    func cancel()
}

final class URLSessionTranslateSocket: OpenAITranslateSocket, Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
    }

    var handshakeStatusCode: Int? {
        (task.response as? HTTPURLResponse)?.statusCode
    }

    func resume() {
        task.resume()
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    func receive(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .success(.string(let text)):
                completion(.success(text))
            case .success(.data(let data)):
                completion(.success(String(decoding: data, as: UTF8.self)))
            case .success:
                completion(.success(""))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Why the cloud engine gave up. Each one ends the cloud session; the owner falls back
/// to the on-device engine.
enum CloudEngineFailure: Error, Equatable, Sendable {
    case missingAPIKey
    case authenticationFailed
    case connectionFailed
    case connectionLost
    case rejected(String)
}

enum CloudEngineState: Equatable, Sendable {
    case streaming
    /// The connection was closed to stop billing while the source is silent. It reopens
    /// by itself when audio returns.
    case pausedNoAudio
    case reconnecting
}

/// Streams captured audio to OpenAI's realtime translation endpoint and turns the
/// transcript deltas into drafts and sentences. Text only: translated audio events are
/// dropped unread, and nothing here can play sound.
///
/// All state lives on `queue`. Handlers are called on that queue.
final class OpenAITranslateClient: @unchecked Sendable {
    struct Configuration {
        var targetLanguageCode: String
        /// False when no voice activity detector feeds `noteVoiceActivity`. Activity is
        /// then judged from the audio level.
        var hasVoiceActivitySignal = true
        var connectTimeout: TimeInterval = 10
        /// How long a closing session may take to drain before its socket is dropped.
        var closeTimeout: TimeInterval = 1
        /// Cost guardrail: close the connection after this long without speech.
        var idlePauseInterval: TimeInterval = 180
        /// Audio kept while paused and replayed on resume, so the first words survive.
        var prerollChunkCount = 5
        /// Audio buffered while a connection is being opened. Older audio is dropped.
        var maximumQueuedChunkCount = 50
        /// Reconnect at the next pause once the session is this close to expiring.
        var rolloverLeadTime: TimeInterval = 90
        /// Reconnect regardless of speech once the session is this close to expiring.
        var rolloverDeadline: TimeInterval = 15
        /// The engine treats resumed audio as contiguous, so gaps are filled with silence.
        var silenceFillThreshold: TimeInterval = 0.4
        /// Peak level that counts as activity when there is no voice activity detector.
        var activityPeakThreshold: Float = 0.003
        var usageReportChunkCount = 25
        var runsTimer = true
    }

    struct Handlers {
        var outputs: ([TranslateDeltaAssembler.Output]) -> Void = { _ in }
        var stateChanged: (CloudEngineState) -> Void = { _ in }
        var failed: (CloudEngineFailure) -> Void = { _ in }
        /// Seconds of audio sent since the last report. Billing follows audio duration.
        var streamedAudio: (TimeInterval) -> Void = { _ in }
    }

    private enum Phase: Equatable {
        case idle
        case connecting
        case streaming
        case paused
        case finished
    }

    let queue: DispatchQueue
    private let apiKey: String
    private let configuration: Configuration
    private let handlers: Handlers
    private let makeSocket: (URLRequest) -> OpenAITranslateSocket
    private let clock: () -> TimeInterval
    private let wallClock: () -> Date

    private var phase: Phase = .idle
    private var socket: OpenAITranslateSocket?
    /// Identifies the current socket. Callbacks from an earlier one are ignored.
    private var socketGeneration = 0
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutWork: DispatchWorkItem?
    private var timer: DispatchSourceTimer?

    private var assembler: TranslateDeltaAssembler
    private var chunker = PCM16Chunker()
    private var queuedChunks: [[Int16]] = []
    private var prerollChunks: [[Int16]] = []
    private var sessionExpiresAt: Date?
    private var isSpeaking = false
    private var lastVoiceActivityAt: TimeInterval = 0
    private var lastCaptureAt: TimeInterval = 0
    private var unreportedChunkCount = 0

    init(
        apiKey: String,
        configuration: Configuration,
        handlers: Handlers,
        queue: DispatchQueue = DispatchQueue(label: "com.franklioxygen.v2s.cloudEngine", qos: .userInitiated),
        makeSocket: @escaping (URLRequest) -> OpenAITranslateSocket = { URLSessionTranslateSocket(request: $0) },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping () -> Date = { Date() }
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.handlers = handlers
        self.queue = queue
        self.makeSocket = makeSocket
        self.clock = clock
        self.wallClock = wallClock
        self.assembler = TranslateDeltaAssembler(hasVoiceActivitySignal: configuration.hasVoiceActivitySignal)
    }

    // MARK: Public interface (any thread)

    /// Opens the session. Returns once the server has accepted the configuration.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard phase == .idle else {
                    continuation.resume(throwing: CloudEngineFailure.connectionFailed)
                    return
                }

                let now = clock()
                lastVoiceActivityAt = now
                lastCaptureAt = now
                startContinuation = continuation
                beginConnect()
                startTimerIfNeeded()
            }
        }
    }

    /// 24 kHz mono PCM16 samples, in capture order.
    func appendSamples(_ samples: [Int16]) {
        guard samples.isEmpty == false else { return }
        queue.async { [self] in
            handleSamples(samples)
        }
    }

    func noteVoiceActivity(isSpeaking: Bool, onset: Bool, offset: Bool) {
        queue.async { [self] in
            handleVoiceActivity(isSpeaking: isSpeaking, onset: onset, offset: offset)
        }
    }

    /// Ends the session. The server gets a moment to drain, but nothing waits for it.
    func stop() {
        queue.async { [self] in
            finish()
        }
    }

    // MARK: Connection

    private func beginConnect() {
        phase = .connecting
        sessionExpiresAt = nil
        socketGeneration &+= 1
        let generation = socketGeneration

        let newSocket = makeSocket(OpenAITranslateProtocol.makeRequest(apiKey: apiKey))
        socket = newSocket
        newSocket.resume()
        receiveNext(on: newSocket, generation: generation)

        connectTimeoutWork?.cancel()
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self, self.socketGeneration == generation, self.phase == .connecting else { return }
            self.fail(.connectionFailed)
        }
        connectTimeoutWork = timeoutWork
        queue.asyncAfter(deadline: .now() + configuration.connectTimeout, execute: timeoutWork)
    }

    private func receiveNext(on socket: OpenAITranslateSocket, generation: Int) {
        socket.receive { [weak self, weak socket] result in
            guard let self else { return }
            self.queue.async {
                guard self.socketGeneration == generation, let socket else { return }

                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    // Handling the message may have replaced or closed this socket.
                    if self.socketGeneration == generation {
                        self.receiveNext(on: socket, generation: generation)
                    }
                case .failure:
                    self.handleSocketFailure(statusCode: socket.handshakeStatusCode)
                }
            }
        }
    }

    private func handleMessage(_ message: String) {
        guard let event = OpenAITranslateServerEvent.decode(message) else {
            return
        }

        let now = clock()
        switch event {
        case .sessionCreated(let expiresAt):
            sessionExpiresAt = expiresAt
            send(OpenAITranslateProtocol.sessionUpdateMessage(targetLanguageCode: configuration.targetLanguageCode))
        case .sessionUpdated:
            guard phase == .connecting else { return }
            didConnect()
        case .sessionClosed:
            handleSocketFailure(statusCode: nil)
        case .inputTranscriptDelta(let delta, _):
            guard phase == .streaming else { return }
            emit(assembler.appendSource(delta, at: now))
        case .outputTranscriptDelta(let delta, _):
            guard phase == .streaming else { return }
            emit(assembler.appendTranslation(delta, at: now))
        case .outputAudioDiscarded:
            // Text only. The translated speech is never decoded, stored, or played.
            break
        case .error(let serverError):
            Logger.cloudEngine.error(
                "Cloud engine error: \(serverError.type, privacy: .public) \(serverError.code ?? "-", privacy: .public)"
            )
            // Before the session is configured an error means it never will be. Later
            // ones are recoverable: the session stays open.
            if phase == .connecting {
                let isAuthenticationError = serverError.type == "authentication_error"
                    || serverError.code == "invalid_api_key"
                fail(isAuthenticationError ? .authenticationFailed : .rejected(serverError.message))
            }
        case .unknown(let type):
            #if DEBUG
            Logger.cloudEngine.debug("Ignoring cloud engine event: \(type, privacy: .public)")
            #else
            _ = type
            #endif
        }
    }

    private func didConnect() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        phase = .streaming
        lastVoiceActivityAt = clock()

        let backlog = queuedChunks
        queuedChunks.removeAll()
        for chunk in backlog {
            sendChunk(chunk)
        }

        handlers.stateChanged(.streaming)
        startContinuation?.resume()
        startContinuation = nil
    }

    /// The socket failed or the server closed the session.
    private func handleSocketFailure(statusCode: Int?) {
        switch phase {
        case .connecting:
            fail(statusCode == 401 || statusCode == 403 ? .authenticationFailed : .connectionFailed)
        case .streaming:
            // A session that ran out its time is replaced, not treated as a failure.
            if let sessionExpiresAt,
               sessionExpiresAt.timeIntervalSince(wallClock()) <= configuration.rolloverLeadTime {
                rollOver()
            } else {
                fail(.connectionLost)
            }
        case .idle, .paused, .finished:
            break
        }
    }

    private func fail(_ failure: CloudEngineFailure) {
        guard phase != .finished else { return }
        let pendingStart = startContinuation
        startContinuation = nil
        dropSocket(gracefully: false)
        reportUsage()
        phase = .finished
        stopTimer()

        if let pendingStart {
            pendingStart.resume(throwing: failure)
        } else {
            handlers.failed(failure)
        }
    }

    private func finish() {
        guard phase != .finished else { return }
        let pendingStart = startContinuation
        startContinuation = nil
        dropSocket(gracefully: phase == .streaming)
        reportUsage()
        phase = .finished
        stopTimer()
        pendingStart?.resume(throwing: CancellationError())
    }

    /// Detaches the current socket. A graceful drop asks the server to close the
    /// session first and gives it `closeTimeout` to drain.
    private func dropSocket(gracefully: Bool) {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        socketGeneration &+= 1

        guard let oldSocket = socket else { return }
        socket = nil

        guard gracefully else {
            oldSocket.cancel()
            return
        }

        oldSocket.send(OpenAITranslateProtocol.sessionCloseMessage) { _ in }
        queue.asyncAfter(deadline: .now() + configuration.closeTimeout) {
            oldSocket.cancel()
        }
    }

    // MARK: Audio

    private func handleSamples(_ samples: [Int16]) {
        guard phase != .finished, phase != .idle else { return }
        lastCaptureAt = clock()

        if configuration.hasVoiceActivitySignal == false,
           PCM16Encoding.peakLevel(of: samples) >= configuration.activityPeakThreshold {
            noteActivity()
        }

        for chunk in chunker.append(samples) {
            route(chunk)
        }
    }

    private func route(_ chunk: [Int16]) {
        switch phase {
        case .streaming:
            sendChunk(chunk)
        case .connecting:
            queuedChunks.append(chunk)
            if queuedChunks.count > configuration.maximumQueuedChunkCount {
                queuedChunks.removeFirst(queuedChunks.count - configuration.maximumQueuedChunkCount)
            }
        case .paused:
            prerollChunks.append(chunk)
            if prerollChunks.count > configuration.prerollChunkCount {
                prerollChunks.removeFirst(prerollChunks.count - configuration.prerollChunkCount)
            }
        case .idle, .finished:
            break
        }
    }

    private func sendChunk(_ chunk: [Int16]) {
        send(OpenAITranslateProtocol.appendAudioMessage(pcm16: PCM16Encoding.littleEndianData(from: chunk)))
        unreportedChunkCount += 1
        if unreportedChunkCount >= configuration.usageReportChunkCount {
            reportUsage()
        }
    }

    private func send(_ message: String) {
        guard let socket else { return }
        let generation = socketGeneration
        socket.send(message) { [weak self, weak socket] error in
            guard let self, error != nil else { return }
            self.queue.async {
                guard self.socketGeneration == generation else { return }
                self.handleSocketFailure(statusCode: socket?.handshakeStatusCode)
            }
        }
    }

    private func reportUsage() {
        guard unreportedChunkCount > 0 else { return }
        let seconds = Double(unreportedChunkCount) * OpenAITranslateProtocol.chunkDuration
        unreportedChunkCount = 0
        handlers.streamedAudio(seconds)
    }

    // MARK: Voice activity, pause and resume

    private func handleVoiceActivity(isSpeaking: Bool, onset: Bool, offset: Bool) {
        guard phase != .finished, phase != .idle else { return }
        let now = clock()
        self.isSpeaking = isSpeaking

        if onset {
            assembler.speechStarted(at: now)
        }
        if offset {
            assembler.speechEnded(at: now)
        }
        if isSpeaking || onset {
            noteActivity()
        }
    }

    private func noteActivity() {
        lastVoiceActivityAt = clock()
        if phase == .paused {
            resumeFromPause()
        }
    }

    private func pauseForSilence() {
        emit(assembler.flush(at: clock()))
        dropSocket(gracefully: true)
        reportUsage()
        prerollChunks.removeAll()
        phase = .paused
        handlers.stateChanged(.pausedNoAudio)
    }

    private func resumeFromPause() {
        queuedChunks = prerollChunks
        prerollChunks.removeAll()
        handlers.stateChanged(.reconnecting)
        beginConnect()
    }

    /// Replaces a session that is about to expire. Audio captured while the new one
    /// opens is queued and sent once it is ready.
    private func rollOver() {
        emit(assembler.flush(at: clock()))
        dropSocket(gracefully: true)
        reportUsage()
        handlers.stateChanged(.reconnecting)
        beginConnect()
    }

    // MARK: Timer

    private func startTimerIfNeeded() {
        guard configuration.runsTimer, timer == nil else { return }
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(OpenAITranslateProtocol.chunkDurationMs)
        newTimer.schedule(deadline: .now() + interval, repeating: interval)
        newTimer.setEventHandler { [weak self] in
            self?.tick()
        }
        newTimer.resume()
        timer = newTimer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Runs every 200 ms on `queue`. Exposed so tests can drive time by hand.
    func tick() {
        let now = clock()

        switch phase {
        case .streaming:
            fillSilenceIfCaptureStalled(now: now)
            emit(assembler.advance(to: now))

            if now - lastVoiceActivityAt >= configuration.idlePauseInterval {
                pauseForSilence()
            } else if let sessionExpiresAt {
                let remaining = sessionExpiresAt.timeIntervalSince(wallClock())
                let atNaturalPause = isSpeaking == false && assembler.hasPendingText == false
                if remaining <= configuration.rolloverDeadline
                    || (remaining <= configuration.rolloverLeadTime && atNaturalPause) {
                    rollOver()
                }
            }
        case .connecting:
            fillSilenceIfCaptureStalled(now: now)
        case .idle, .paused, .finished:
            break
        }
    }

    private func fillSilenceIfCaptureStalled(now: TimeInterval) {
        guard now - lastCaptureAt >= configuration.silenceFillThreshold else { return }
        route(PCM16Chunker.silentChunk())
    }

    // MARK: Output

    private func emit(_ outputs: [TranslateDeltaAssembler.Output]) {
        guard outputs.isEmpty == false else { return }

        #if DEBUG
        for case .sentence(let sentence) in outputs {
            logLatency(sentence.timing)
        }
        #endif

        handlers.outputs(outputs)
    }

    #if DEBUG
    /// R16: per-sentence delays, measured from the end of speech when it is known.
    /// Timings only: transcript text is never logged.
    private func logLatency(_ timing: TranslateDeltaAssembler.Timing) {
        func describe(_ value: TimeInterval?) -> String {
            guard let value else { return "-" }
            guard let speechEndedAt = timing.speechEndedAt else {
                return String(format: "%.2fs before commit", timing.committedAt - value)
            }
            return String(format: "%+.2fs", value - speechEndedAt)
        }

        Logger.cloudEngine.debug(
            """
            Sentence latency vs end of speech: first source \(describe(timing.firstSourceDeltaAt), privacy: .public), \
            first translation \(describe(timing.firstTranslationDeltaAt), privacy: .public), \
            commit \(describe(timing.committedAt), privacy: .public)
            """
        )
    }
    #endif
}
