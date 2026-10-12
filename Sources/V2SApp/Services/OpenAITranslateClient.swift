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

/// Every socket to the cloud engine that is open right now. The menu-bar icon reads
/// this rather than the session state, so it cannot show "off" while a connection
/// that may be billing is still open, and Stop can close whatever is left.
final class CloudConnectionRegistry: @unchecked Sendable {
    static let shared = CloudConnectionRegistry()

    private let lock = NSLock()
    private var sockets: [ObjectIdentifier: OpenAITranslateSocket] = [:]
    private var observers: [UUID: @Sendable (Int) -> Void] = [:]

    var openCount: Int {
        lock.withLock { sockets.count }
    }

    func register(_ socket: OpenAITranslateSocket) {
        update { $0[ObjectIdentifier(socket)] = socket }
    }

    func unregister(_ socket: OpenAITranslateSocket) {
        update { $0[ObjectIdentifier(socket)] = nil }
    }

    /// Closes every open connection, whoever owns it. Returns how many there were.
    @discardableResult
    func closeAll() -> Int {
        let open = lock.withLock { Array(sockets.values) }
        for socket in open {
            socket.cancel()
        }
        update { $0.removeAll() }
        return open.count
    }

    /// Calls `handler` with the number of open connections whenever it changes, on
    /// whichever thread changed it.
    func observe(_ handler: @escaping @Sendable (Int) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.withLock { observers[id] = nil }
    }

    private func update(_ change: (inout [ObjectIdentifier: OpenAITranslateSocket]) -> Void) {
        let (count, handlers): (Int, [@Sendable (Int) -> Void]) = lock.withLock {
            let before = sockets.count
            change(&sockets)
            return (sockets.count, sockets.count == before ? [] : Array(observers.values))
        }
        for handler in handlers {
            handler(count)
        }
    }
}

/// Why a connection to the cloud engine was opened.
enum CloudConnectReason: String, Equatable, Sendable {
    /// The first sound of a session.
    case sessionStart
    /// Sound returned after the connection was closed for silence.
    case audioReturned
    /// The user resumed a paused session.
    case manualResume
    /// Speech returned while paused and automatic resume is switched on.
    case automaticResume
    /// The previous connection reached the engine's session time limit.
    case renewal
}

/// Why a connection to the cloud engine was closed.
enum CloudDisconnectReason: String, Equatable, Sendable {
    case stopped
    /// The capture delivered only silence, so there was nothing to translate.
    case noAudio
    case idlePause
    case failed
    case renewal
}

