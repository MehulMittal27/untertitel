import Foundation

/// One WebSocket frame to a cloud engine.
enum CloudSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// Why a cloud engine reported an error.
struct CloudWireError: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The key is missing, wrong or not allowed to use the engine.
        case authentication
        /// The engine's limit for one connection was reached. A new one may be opened.
        case sessionLimit
        case other
    }

    var kind: Kind
    /// The engine closes the connection after this error.
    var isFatal: Bool
    var message: String
    /// A short machine-readable label for the log. Never transcript text.
    var logLabel: String
}

/// What a cloud engine says, in the terms the client works with.
enum CloudWireEvent: Equatable, Sendable {
    /// The connection is open. The client answers with the wire's configuration message.
    case sessionCreated(expiresAt: Date?)
    /// The configuration was accepted: audio may be sent.
    case sessionReady
    case sessionClosed
    /// Source-language text that will not change. Append-only.
    case sourceDelta(String)
    /// Target-language text that will not change. Append-only.
    case translationDelta(String)
    /// Text that may still change. It replaces whatever was provisional before.
    case provisional(source: String, translation: String)
    /// The engine heard the speaker finish.
    case utteranceEnded
    /// Translated speech. Never read: the app shows text only.
    case discardedAudio
    case error(CloudWireError)
    case unknown(String)
}

/// The wire format of one cloud engine. Everything else about a cloud session, above
/// all when a connection may be open, is the same for every engine and lives in
/// `OpenAITranslateClient`.
protocol CloudEngineWire: Sendable {
    /// For logs and the connection record.
    var name: String { get }
    func makeRequest(apiKey: String) -> URLRequest
    /// Sent as soon as the socket is open. Nil when the engine speaks first.
    func openingMessage(transcribesSource: Bool) -> CloudSocketMessage?
    /// True when audio may follow the opening message without waiting for the server.
    var streamsAfterOpening: Bool { get }
    /// (Re)configures a session that is open. Nil when the engine cannot be
    /// reconfigured, or has nothing to configure.
    func configurationMessage(transcribesSource: Bool) -> CloudSocketMessage?
    func audioMessage(pcm16: Data) -> CloudSocketMessage
    /// Asks the engine to end the session. Best effort: the socket is closed right after.
    var closeMessage: CloudSocketMessage? { get }
    func decode(_ message: String) -> [CloudWireEvent]
}

// MARK: - OpenAI

/// OpenAI `gpt-realtime-translate`. See `plan/OPENAI-TRANSLATE.md`.
struct OpenAIWire: CloudEngineWire {
    let targetLanguageCode: String

    var name: String { "OpenAI" }
    var streamsAfterOpening: Bool { false }
    var closeMessage: CloudSocketMessage? { .text(OpenAITranslateProtocol.sessionCloseMessage) }

    func makeRequest(apiKey: String) -> URLRequest {
        OpenAITranslateProtocol.makeRequest(apiKey: apiKey)
    }

    func openingMessage(transcribesSource: Bool) -> CloudSocketMessage? {
        nil
    }

    func configurationMessage(transcribesSource: Bool) -> CloudSocketMessage? {
        .text(
            OpenAITranslateProtocol.sessionUpdateMessage(
                targetLanguageCode: targetLanguageCode,
                transcribesSource: transcribesSource
            )
        )
    }

    func audioMessage(pcm16: Data) -> CloudSocketMessage {
        .text(OpenAITranslateProtocol.appendAudioMessage(pcm16: pcm16))
    }

    func decode(_ message: String) -> [CloudWireEvent] {
        guard let event = OpenAITranslateServerEvent.decode(message) else {
            return []
        }

        switch event {
        case .sessionCreated(let expiresAt):
            return [.sessionCreated(expiresAt: expiresAt)]
        case .sessionUpdated:
            return [.sessionReady]
        case .sessionClosed:
            return [.sessionClosed]
        case .inputTranscriptDelta(let delta, _):
            return [.sourceDelta(delta)]
        case .outputTranscriptDelta(let delta, _):
            return [.translationDelta(delta)]
        case .outputAudioDiscarded:
            return [.discardedAudio]
        case .error(let serverError):
            let isAuthentication = serverError.type == "authentication_error" || serverError.code == "invalid_api_key"
            return [
                .error(
                    CloudWireError(
                        kind: isAuthentication ? .authentication : .other,
                        // OpenAI keeps the session open after an error.
                        isFatal: false,
                        message: serverError.message,
                        logLabel: "\(serverError.type) \(serverError.code ?? "-")"
                    )
                ),
            ]
        case .unknown(let type):
            return [.unknown(type)]
        }
    }
}

// MARK: - Soniox

