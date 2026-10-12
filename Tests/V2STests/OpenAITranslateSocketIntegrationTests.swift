import Network
import os
import XCTest
@testable import v2s

/// A WebSocket server on localhost that plays the part of the translation endpoint,
/// so the real `URLSession` socket is exercised end to end without any network.
private final class LocalTranslationServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalTranslationServer")
    private let lock = NSLock()
    private var _received: [String] = []
    private var connection: NWConnection?
    var onMessage: (@Sendable (String) -> Void)?

    var received: [String] { lock.withLock { _received } }

    init() throws {
        let parameters = NWParameters.tcp
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.send(#"{"type":"session.created","session":{"id":"sess_local","type":"translation"}}"#)
            self.receiveNext(on: connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let didResume = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                let shouldResume = didResume.withLock { alreadyResumed -> Bool in
                    guard alreadyResumed == false else { return false }
                    switch state {
                    case .ready, .failed:
                        alreadyResumed = true
                        return true
                    default:
                        return false
                    }
                }
                guard shouldResume else { return }

                if case .failed(let error) = state {
                    continuation.resume(throwing: error)
                } else if let port = listener.port {
                    continuation.resume(returning: URL(string: "ws://127.0.0.1:\(port.rawValue)/v1/realtime/translations")!)
                } else {
                    continuation.resume(throwing: URLError(.cannotConnectToHost))
                }
            }
            listener.start(queue: queue)
        }
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock { self._received.append(text) }

            if text.contains("\"session.update\"") {
                self.send(#"{"type":"session.updated","session":{"id":"sess_local","type":"translation"}}"#)
            } else if text.contains("\"session.close\"") {
                self.send(#"{"type":"session.closed"}"#)
            }
            self.onMessage?(text)
            self.receiveNext(on: connection)
        }
    }
}

final class OpenAITranslateSocketIntegrationTests: XCTestCase {
    func testRealSocketConfiguresStreamsAudioAndReceivesTranscripts() async throws {
        let server = try LocalTranslationServer()
        let serverURL = try await server.start()
        defer { server.stop() }

        let sentence = expectation(description: "sentence delivered")
        let audioArrived = expectation(description: "audio reached the server")
        audioArrived.assertForOverFulfill = false

        server.onMessage = { [weak server] message in
            if message.contains("session.input_audio_buffer.append") {
                audioArrived.fulfill()
                server?.send(#"{"type":"session.output_audio.delta","delta":"AAAA","sample_rate":24000}"#)
                server?.send(#"{"type":"session.input_transcript.delta","delta":"Guten Morgen.","elapsed_ms":200}"#)
                server?.send(#"{"type":"session.output_transcript.delta","delta":"Good morning.","elapsed_ms":200}"#)
            }
        }

        var configuration = OpenAITranslateClient.Configuration(targetLanguageCode: "en")
        configuration.hasVoiceActivitySignal = false
        let registry = CloudConnectionRegistry()
        var handlers = OpenAITranslateClient.Handlers()
        handlers.outputs = { outputs in
            for case .sentence(let committed) in outputs {
                XCTAssertEqual(committed.sourceText, "Guten Morgen.")
                XCTAssertEqual(committed.translatedText, "Good morning.")
                sentence.fulfill()
            }
        }

        let client = OpenAITranslateClient(
            apiKey: "sk-local-test",
            configuration: configuration,
            handlers: handlers,
            makeSocket: { request in
                var localRequest = URLRequest(url: serverURL)
                localRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
                return URLSessionTranslateSocket(request: localRequest)
            },
            registry: registry
        )

        // Starting connects to nothing: the first sound does.
        client.start()
        client.appendSamples([Int16](repeating: 1_000, count: 4_800))

        await fulfillment(of: [audioArrived, sentence], timeout: 10)
        XCTAssertTrue(server.received.first?.contains("\"session.update\"") == true, "configuration comes first")
        XCTAssertEqual(registry.openCount, 1)

        client.stop()
        client.queue.sync {}
        XCTAssertEqual(registry.openCount, 0, "Stop closes the connection without waiting")
    }

    /// Soniox over a real WebSocket: the configuration goes first as text, the audio
    /// follows as binary frames without waiting, and its tokens become a sentence.
    func testRealSocketSpeaksSonioxFormat() async throws {
        let server = try LocalTranslationServer()
        let serverURL = try await server.start()
        defer { server.stop() }

        let sentence = expectation(description: "sentence delivered")
        let audioArrived = expectation(description: "audio reached the server")
        audioArrived.assertForOverFulfill = false

        server.onMessage = { [weak server] message in
            // The configuration is JSON; anything else is an audio frame.
            guard message.contains("\"model\"") == false else { return }
            audioArrived.fulfill()
            server?.send(#"{"tokens":[{"text":"Guten Morgen.","is_final":true,"translation_status":"original"},{"text":"Good morning.","is_final":true,"translation_status":"translation"},{"text":"<end>","is_final":true}]}"#)
        }

        var configuration = OpenAITranslateClient.Configuration(targetLanguageCode: "en")
        configuration.wire = SonioxWire(sourceLanguageCode: "de", targetLanguageCode: "en")
        configuration.hasVoiceActivitySignal = false
        let registry = CloudConnectionRegistry()
        var handlers = OpenAITranslateClient.Handlers()
        handlers.outputs = { outputs in
            for case .sentence(let committed) in outputs {
                XCTAssertEqual(committed.sourceText, "Guten Morgen.")
                XCTAssertEqual(committed.translatedText, "Good morning.")
                sentence.fulfill()
            }
        }

        let client = OpenAITranslateClient(
            apiKey: "soniox-local-test",
            configuration: configuration,
            handlers: handlers,
            makeSocket: { request in
                var localRequest = URLRequest(url: serverURL)
                localRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
                return URLSessionTranslateSocket(request: localRequest)
            },
            registry: registry
        )

        client.start()
        client.appendSamples([Int16](repeating: 1_000, count: 4_800))

        await fulfillment(of: [audioArrived, sentence], timeout: 10)
        XCTAssertTrue(server.received.first?.contains("\"model\":\"stt-rt-v5\"") == true, "configuration comes first")
        XCTAssertFalse(server.received.contains { $0.contains("soniox-local-test") }, "the key is not in any message")

        client.stop()
        client.queue.sync {}
        XCTAssertEqual(registry.openCount, 0)
    }

    func testNothingListeningIsReportedAsUnreachable() async throws {
        // Find a free port, then close it again so nothing answers there.
        let server = try LocalTranslationServer()
        let deadURL = try await server.start()
        server.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        var configuration = OpenAITranslateClient.Configuration(targetLanguageCode: "en")
        configuration.connectTimeout = 5
        let failed = expectation(description: "the failure is reported")
        var handlers = OpenAITranslateClient.Handlers()
        handlers.failed = { failure in
            XCTAssertEqual(failure, .connectionFailed)
            failed.fulfill()
        }
        let registry = CloudConnectionRegistry()
        let client = OpenAITranslateClient(
            apiKey: "sk-local-test",
            configuration: configuration,
            handlers: handlers,
            makeSocket: { _ in URLSessionTranslateSocket(request: URLRequest(url: deadURL)) },
            registry: registry
        )

        client.start()
        client.appendSamples([Int16](repeating: 1_000, count: 4_800))

        await fulfillment(of: [failed], timeout: 10)
        XCTAssertEqual(registry.openCount, 0)
    }
}