/// One line of the local connection log.
enum CloudConnectionEvent: Equatable, Sendable {
    case opened(CloudConnectReason)
    /// `audioSeconds` is the audio sent over this connection, which is what is billed.
    case closed(CloudDisconnectReason, audioSeconds: TimeInterval)
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
    /// No connection: the capture is delivering no sound, at the start of a session or
    /// after about 20 seconds of silence. Nothing is billed. The connection opens by
    /// itself as soon as there is sound.
    case waitingForAudio
    case streaming
    /// The connection was closed after minutes without speech. Nothing is billed. It
    /// stays closed until the user resumes, unless automatic resume is switched on.
    case pausedNoAudio
    /// A connection is being opened.
    case reconnecting
    /// The pause lasted so long that the session ended itself. The owner stops as if
    /// the user had switched subtitles off, so nothing can start billing again later.
    case stoppedAfterLongPause
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
        /// Whether the engine also transcribes the source language. That runs on a
        /// second model with its own bill, so it is off when the line is not shown.
        var transcribesSource = true
        var connectTimeout: TimeInterval = 10
        /// Cost guardrail: close the connection after this long without speech.
        var idlePauseInterval: TimeInterval = 180
        /// Cost guardrail: close the connection after this long with no sound at all
        /// from the capture, instead of streaming, and paying for, silence.
        var noAudioCloseInterval: TimeInterval = 20
        /// Peak level from which captured audio counts as sound rather than silence.
        var soundPeakThreshold: Float = 0.003
        /// Whether speech reopens the connection after an idle pause. Off by default:
        /// a paused session then stays paused, and unbilled, until the user resumes it.
        var resumesAutomatically = false
        /// Cost guardrail: a pause this long ends the session instead of waiting for
        /// audio. Measured on the wall clock, so time the Mac spent asleep counts.
        var pausedStopInterval: TimeInterval = 900
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
        /// Seconds of audio sent since the last report, and how many of them were
        /// also transcribed in the source language. Billing follows audio duration.
        var streamedAudio: (_ seconds: TimeInterval, _ transcribedSeconds: TimeInterval) -> Void = { _, _ in }
        /// Every connection opened and closed, with the reason.
        var connectionEvent: (CloudConnectionEvent) -> Void = { _ in }
    }

    private enum Phase: Equatable {
        case idle
        /// Started, no connection, waiting for the capture to deliver sound.
        case waitingForAudio
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
    private let registry: CloudConnectionRegistry
    private let clock: () -> TimeInterval
    private let wallClock: () -> Date

    private var phase: Phase = .idle
    private var socket: OpenAITranslateSocket?
    /// Identifies the current socket. Callbacks from an earlier one are ignored.
    private var socketGeneration = 0
    private var connectTimeoutWork: DispatchWorkItem?
    private var timer: DispatchSourceTimer?

    private var assembler: TranslateDeltaAssembler
    private var chunker = PCM16Chunker()
    private var queuedChunks: [[Int16]] = []
    private var prerollChunks: [[Int16]] = []
    private var sessionExpiresAt: Date?
    private var pausedSince: Date?
    private var isSpeaking = false
    private var lastVoiceActivityAt: TimeInterval = 0
    private var lastCaptureAt: TimeInterval = 0
    private var lastSoundAt: TimeInterval = 0
    private var hasConnectedBefore = false
    /// The next connection is the user's resume of a paused session.
    private var resumesManually = false
    /// False until the capture has delivered its first audio. Silence is not sent in
    /// its place before then: it would be billed and carries nothing.
    private var hasCapturedAudio = false
    private var unreportedChunkCount = 0
    private var unreportedTranscribedChunkCount = 0
    /// Chunks sent over the current connection, for the connection log.
    private var connectionChunkCount = 0
    private var transcribesSource: Bool
    /// What the server was last told. Nil until this connection has been configured.
    private var configuredTranscribesSource: Bool?

    init(
        apiKey: String,
        configuration: Configuration,
        handlers: Handlers,
        queue: DispatchQueue = DispatchQueue(label: "com.franklioxygen.v2s.cloudEngine", qos: .userInitiated),
        makeSocket: @escaping (URLRequest) -> OpenAITranslateSocket = { URLSessionTranslateSocket(request: $0) },
        registry: CloudConnectionRegistry = .shared,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping () -> Date = { Date() }
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.handlers = handlers
        self.queue = queue
        self.makeSocket = makeSocket
        self.registry = registry
        self.clock = clock
        self.wallClock = wallClock
        self.assembler = TranslateDeltaAssembler(hasVoiceActivitySignal: configuration.hasVoiceActivitySignal)
        self.transcribesSource = configuration.transcribesSource
    }

    deinit {
        // A client that is dropped without being stopped must not leave a connection.
        if let socket {
            socket.cancel()
            registry.unregister(socket)
        }
    }

    // MARK: Public interface (any thread)

    /// Starts the session without connecting. The connection, and with it the billing,
    /// opens only once the capture delivers sound; a bad key or an unreachable server
    /// is then reported through `Handlers.failed`.
    func start() {
        queue.async { [self] in
            guard phase == .idle else { return }

            let now = clock()
            lastVoiceActivityAt = now
            lastCaptureAt = now
            phase = .waitingForAudio
            handlers.stateChanged(.waitingForAudio)
            startTimerIfNeeded()
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

    /// Ends the session and closes the connection at once.
    func stop() {
        queue.async { [self] in
            finish()
        }
    }

    /// Takes a session out of its pause. Does nothing otherwise. The connection still
    /// opens only when there is sound to send.
    func resume() {
        queue.async { [self] in
            guard phase == .paused else { return }
            lastVoiceActivityAt = clock()
            pausedSince = nil
            resumesManually = true
            phase = .waitingForAudio
            handlers.stateChanged(.waitingForAudio)
        }
    }

    /// The capture reports that it is delivering silence although the source is
    /// playing. There is nothing to translate, so the connection is closed at once.
    func noteCaptureSilent() {
        queue.async { [self] in
            guard phase == .streaming || phase == .connecting else { return }
            closeForNoAudio()
        }
    }

    /// Switches source-language transcription, and its separate bill, on or off.
    func setSourceTranscription(_ enabled: Bool) {
        queue.async { [self] in
            guard transcribesSource != enabled else { return }
            transcribesSource = enabled
            if enabled == false {
                // The rest of the sentence under way will never arrive.
                assembler.discardPendingSource()
            }
            if phase == .streaming {
                sendSessionConfiguration()
            }
        }
    }

    // MARK: Connection

    private func beginConnect(reason: CloudConnectReason) {
        phase = .connecting
        sessionExpiresAt = nil
        socketGeneration &+= 1
        let generation = socketGeneration
        configuredTranscribesSource = nil
        connectionChunkCount = 0

        let newSocket = makeSocket(OpenAITranslateProtocol.makeRequest(apiKey: apiKey))
        socket = newSocket
        registry.register(newSocket)
        Logger.cloudEngine.log("Cloud connection opening: \(reason.rawValue, privacy: .public)")
        handlers.connectionEvent(.opened(reason))
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
            sendSessionConfiguration()
        case .sessionUpdated:
            guard phase == .connecting else { return }
            didConnect()
        case .sessionClosed:
            handleSocketFailure(statusCode: nil)
        case .inputTranscriptDelta(let delta, _):
            // Deltas still on their way after transcription was switched off are dropped.
            guard phase == .streaming, transcribesSource else { return }
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

    private func sendSessionConfiguration() {
        configuredTranscribesSource = transcribesSource
        send(
            OpenAITranslateProtocol.sessionUpdateMessage(
                targetLanguageCode: configuration.targetLanguageCode,
                transcribesSource: transcribesSource
            )
        )
    }

    private func didConnect() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        phase = .streaming
        hasConnectedBefore = true
        // The idle clock is not reset here: a source that only ever plays music must
        // still reach the pause, however often its sound comes and goes.
        lastSoundAt = clock()
        // The setting changed while this connection was being opened.
        if configuredTranscribesSource != transcribesSource {
            sendSessionConfiguration()
        }

        let backlog = queuedChunks
        queuedChunks.removeAll()
        for chunk in backlog {
            sendChunk(chunk)
        }

        handlers.stateChanged(.streaming)
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
        case .idle, .waitingForAudio, .paused, .finished:
            break
        }
    }

    private func fail(_ failure: CloudEngineFailure) {
        guard phase != .finished else { return }
        dropSocket(reason: .failed)
        reportUsage()
        phase = .finished
        stopTimer()
        handlers.failed(failure)
    }

    private func finish() {
        guard phase != .finished else { return }
        dropSocket(reason: .stopped)
        reportUsage()
        phase = .finished
        stopTimer()
    }

    /// Closes the current connection, if there is one, at once. Nothing waits for the
    /// server: a connection the user believes is closed must not linger.
    private func dropSocket(reason: CloudDisconnectReason) {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        socketGeneration &+= 1

        guard let oldSocket = socket else { return }
        socket = nil

        // Best effort: the close frame that follows ends the session either way.
        oldSocket.send(OpenAITranslateProtocol.sessionCloseMessage) { _ in }
        oldSocket.cancel()
        registry.unregister(oldSocket)

        let audioSeconds = Double(connectionChunkCount) * OpenAITranslateProtocol.chunkDuration
        connectionChunkCount = 0
        Logger.cloudEngine.log(
            "Cloud connection closed: \(reason.rawValue, privacy: .public), \(audioSeconds, privacy: .public) s of audio sent"
        )
        handlers.connectionEvent(.closed(reason, audioSeconds: audioSeconds))
    }

    // MARK: Audio

    private func handleSamples(_ samples: [Int16]) {
        guard phase != .finished, phase != .idle else { return }
        let now = clock()
        lastCaptureAt = now
        hasCapturedAudio = true

        let peak = PCM16Encoding.peakLevel(of: samples)
        let hasSound = peak >= configuration.soundPeakThreshold
        if hasSound {
            lastSoundAt = now
        }

        if configuration.hasVoiceActivitySignal == false, peak >= configuration.activityPeakThreshold {
            noteActivity()
        }

        for chunk in chunker.append(samples) {
            route(chunk)
        }

        // The connection opens here and nowhere earlier: on the first sound, with the
        // moment before it replayed so the first word is not clipped.
        if phase == .waitingForAudio, hasSound {
            connectForSound()
        }
    }

    private func connectForSound() {
        let reason: CloudConnectReason
        if resumesManually {
            reason = .manualResume
        } else {
            reason = hasConnectedBefore ? .audioReturned : .sessionStart
        }
        resumesManually = false

        queuedChunks = prerollChunks
        prerollChunks.removeAll()
        handlers.stateChanged(.reconnecting)
        beginConnect(reason: reason)
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
        case .waitingForAudio, .paused:
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
        connectionChunkCount += 1
        if configuredTranscribesSource == true {
            unreportedTranscribedChunkCount += 1
        }
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
        let transcribedSeconds = Double(unreportedTranscribedChunkCount) * OpenAITranslateProtocol.chunkDuration
        unreportedChunkCount = 0
        unreportedTranscribedChunkCount = 0
        handlers.streamedAudio(seconds, transcribedSeconds)
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
        guard phase == .paused else { return }

        // Audio can arrive before the timer notices an overlong pause, for example
        // right after the Mac wakes. It must not reopen the connection.
        if hasPausedTooLong {
            stopAfterLongPause()
        } else if configuration.resumesAutomatically {
            resumeFromPause(reason: .automaticResume)
        }
        // Otherwise the session stays paused: sound from the source, such as a video
        // that starts playing by itself, must not start billing again.
    }

    private var hasPausedTooLong: Bool {
        guard let pausedSince else { return false }
        return wallClock().timeIntervalSince(pausedSince) >= configuration.pausedStopInterval
    }

    private func stopAfterLongPause() {
        handlers.stateChanged(.stoppedAfterLongPause)
        finish()
    }

    private func pauseForSilence() {
        emit(assembler.flush(at: clock()))
        dropSocket(reason: .idlePause)
        reportUsage()
        prerollChunks.removeAll()
        phase = .paused
        pausedSince = wallClock()
        handlers.stateChanged(.pausedNoAudio)
    }

    /// Nothing but silence is arriving. Sending it would be billed like speech, so the
    /// connection is closed until there is sound again.
    private func closeForNoAudio() {
        emit(assembler.flush(at: clock()))
        dropSocket(reason: .noAudio)
        reportUsage()
        queuedChunks.removeAll()
        prerollChunks.removeAll()
        phase = .waitingForAudio
        handlers.stateChanged(.waitingForAudio)
    }

    private func resumeFromPause(reason: CloudConnectReason) {
        pausedSince = nil
        queuedChunks = prerollChunks
        prerollChunks.removeAll()
        handlers.stateChanged(.reconnecting)
        beginConnect(reason: reason)
    }

    /// Replaces a session that is about to expire. Audio captured while the new one
    /// opens is queued and sent once it is ready.
    private func rollOver() {
        emit(assembler.flush(at: clock()))
        dropSocket(reason: .renewal)
        reportUsage()
        handlers.stateChanged(.reconnecting)
        beginConnect(reason: .renewal)
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
            } else if now - lastSoundAt >= configuration.noAudioCloseInterval {
                closeForNoAudio()
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
        case .waitingForAudio:
            // Still nothing to send after minutes: a pause, so that sound from the
            // source much later cannot open a connection the user has forgotten about.
            if now - lastVoiceActivityAt >= configuration.idlePauseInterval {
                pauseForSilence()
            }
        case .paused:
            if hasPausedTooLong {
                stopAfterLongPause()
            }
        case .idle, .finished:
            break
        }
    }

    private func fillSilenceIfCaptureStalled(now: TimeInterval) {
        guard hasCapturedAudio, now - lastCaptureAt >= configuration.silenceFillThreshold else { return }
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
