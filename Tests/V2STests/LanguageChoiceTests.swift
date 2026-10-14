import XCTest
@testable import v2s

@MainActor
final class LanguageChoiceTests: XCTestCase {
    private struct Keys: SecretStore {
        var stored: Set<String> = []
        func hasSecret(for account: String) -> Bool { stored.contains(account) }
        func secret(for account: String) -> String? { stored.contains(account) ? "test-key" : nil }
        func setSecret(_ secret: String, for account: String) throws {}
        func removeSecret(for account: String) throws {}
    }

    private let safari = InputSource(id: "app:com.apple.Safari", name: "Safari", detail: "com.apple.Safari", category: .application)
    private var directory: URL!
    private var registry: CloudConnectionRegistry!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("untertitel-languages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry = CloudConnectionRegistry()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Safari is running and chosen. Starts never reach the capture in these tests:
    /// each is stopped by its language check first.
    private func makeModel(keys: Set<String> = []) -> AppModel {
        let safari = self.safari
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: [safari], microphones: [])
            }),
            secretStore: Keys(stored: keys),
            cloudConnectionRegistry: registry
        )
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"
        model.chooseSources([safari.id])
        return model
    }

    // MARK: Spoken language

    func testAutoDetectIsTheDefaultSpokenLanguageAndComesFirst() {
        let model = makeModel()

        XCTAssertEqual(model.inputLanguageID, "auto")
        XCTAssertEqual(model.outputLanguageID, "en")
        XCTAssertEqual(model.spokenLanguageOptions.first?.id, "auto")
        XCTAssertEqual(model.languageName(for: "auto"), "Auto-detect")
        XCTAssertEqual(LanguageCatalog.displayName(for: "auto", in: "de"), "Automatisch erkennen")
    }

    func testOnDeviceCannotStartOnAutoDetectAndSaysSo() async {
        let model = makeModel()
        model.recognitionEngine = .onDevice
        let message = "On-device subtitles cannot detect the language. Choose the spoken language, or use a cloud engine."

        XCTAssertEqual(model.spokenLanguageNotice, message)
        XCTAssertTrue(model.spokenLanguageNoticeBlocksStart)

        await model.startSession()

        XCTAssertNotEqual(model.sessionState, .running)
        XCTAssertEqual(model.statusMessage, message)

        model.inputLanguageSelectionBinding.wrappedValue = "de"
        XCTAssertNil(model.spokenLanguageNotice)
        XCTAssertFalse(model.spokenLanguageNoticeBlocksStart)
    }

    func testOpenAIFindsTheSpokenLanguageItself() {
        let model = makeModel()
        model.recognitionEngine = .openAITranslate

        XCTAssertEqual(model.spokenLanguageNotice, "OpenAI detects the spoken language by itself.")
        XCTAssertFalse(model.spokenLanguageNoticeBlocksStart)
    }

    func testSonioxTakesAChosenSpokenLanguageAsAHint() {
        let model = makeModel()
        model.recognitionEngine = .sonioxTranslate
        XCTAssertNil(model.spokenLanguageNotice, "Auto-detect needs no explanation")
        XCTAssertEqual(model.spokenLanguageOptions.count, 61, "Auto-detect and Soniox's 60 languages")

        model.inputLanguageSelectionBinding.wrappedValue = "sw"
        XCTAssertEqual(model.inputLanguageID, "sw", "a language only Soniox knows")
        XCTAssertEqual(
            model.spokenLanguageNotice,
            "Soniox detects the spoken language. A language chosen here is used as a hint."
        )
    }

    // MARK: Subtitle language

    func testEachEngineOffersItsOwnSubtitleLanguages() {
        let model = makeModel()

        model.recognitionEngine = .openAITranslate
        XCTAssertEqual(
            Set(model.subtitleLanguageOptions.map(\.id)),
            ["en", "es", "pt", "fr", "ja", "ru", "zh-Hans", "de", "ko", "hi", "id", "vi", "it"]
        )

        model.recognitionEngine = .sonioxTranslate
        XCTAssertEqual(model.subtitleLanguageOptions.count, 60)
        XCTAssertTrue(model.subtitleLanguageOptions.contains(where: { $0.id == "sw" }))

        model.recognitionEngine = .onDevice
        XCTAssertEqual(model.subtitleLanguageOptions.map(\.id), model.translationLanguageOptions.map(\.id))
    }

    func testACloudEngineDoesNotStartInASubtitleLanguageItCannotMake() async {
        let model = makeModel(keys: [SecretAccount.openAIAPIKey])
        model.recognitionEngine = .openAITranslate
        model.outputLanguageSelectionBinding.wrappedValue = "nl"
        let message = "OpenAI cannot make subtitles in Dutch. Choose another subtitle language."

        XCTAssertEqual(model.subtitleLanguageNotice, message)
        XCTAssertTrue(model.subtitleLanguageOptions.contains(where: { $0.id == "nl" }), "the choice stays visible")

        await model.startSession()

        XCTAssertNotEqual(model.sessionState, .running)
        XCTAssertEqual(model.statusMessage, message)
        XCTAssertEqual(registry.openCount, 0, "nothing was connected")

        model.recognitionEngine = .sonioxTranslate
        XCTAssertNil(model.subtitleLanguageNotice, "Soniox can")
    }

    func testTheConfirmationLabelNamesTheSubtitleLanguage() {
        let model = makeModel()

        XCTAssertEqual(model.toggleConfirmationText(for: .on), "Subtitles on – Safari – → English")
        model.outputLanguageSelectionBinding.wrappedValue = "fr"
        XCTAssertEqual(model.toggleConfirmationText(for: .on), "Subtitles on – Safari – → French")
        model.chooseSources([])
        XCTAssertEqual(model.toggleConfirmationText(for: .on), "Subtitles on → French")
    }

    func testChangingALanguageWhileStoppedStartsNothing() {
        let model = makeModel()

        model.outputLanguageSelectionBinding.wrappedValue = "de"
        model.inputLanguageSelectionBinding.wrappedValue = "fr"

        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertEqual(model.outputLanguageID, "de")
        XCTAssertEqual(model.inputLanguageID, "fr")
    }

    // MARK: Codes and detection

    func testEachEngineGetsItsOwnLanguageCodes() {
        XCTAssertEqual(RecognitionEngine.openAITranslate.cloudSubtitleLanguageCode(for: "zh-Hans"), "zh")
        XCTAssertEqual(RecognitionEngine.openAITranslate.cloudSubtitleLanguageCode(for: "de"), "de")
        XCTAssertNil(RecognitionEngine.openAITranslate.cloudSubtitleLanguageCode(for: "nl"))
        XCTAssertEqual(RecognitionEngine.sonioxTranslate.cloudSubtitleLanguageCode(for: "nb"), "no")
        XCTAssertEqual(RecognitionEngine.sonioxTranslate.cloudSubtitleLanguageCode(for: "sw"), "sw")
        XCTAssertNil(RecognitionEngine.sonioxTranslate.cloudSubtitleLanguageCode(for: "yue"))
        XCTAssertNil(RecognitionEngine.sonioxTranslate.cloudSubtitleLanguageCode(for: "zh-Hant"))
        XCTAssertNil(RecognitionEngine.onDevice.cloudSubtitleLanguageCode(for: "en"))
    }

    func testTheEngineListsHaveNoDuplicates() {
        XCTAssertEqual(LanguageCatalog.openAISubtitleLanguageIDs.count, 13)
        XCTAssertEqual(Set(LanguageCatalog.openAISubtitleLanguageIDs).count, 13)
        XCTAssertEqual(LanguageCatalog.sonioxLanguageIDs.count, 60)
        XCTAssertEqual(Set(LanguageCatalog.sonioxLanguageIDs).count, 60)
        XCTAssertTrue(Set(LanguageCatalog.openAISubtitleLanguageIDs).isSubset(of: Set(LanguageCatalog.sonioxLanguageIDs)))
    }

    func testTheSpokenLanguageIsFoundOnlyInEnoughText() {
        XCTAssertNil(LanguageCatalog.dominantLanguageID(in: "Ja, gut."))
        XCTAssertEqual(
            LanguageCatalog.dominantLanguageID(in: "Wir sollten das Angebot bis Freitag noch einmal durchgehen."),
            "de"
        )
    }

    // MARK: Interface text

    func testTheNewTextsExistInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .autoDetect, .spokenLanguage, .onDeviceNeedsSpokenLanguage, .openAIDetectsSpokenLanguage,
            .sonioxSpokenLanguageHint, .cloudSubtitleLanguageUnsupportedFormat, .subtitlesOnTargetFormat,
            .subtitlesOnSourceFormat, .cloudEngineRatesAutoFormat,
        ]
        for language in LanguageCatalog.interface {
            for key in keys {
                let text = AppLocalization.string(key, languageID: language.id)
                XCTAssertFalse(text.isEmpty, "\(language.id) \(key)")
                XCTAssertNotEqual(text, "\(key)", "\(language.id) \(key)")
                XCTAssertFalse(text.contains("\u{2014}"), "\(language.id) \(key)")
            }
            // Arabic wraps each inserted name in direction isolates.
            let label = AppLocalization.string(.subtitlesOnSourceFormat, languageID: language.id, "Safari", "LANG")
                .replacingOccurrences(of: "\u{2068}", with: "")
                .replacingOccurrences(of: "\u{2069}", with: "")
            XCTAssertTrue(label.contains("Safari") && label.hasSuffix("→ LANG"), "\(language.id): \(label)")
        }
    }
}
