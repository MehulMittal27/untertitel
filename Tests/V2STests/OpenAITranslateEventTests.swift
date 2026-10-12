import XCTest
@testable import v2s

final class OpenAITranslateEventTests: XCTestCase {
    func testEndpointSelectsTheTranslationModel() {
        XCTAssertEqual(
            OpenAITranslateProtocol.endpointURL.absoluteString,
            "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate"
        )
    }

    func testRequestCarriesTheKeyOnlyInTheAuthorizationHeader() {
        let request = OpenAITranslateProtocol.makeRequest(apiKey: "sk-test-123")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
        XCTAssertEqual(request.url?.absoluteString.contains("sk-test-123"), false)
    }

    func testSessionUpdateSetsLanguageAndSourceTranscriptButNotTheModel() throws {
        let message = OpenAITranslateProtocol.sessionUpdateMessage(targetLanguageCode: "en")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "session.update")
        XCTAssertNil(session["model"], "the model is fixed by the URL and cannot be updated")
        XCTAssertEqual(output["language"] as? String, "en")
        XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-realtime-whisper")
        XCTAssertTrue(input["noise_reduction"] is NSNull)
    }

    func testAppendAudioMessageCarriesBase64Audio() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let message = OpenAITranslateProtocol.appendAudioMessage(pcm16: pcm)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String])

        XCTAssertEqual(json["type"], "session.input_audio_buffer.append")
        XCTAssertEqual(json["audio"].flatMap { Data(base64Encoded: $0) }, pcm)
    }

    func testTargetLanguageCodeDropsScriptAndRegion() {
        XCTAssertEqual(OpenAITranslateProtocol.targetLanguageCode(forLanguageID: "en"), "en")
        XCTAssertEqual(OpenAITranslateProtocol.targetLanguageCode(forLanguageID: "zh-Hans"), "zh")
        XCTAssertEqual(OpenAITranslateProtocol.targetLanguageCode(forLanguageID: "pt-BR"), "pt")
    }

    func testTranscriptDeltasDecodeWithTheirText() {
        XCTAssertEqual(
            OpenAITranslateServerEvent.decode(
                #"{"event_id":"e1","type":"session.input_transcript.delta","delta":" hören","elapsed_ms":1200}"#
            ),
            .inputTranscriptDelta(" hören", elapsedMs: 1200)
        )
        XCTAssertEqual(
            OpenAITranslateServerEvent.decode(
                #"{"event_id":"e2","type":"session.output_transcript.delta","delta":" hear","elapsed_ms":null}"#
            ),
            .outputTranscriptDelta(" hear", elapsedMs: nil)
        )
    }

    func testTranslatedAudioIsDroppedWithoutItsPayload() {
        let event = OpenAITranslateServerEvent.decode(
            #"{"type":"session.output_audio.delta","delta":"AAAA////","sample_rate":24000,"channels":1,"format":"pcm16"}"#
        )

        XCTAssertEqual(event, .outputAudioDiscarded)
    }

    func testSessionLifecycleEventsDecode() {
        XCTAssertEqual(
            OpenAITranslateServerEvent.decode(
                #"{"type":"session.created","session":{"id":"sess_1","type":"translation","expires_at":1714857600}}"#
            ),
            .sessionCreated(expiresAt: Date(timeIntervalSince1970: 1_714_857_600))
        )
        XCTAssertEqual(OpenAITranslateServerEvent.decode(#"{"type":"session.updated","session":{}}"#), .sessionUpdated)
        XCTAssertEqual(OpenAITranslateServerEvent.decode(#"{"type":"session.closed"}"#), .sessionClosed)
    }

    func testErrorEventDecodesTypeCodeAndMessage() {
        XCTAssertEqual(
            OpenAITranslateServerEvent.decode(
                #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_event","message":"Bad","param":null}}"#
            ),
            .error(OpenAITranslateServerError(type: "invalid_request_error", code: "invalid_event", message: "Bad"))
        )
    }

    func testUnknownEventTypesAreReportedNotRejected() {
        XCTAssertEqual(
            OpenAITranslateServerEvent.decode(#"{"type":"session.something_new","delta":"x"}"#),
            .unknown(type: "session.something_new")
        )
        XCTAssertNil(OpenAITranslateServerEvent.decode("not json"))
    }
}
