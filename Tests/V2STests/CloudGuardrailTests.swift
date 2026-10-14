import Combine
import XCTest
@testable import v2s

private struct NoSecrets: SecretStore {
    func hasSecret(for account: String) -> Bool { false }
    func secret(for account: String) -> String? { nil }
    func setSecret(_ secret: String, for account: String) throws {}
    func removeSecret(for account: String) throws {}
}

/// A connection the model did not open itself, as a leaked or stuck one would be.
private final class StraySocket: OpenAITranslateSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    var handshakeStatusCode: Int? { 101 }
    func resume() {}
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }
    func send(data: Data, completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }
    func receive(completion: @escaping @Sendable (Result<String, Error>) -> Void) {}
    func cancel() { lock.withLock { cancelled = true } }
}

@MainActor
final class CloudGuardrailTests: XCTestCase {
    private var directory: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-cloud-guardrails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(registry: CloudConnectionRegistry = CloudConnectionRegistry()) -> AppModel {
        AppModel(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: [], microphones: [])
            }),
            secretStore: NoSecrets(),
            cloudConnectionRegistry: registry
        )
    }

    private func journalLines() -> [String] {
        CloudConnectionJournal(fileURL: directory.appendingPathComponent("cloud-connections.log")).lines()
    }

    private func waitForMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: Stop closes everything, and the icon follows the connection

    func testStopClosesEveryOpenConnectionAndRecordsIt() async {
        let registry = CloudConnectionRegistry()
        let model = makeModel(registry: registry)
        let stray = StraySocket()
        registry.register(stray)
        await waitForMainQueue()
        XCTAssertEqual(model.openCloudConnectionCount, 1)

        model.stopSession(trigger: .hotkey)

        XCTAssertTrue(stray.isCancelled, "closed on the spot, not after a delay")
        XCTAssertEqual(registry.openCount, 0)
        await waitForMainQueue()
        XCTAssertEqual(model.openCloudConnectionCount, 0)
        XCTAssertEqual(journalLines().count, 1)
        XCTAssertTrue(journalLines()[0].hasSuffix("Session stopped by shortcut, 1 connection(s) closed"))
    }

    func testTheIconShowsBillingForAsLongAsAConnectionIsOpenEvenWithNoSession() async {
        let registry = CloudConnectionRegistry()
        let model = makeModel(registry: registry)
        func icon() -> StatusItemAppearance {
            StatusItemAppearance.resolve(
                sessionState: model.sessionState,
                cloudEngineState: model.cloudEngineState,
                hasOpenCloudConnection: model.openCloudConnectionCount > 0
            )
        }
        XCTAssertEqual(icon().tint, .template)

        let stray = StraySocket()
        registry.register(stray)
        await waitForMainQueue()

        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertEqual(icon().tint, .billing, "no session, but a connection is open")
        XCTAssertEqual(icon().title, "$")

        registry.unregister(stray)
        await waitForMainQueue()
        XCTAssertEqual(icon().tint, .template)
    }

    func testStoppingWithNothingRunningWritesNothingToTheLog() {
        let model = makeModel()

        model.stopSession()

        XCTAssertTrue(journalLines().isEmpty)
    }

    // MARK: Automatic resume is opt-in

    func testAutomaticResumeIsOffUnlessSwitchedOnAndTheChoiceIsKept() throws {
        let model = makeModel()
        XCTAssertFalse(model.cloudResumesAutomatically)

        model.cloudResumesAutomatically = true
        XCTAssertTrue(makeModel().cloudResumesAutomatically)

        let legacy = #"{ "inputLanguageID": "de", "outputLanguageID": "en", "recognitionEngine": "openAITranslate" }"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertFalse(settings.cloudResumesAutomatically, "an older settings file does not opt in")
    }

    // MARK: Cost of the original-language line

    func testTheOriginalLineIsOnlyRequestedWhenItIsShown() {
        let model = makeModel()

        model.subtitleDisplayMode = .both
        XCTAssertTrue(model.cloudTranscribesSource)
        model.subtitleDisplayMode = .originalOnly
        XCTAssertTrue(model.cloudTranscribesSource)
        model.subtitleDisplayMode = .translatedOnly
        XCTAssertFalse(model.cloudTranscribesSource, "no German line, no second model")
    }

    func testTheHourlyRateFollowsTheDisplaySetting() {
        let model = makeModel()
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"

        model.subtitleDisplayMode = .both
        XCTAssertEqual(model.cloudHourlyRateText, "≈ $3.06 per hour while audio is streaming")

        model.subtitleDisplayMode = .translatedOnly
        XCTAssertEqual(model.cloudHourlyRateText, "≈ $2.04 per hour while audio is streaming")
    }

    func testSettingsShowsBothRatesWithTheLanguageNames() {
        let model = makeModel()
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"

        XCTAssertEqual(model.inputLanguageID, "auto")
        XCTAssertEqual(model.outputLanguageID, "en")
        XCTAssertEqual(model.cloudHourlyRatesText, "English only ≈ $2.04/h, with original line ≈ $3.06/h")

        model.inputLanguageSelectionBinding.wrappedValue = "de"
        XCTAssertEqual(model.cloudHourlyRatesText, "English only ≈ $2.04/h, with German line ≈ $3.06/h")
    }

    func testTodaysEstimateCountsBothModels() throws {
        // 10 minutes streamed, 4 of them with the original line.
        let usage = """
        {
          "secondsByDay": { "\(CloudUsageLedger.dayKey(for: Date()))": 600 },
          "transcribedSecondsByDay": { "\(CloudUsageLedger.dayKey(for: Date()))": 240 }
        }
        """
        try Data(usage.utf8).write(to: directory.appendingPathComponent("cloud-usage.json"))
        let model = makeModel()
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"

        // 10 x 0.034 + 4 x 0.017 = 0.408
        XCTAssertEqual(model.cloudUsageTodayText, "Today: 10 min ≈ $0.41")
    }

    func testEveryNewTextExistsInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .cloudEngineNoAudio, .cloudPausedResumeHintFormat, .cloudPausedResumeHint,
            .cloudAutoResumeSetting, .cloudAutoResumeHint, .cloudEngineRateFormat, .cloudEngineRatesFormat,
        ]

        for language in LanguageCatalog.interface {
            for key in keys {
                let text = AppLocalization.string(key, languageID: language.id)
                XCTAssertNotEqual(text, key.rawValue, "\(language.id) is missing \(key.rawValue)")
                if language.id != "en" {
                    XCTAssertNotEqual(
                        text,
                        AppLocalization.string(key, languageID: "en"),
                        "\(language.id) falls back to English for \(key.rawValue)"
                    )
                }
            }

            let rates = AppLocalization.string(.cloudEngineRatesFormat, languageID: language.id, "A", "2.04", "B", "3.06")
            XCTAssertTrue(rates.contains("2.04") && rates.contains("3.06"), "\(language.id): \(rates)")
            XCTAssertTrue(rates.contains("A") && rates.contains("B"), "\(language.id): \(rates)")
        }
    }
}

