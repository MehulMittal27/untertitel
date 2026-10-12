import XCTest
@testable import v2s

private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    var failsOnWrite = false

    func hasSecret(for account: String) -> Bool {
        lock.withLock { secrets[account] != nil }
    }

    func secret(for account: String) -> String? {
        lock.withLock { secrets[account] }
    }

    func setSecret(_ secret: String, for account: String) throws {
        if failsOnWrite { throw KeychainStoreError(status: errSecNotAvailable) }
        lock.withLock { secrets[account] = secret }
    }

    func removeSecret(for account: String) throws {
        lock.withLock { secrets[account] = nil }
    }
}

@MainActor
final class CloudEngineSettingsTests: XCTestCase {
    private var settingsURL: URL!

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-cloud-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
    }

    private func makeModel(secretStore: SecretStore) -> AppModel {
        AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            secretStore: secretStore
        )
    }

    func testAPIKeyGoesToTheSecretStoreAndNeverIntoTheSettingsFolder() throws {
        let secretStore = InMemorySecretStore()
        let model = makeModel(secretStore: secretStore)
        XCTAssertFalse(model.hasOpenAIAPIKey)

        XCTAssertTrue(model.saveOpenAIAPIKey("  sk-secret-value-123  "))
        model.recognitionEngine = .openAITranslate

        XCTAssertTrue(model.hasOpenAIAPIKey)
        XCTAssertEqual(secretStore.secret(for: SecretAccount.openAIAPIKey), "sk-secret-value-123")

        let directory = settingsURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty, "changing the engine saved the settings")
        for file in files {
            let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(contents.contains("sk-secret-value-123"), "\(file.lastPathComponent) holds the key")
        }
    }

    func testRemovingTheKeyClearsIt() {
        let secretStore = InMemorySecretStore()
        let model = makeModel(secretStore: secretStore)
        model.saveOpenAIAPIKey("sk-secret-value-123")

        model.removeOpenAIAPIKey()

        XCTAssertFalse(model.hasOpenAIAPIKey)
        XCTAssertNil(secretStore.secret(for: SecretAccount.openAIAPIKey))
    }

    func testEmptyOrUnsavableKeyIsReportedAsNotSaved() {
        let secretStore = InMemorySecretStore()
        let model = makeModel(secretStore: secretStore)

        XCTAssertFalse(model.saveOpenAIAPIKey("   "))
        secretStore.failsOnWrite = true
        XCTAssertFalse(model.saveOpenAIAPIKey("sk-secret-value-123"))
        XCTAssertFalse(model.hasOpenAIAPIKey)
    }

    func testEngineChoiceIsRemembered() {
        let model = makeModel(secretStore: InMemorySecretStore())
        XCTAssertEqual(model.recognitionEngine, .onDevice)

        model.recognitionEngine = .openAITranslate

        XCTAssertEqual(makeModel(secretStore: InMemorySecretStore()).recognitionEngine, .openAITranslate)
    }

    func testCloudEngineKeepsASingleSource() {
        let model = makeModel(secretStore: InMemorySecretStore())
        model.setSelectedSourceIDs(["app:one", "app:two", "app:three"])
        XCTAssertEqual(model.selectedSourceIDs.count, 3, "on-device mode allows several sources")

        model.recognitionEngine = .openAITranslate
        XCTAssertEqual(model.selectedSourceIDs.count, 1, "switching to the cloud engine trims the selection")

        let kept = model.selectedSourceIDs
        model.setSelectedSourceIDs(kept.union(["app:four"]))
        XCTAssertEqual(model.selectedSourceIDs, ["app:four"], "a newly picked source replaces the old one")

        model.recognitionEngine = .onDevice
        model.setSelectedSourceIDs(["app:one", "app:two"])
        XCTAssertEqual(model.selectedSourceIDs.count, 2)
    }

    func testUsageTextShowsMinutesAndEstimatedCost() {
        let model = makeModel(secretStore: InMemorySecretStore())

        XCTAssertEqual(model.cloudSecondsStreamedToday, 0)
        XCTAssertTrue(model.cloudUsageTodayText.contains("0"))
        XCTAssertTrue(model.cloudUsageTodayText.contains("$"))
    }
}
