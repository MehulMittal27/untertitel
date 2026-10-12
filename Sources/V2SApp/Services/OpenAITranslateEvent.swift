import Foundation

/// Wire format of OpenAI's realtime translation WebSocket
/// (`wss://api.openai.com/v1/realtime/translations`). See `plan/OPENAI-TRANSLATE.md`.
enum OpenAITranslateProtocol {
    static let model = "gpt-realtime-translate"
    static let sourceTranscriptionModel = "gpt-realtime-whisper"
    static let sampleRate = 24_000
    /// The engine consumes 200 ms frames; sending exactly one per message avoids
    /// server-side buffering or splitting.
    static let chunkDurationMs = 200
    static let samplesPerChunk = sampleRate * chunkDurationMs / 1000
    static let chunkDuration = TimeInterval(chunkDurationMs) / 1000

    static var endpointURL: URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime/translations"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    static func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// The target language as OpenAI expects it: a bare language code.
    static func targetLanguageCode(forLanguageID languageID: String) -> String {
        String(languageID.split(separator: "-").first ?? Substring(languageID)).lowercased()
    }

    // MARK: Client events

    /// The model is chosen in the URL and cannot be changed here. Source transcription
    /// is what produces the original-language line. Noise reduction is off: app audio
    /// is already a clean digital signal, and `near_field` targets headset microphones.
    static func sessionUpdateMessage(targetLanguageCode: String) -> String {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "audio": [
                    "input": [
                        "transcription": ["model": sourceTranscriptionModel],
                        "noise_reduction": NSNull(),
                    ],
                    "output": ["language": targetLanguageCode],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Base64 needs no JSON escaping, so the message is assembled directly.
    static func appendAudioMessage(pcm16: Data) -> String {
        "{\"type\":\"session.input_audio_buffer.append\",\"audio\":\"\(pcm16.base64EncodedString())\"}"
    }

    static let sessionCloseMessage = "{\"type\":\"session.close\"}"
}

struct OpenAITranslateServerError: Equatable, Sendable {
    let type: String
    let code: String?
    let message: String
}

enum OpenAITranslateServerEvent: Equatable, Sendable {
    case sessionCreated(expiresAt: Date?)
    case sessionUpdated
    case sessionClosed
    /// Source-language transcript text. Append-only; never insert spaces between deltas.
    case inputTranscriptDelta(String, elapsedMs: Int?)
    /// Target-language transcript text. Append-only.
    case outputTranscriptDelta(String, elapsedMs: Int?)
    /// Translated speech. Its payload is deliberately never read: the app shows text
    /// only and must not play, decode, or store this audio.
    case outputAudioDiscarded
    case error(OpenAITranslateServerError)
    case unknown(type: String)

    static func decode(_ message: String) -> OpenAITranslateServerEvent? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(message.utf8)) else {
            return nil
        }

        switch envelope.type {
        case "session.created":
            return .sessionCreated(
                expiresAt: envelope.session?.expiresAt.map { Date(timeIntervalSince1970: $0) }
            )
        case "session.updated":
            return .sessionUpdated
        case "session.closed":
            return .sessionClosed
        case "session.input_transcript.delta":
            return .inputTranscriptDelta(envelope.textDelta ?? "", elapsedMs: envelope.elapsedMs)
        case "session.output_transcript.delta":
            return .outputTranscriptDelta(envelope.textDelta ?? "", elapsedMs: envelope.elapsedMs)
        case "session.output_audio.delta":
            return .outputAudioDiscarded
        case "error":
            return .error(
                OpenAITranslateServerError(
                    type: envelope.error?.type ?? "unknown",
                    code: envelope.error?.code,
                    message: envelope.error?.message ?? ""
                )
            )
        default:
            return .unknown(type: envelope.type)
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let textDelta: String?
        let elapsedMs: Int?
        let session: Session?
        let error: ErrorBody?

        struct Session: Decodable {
            let expiresAt: Double?

            enum CodingKeys: String, CodingKey {
                case expiresAt = "expires_at"
            }
        }

        struct ErrorBody: Decodable {
            let type: String?
            let code: String?
            let message: String?
        }

        enum CodingKeys: String, CodingKey {
            case type
            case delta
            case elapsedMs = "elapsed_ms"
            case session
            case error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            elapsedMs = (try? container.decodeIfPresent(Double.self, forKey: .elapsedMs)).flatMap { $0 }.map { Int($0) }
            session = try? container.decodeIfPresent(Session.self, forKey: .session)
            error = try? container.decodeIfPresent(ErrorBody.self, forKey: .error)
            // `delta` is text for transcript events and audio for audio events. Only the
            // transcript text is ever read into memory as a value.
            if type == "session.input_transcript.delta" || type == "session.output_transcript.delta" {
                textDelta = try? container.decodeIfPresent(String.self, forKey: .delta)
            } else {
                textDelta = nil
            }
        }
    }
}