@MainActor
final class CloudConnectionJournalTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-journal-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("cloud-connections.log")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testEventsAreAppendedInOrderWithALocalTimestamp() {
        let journal = CloudConnectionJournal(fileURL: fileURL)
        let moment = Date(timeIntervalSince1970: 1_791_837_413)

        journal.record("Connection opened: first sound of the session", at: moment)
        journal.record("Connection closed: session stopped, 74.8 s of audio sent", at: moment.addingTimeInterval(75))

        let lines = CloudConnectionJournal(fileURL: fileURL).lines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("  Connection opened: first sound of the session"))
        XCTAssertTrue(lines[1].hasSuffix("  Connection closed: session stopped, 74.8 s of audio sent"))
        XCTAssertNotNil(
            lines[0].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{2}:\d{2}  "#, options: .regularExpression),
            lines[0]
        )
    }

    func testTheLogKeepsOnlyTheNewestLines() {
        let journal = CloudConnectionJournal(fileURL: fileURL)
        for index in 0..<(CloudConnectionJournal.maximumLineCount + 250) {
            journal.record("event \(index)")
        }

        journal.trim()

        let lines = journal.lines()
        XCTAssertEqual(lines.count, CloudConnectionJournal.maximumLineCount)
        XCTAssertTrue(lines.last?.hasSuffix("event \(CloudConnectionJournal.maximumLineCount + 249)") == true)
        XCTAssertTrue(lines.first?.hasSuffix("event 250") == true)
    }
}
