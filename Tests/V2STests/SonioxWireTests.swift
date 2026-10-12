import XCTest
@testable import v2s

final class SonioxWireTests: XCTestCase {
    private let wire = SonioxWire(sourceLanguageCode: "de", targetLanguageCode: "en")

    private func payload(_ message: CloudSocketMessage?) throws -> [String: Any] {
        guard case .text(let text)? = message else {
            XCTFail("expected a text message")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testTheKeyTravelsInTheAuthorizationHeaderOnly() {
        let request = wire.makeRequest(apiKey: "soniox-secret-123")

        XCTAssertEqual(request.url?.absoluteString, "wss://stt-rt.soniox.com/transcribe-websocket")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-secret-123")
        XCTAssertEqual(request.url?.absoluteString.contains("soniox-secret-123"), false)
    }

    func testTheConfigurationAsksForRawAudioAndOneWayTranslationWithoutTheKey() throws {
        let message = wire.openingMessage(transcribesSource: true)
        let json = try payload(message)

        XCTAssertEqual(json["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(json["audio_format"] as? String, "s16le")
        XCTAssertEqual(json["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(json["num_channels"] as? Int, 1)
        XCTAssertEqual(json["language_hints"] as? [String], ["de", "en"])
        XCTAssertEqual(json["enable_endpoint_detection"] as? Bool, true)
        let translation = try XCTUnwrap(json["translation"] as? [String: Any])
        XCTAssertEqual(translation["type"] as? String, "one_way")
        XCTAssertEqual(translation["target_language"] as? String, "en")
        XCTAssertNil(json["api_key"], "the deprecated key field is not used")
        XCTAssertNil(json["context"], "no glossary, no context")
    }

    func testTheGlossaryIsSentAsTermsAndTranslationTerms() throws {
        let wire = SonioxWire(
            sourceLanguageCode: "de",
            targetLanguageCode: "en",
            glossary: ["Vertrieb": "Sales", "Kubernetes": "", "  ": "ignored"]
        )

        let context = try XCTUnwrap(try payload(wire.openingMessage(transcribesSource: true))["context"] as? [String: Any])

        XCTAssertEqual(context["terms"] as? [String], ["Kubernetes", "Vertrieb"])
        let translationTerms = try XCTUnwrap(context["translation_terms"] as? [[String: String]])
        XCTAssertEqual(translationTerms, [["source": "Vertrieb", "target": "Sales"]])
    }

    func testAudioIsBinaryAndTheStreamEndsWithAnEmptyTextFrame() {
        let audio = Data([1, 2, 3, 4])

        XCTAssertEqual(wire.audioMessage(pcm16: audio), .binary(audio))
        XCTAssertEqual(wire.closeMessage, .text(""))
        XCTAssertTrue(wire.streamsAfterOpening)
        XCTAssertNil(wire.configurationMessage(transcribesSource: false))
    }

    func testTokensAreSplitIntoFinalAndProvisionalOriginalAndTranslation() {
        let events = wire.decode(#"""
        {"tokens":[
          {"text":"Guten","is_final":true,"translation_status":"original","language":"de"},
          {"text":" Morgen","is_final":false,"translation_status":"original"},
          {"text":"Good","is_final":true,"translation_status":"translation"},
          {"text":" morn","is_final":false,"translation_status":"translation"}
        ],"final_audio_proc_ms":400,"total_audio_proc_ms":900}
        """#)

        XCTAssertEqual(events, [
            .sourceDelta("Guten"),
            .translationDelta("Good"),
            .provisional(source: " Morgen", translation: " morn"),
        ])
    }

    func testAResponseWithoutProvisionalTokensClearsTheOnesBefore() {
        XCTAssertEqual(
            wire.decode(#"{"tokens":[{"text":" Morgen.","is_final":true,"translation_status":"none"}]}"#),
            [.sourceDelta(" Morgen."), .provisional(source: "", translation: "")]
        )
        XCTAssertEqual(wire.decode(#"{"tokens":[]}"#), [.provisional(source: "", translation: "")])
    }

    func testTheEndpointMarkerIsASignalNotText() {
        let events = wire.decode(#"{"tokens":[{"text":"Hallo.","is_final":true},{"text":"<end>","is_final":true},{"text":"<fin>","is_final":true}]}"#)

        XCTAssertEqual(events, [.sourceDelta("Hallo."), .provisional(source: "", translation: ""), .utteranceEnded])
    }

    func testTheFinishedResponseClosesTheSession() {
        XCTAssertEqual(
            wire.decode(#"{"tokens":[],"final_audio_proc_ms":1000,"total_audio_proc_ms":1000,"finished":true}"#),
            [.provisional(source: "", translation: ""), .sessionClosed]
        )
    }

    func testErrorsAreSortedByWhatCanBeDoneAboutThem() {
        func error(_ code: Int) -> CloudWireError? {
            let events = wire.decode(#"{"error_code":\#(code),"error_type":"some_type","error_message":"Why."}"#)
            guard case .error(let error)? = events.first, events.count == 1 else { return nil }
            return error
        }

        XCTAssertEqual(error(401)?.kind, .authentication)
        XCTAssertEqual(error(402)?.kind, .authentication, "an empty balance is not fixed by retrying")
        XCTAssertEqual(error(403)?.kind, .authentication)
        XCTAssertEqual(error(413)?.kind, .sessionLimit)
        XCTAssertEqual(error(500)?.kind, .other)
        XCTAssertEqual(error(500)?.isFatal, true, "Soniox closes the connection after any error")
        XCTAssertEqual(error(500)?.message, "Why.")
        XCTAssertEqual(error(429)?.logLabel, "429 some_type")
    }

    func testAnythingElseIsIgnored() {
        XCTAssertEqual(wire.decode("not json"), [])
        XCTAssertEqual(wire.decode("{}"), [])
    }

    func testOpenAIStillSpeaksItsOwnFormat() {
        let openAI = OpenAIWire(targetLanguageCode: "en")

        XCTAssertNil(openAI.openingMessage(transcribesSource: true), "OpenAI speaks first")
        XCTAssertFalse(openAI.streamsAfterOpening)
        XCTAssertEqual(openAI.decode(#"{"type":"session.updated","session":{"id":"s"}}"#), [.sessionReady])
        XCTAssertEqual(
            openAI.decode(#"{"type":"session.output_transcript.delta","delta":" hi"}"#),
            [.translationDelta(" hi")]
        )
        XCTAssertEqual(openAI.decode(#"{"type":"session.output_audio.delta","delta":"AAAA"}"#), [.discardedAudio])
        guard case .text(let audio) = openAI.audioMessage(pcm16: Data([0, 1])) else {
            return XCTFail("OpenAI takes audio as base64 text")
        }
        XCTAssertTrue(audio.contains("session.input_audio_buffer.append"))
    }
}

final class ProvisionalTextTests: XCTestCase {
    func testProvisionalTextIsShownButNeverCommitted() {
        var assembler = TranslateDeltaAssembler()

        _ = assembler.appendSource("Das", at: 0)
        let outputs = assembler.setProvisional(source: " passt", translation: "That", at: 0.1)

        guard case .draft(let draft?)? = outputs.last else {
            return XCTFail("expected a draft")
        }
        XCTAssertEqual(draft.sourceText, "Das passt")
        XCTAssertEqual(draft.translatedText, "That")

        // The session ends before the words settle: only what was final is kept.
        let flushed = assembler.flush(at: 5)
        guard case .sentence(let sentence)? = flushed.first else {
            return XCTFail("expected a sentence")
        }
        XCTAssertEqual(sentence.sourceText, "Das")
    }

    func testUnchangedProvisionalTextProducesNoNewDraft() {
        var assembler = TranslateDeltaAssembler()
        _ = assembler.setProvisional(source: "Hallo", translation: "", at: 0)

        XCTAssertTrue(assembler.setProvisional(source: "Hallo", translation: "", at: 0.2).isEmpty)
        XCTAssertFalse(assembler.setProvisional(source: "", translation: "", at: 0.4).isEmpty)
    }
}

@MainActor
final class SonioxEngineModelTests: XCTestCase {
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: [String: String] = [:]
        func hasSecret(for account: String) -> Bool { lock.withLock { secrets[account] != nil } }
        func secret(for account: String) -> String? { lock.withLock { secrets[account] } }
        func setSecret(_ secret: String, for account: String) throws { lock.withLock { secrets[account] = secret } }
        func removeSecret(for account: String) throws { lock.withLock { secrets[account] = nil } }
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-soniox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(secrets: SecretStore) -> AppModel {
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: [], microphones: [])
            }),
            secretStore: secrets,
            cloudConnectionRegistry: CloudConnectionRegistry()
        )
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"
        return model
    }

    func testTheTwoProvidersKeepSeparateKeysAndNeitherReachesTheSettingsFolder() throws {
        let secrets = MemorySecrets()
        let model = makeModel(secrets: secrets)
        XCTAssertFalse(model.hasAPIKey(for: .sonioxTranslate))

        XCTAssertTrue(model.saveAPIKey("  soniox-secret-456 ", for: .sonioxTranslate))
        model.recognitionEngine = .sonioxTranslate

        XCTAssertTrue(model.hasSonioxAPIKey)
        XCTAssertFalse(model.hasOpenAIAPIKey, "a Soniox key is not an OpenAI key")
        XCTAssertEqual(secrets.secret(for: SecretAccount.sonioxAPIKey), "soniox-secret-456")
        XCTAssertNil(secrets.secret(for: SecretAccount.openAIAPIKey))

        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(contents.contains("soniox-secret-456"), "\(file.lastPathComponent) holds the key")
        }

        model.removeAPIKey(for: .sonioxTranslate)
        XCTAssertFalse(model.hasSonioxAPIKey)
    }

    func testTheEngineChoiceIsKeptAndCountsAsACloudEngine() {
        let secrets = MemorySecrets()
        makeModel(secrets: secrets).recognitionEngine = .sonioxTranslate

        let relaunched = makeModel(secrets: secrets)
        XCTAssertEqual(relaunched.recognitionEngine, .sonioxTranslate)
        XCTAssertTrue(relaunched.recognitionEngine.isCloud)
        XCTAssertTrue(RecognitionEngine.openAITranslate.isCloud)
        XCTAssertFalse(RecognitionEngine.onDevice.isCloud)
        XCTAssertEqual(RecognitionEngine.sonioxTranslate.displayName(in: "en"), "Cloud (Soniox)")
    }

    func testSonioxShowsItsOwnRateNameAndMissingKeyMessage() {
        let model = makeModel(secrets: MemorySecrets())
        model.recognitionEngine = .sonioxTranslate

        XCTAssertEqual(model.cloudHourlyRateText, "≈ $0.12 per hour while audio is streaming")
        XCTAssertEqual(
            model.providerText(model.localized(.cloudFallbackMissingKey)),
            "No Soniox API key saved. Using on-device mode."
        )
        XCTAssertEqual(model.providerText(model.localized(.openAIAPIKey), for: .sonioxTranslate), "Soniox API key")
        XCTAssertEqual(model.providerText(model.localized(.openAIAPIKey), for: .openAITranslate), "OpenAI API key")
        XCTAssertTrue(model.cloudEngineHintText.contains("Soniox"))
    }

    func testSonioxUsageIsCountedAtItsOwnPrice() throws {
        let key = CloudUsageLedger.dayKey(for: Date())
        let usage = #"{"secondsByDay":{"\#(key)":600},"transcribedSecondsByDay":{"\#(key)":0},"sonioxSecondsByDay":{"\#(key)":3600}}"#
        try Data(usage.utf8).write(to: directory.appendingPathComponent("cloud-usage.json"))

        let model = makeModel(secrets: MemorySecrets())

        // OpenAI: 10 min x $0.034 = $0.34. Soniox: 60 min x $0.002 = $0.12.
        XCTAssertEqual(model.cloudUsageTodayText, "Today: 70 min ≈ $0.46")

        var ledger = CloudUsageLedger()
        ledger.addSoniox(seconds: 90, on: Date())
        XCTAssertEqual(ledger.sonioxSeconds(on: Date()), 90)
        XCTAssertEqual(ledger.seconds(on: Date()), 0, "kept apart from OpenAI's seconds")
        XCTAssertEqual(
            CloudUsageLedger.estimatedCostUSD(seconds: 0, transcribedSeconds: 0, sonioxSeconds: 3_600),
            0.12,
            accuracy: 0.0001
        )
    }
}