/// Soniox real-time speech-to-text with one-way translation
/// (`wss://stt-rt.soniox.com/transcribe-websocket`). See `plan/SONIOX.md`.
///
/// Unlike OpenAI's engine it returns text only, sends provisional tokens that are
/// replaced until they become final, takes a glossary, and bills for as long as the
/// connection is open rather than per model.
struct SonioxWire: CloudEngineWire {
    static let endpointURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let model = "stt-rt-v5"
    /// Tokens the engine sends as markers rather than as text.
    static let endpointToken = "<end>"
    static let finalizedToken = "<fin>"
    /// The engine accepts at most this many context terms' worth of text; the glossary
    /// is cut well below its 8000-token limit.
    static let maximumGlossaryEntries = 200

    let sourceLanguageCode: String
    let targetLanguageCode: String
    /// Terms to recognize and how to translate them: source term to target term.
    var glossary: [String: String] = [:]

    var name: String { "Soniox" }
    var streamsAfterOpening: Bool { true }
    /// An empty text frame ends the stream.
    var closeMessage: CloudSocketMessage? { .text("") }

    func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: Self.endpointURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    func openingMessage(transcribesSource: Bool) -> CloudSocketMessage? {
        var payload: [String: Any] = [
            "model": Self.model,
            "audio_format": "s16le",
            "sample_rate": OpenAITranslateProtocol.sampleRate,
            "num_channels": 1,
            // Calls switch between the two languages; anything else is unexpected.
            "language_hints": Array(Set([sourceLanguageCode, targetLanguageCode])).sorted(),
            "enable_endpoint_detection": true,
            "translation": [
                "type": "one_way",
                "target_language": targetLanguageCode,
            ],
        ]

        let entries = glossary
            .map { (source: $0.key.trimmingCharacters(in: .whitespacesAndNewlines),
                    target: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0.source.isEmpty == false }
            .sorted { $0.source < $1.source }
            .prefix(Self.maximumGlossaryEntries)
        if entries.isEmpty == false {
            payload["context"] = [
                "terms": entries.map(\.source),
                "translation_terms": entries
                    .filter { $0.target.isEmpty == false }
                    .map { ["source": $0.source, "target": $0.target] },
            ]
        }

        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// The source transcript is part of the same model and the same price, and the
    /// configuration is fixed once the stream has started.
    func configurationMessage(transcribesSource: Bool) -> CloudSocketMessage? {
        nil
    }

    func audioMessage(pcm16: Data) -> CloudSocketMessage {
        .binary(pcm16)
    }

    func decode(_ message: String) -> [CloudWireEvent] {
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(message.utf8)) else {
            return []
        }

        if let code = response.errorCode {
            let kind: CloudWireError.Kind
            switch code {
            case 401, 402, 403:
                // A wrong key, an empty balance, or no permission: retrying cannot help.
                kind = .authentication
            case 413:
                kind = .sessionLimit
            default:
                kind = .other
            }
            return [
                .error(
                    CloudWireError(
                        kind: kind,
                        isFatal: true,
                        message: response.errorMessage ?? "",
                        logLabel: "\(code) \(response.errorType ?? "-")"
                    )
                ),
            ]
        }

        var events: [CloudWireEvent] = []
        var finalSource = ""
        var finalTranslation = ""
        var provisionalSource = ""
        var provisionalTranslation = ""
        var utteranceEnded = false

        for token in response.tokens ?? [] {
            if token.text == Self.endpointToken || token.text == Self.finalizedToken {
                utteranceEnded = utteranceEnded || token.text == Self.endpointToken
                continue
            }

            let isTranslation = token.translationStatus == "translation"
            switch (token.isFinal ?? false, isTranslation) {
            case (true, false):
                finalSource += token.text
            case (true, true):
                finalTranslation += token.text
            case (false, false):
                provisionalSource += token.text
            case (false, true):
                provisionalTranslation += token.text
            }
        }

        if finalSource.isEmpty == false {
            events.append(.sourceDelta(finalSource))
        }
        if finalTranslation.isEmpty == false {
            events.append(.translationDelta(finalTranslation))
        }
        // Always sent, also when empty: a response without provisional tokens clears
        // the ones before it.
        if response.tokens != nil {
            events.append(.provisional(source: provisionalSource, translation: provisionalTranslation))
        }
        if utteranceEnded {
            events.append(.utteranceEnded)
        }
        if response.finished == true {
            events.append(.sessionClosed)
        }
        return events
    }

    private struct Response: Decodable {
        let tokens: [Token]?
        let finished: Bool?
        let errorCode: Int?
        let errorType: String?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorCode = "error_code"
            case errorType = "error_type"
            case errorMessage = "error_message"
        }

        struct Token: Decodable {
            let text: String
            let isFinal: Bool?
            let translationStatus: String?

            enum CodingKeys: String, CodingKey {
                case text
                case isFinal = "is_final"
                case translationStatus = "translation_status"
            }
        }
    }
}
