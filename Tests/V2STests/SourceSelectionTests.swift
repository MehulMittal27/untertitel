import Combine
import XCTest
@testable import v2s

/// The app never chooses what to listen to by itself: a session runs on a source the
/// user selected, or on the one the last session used.
@MainActor
final class SourceSelectionTests: XCTestCase {
    private struct NoSecrets: SecretStore {
        func hasSecret(for account: String) -> Bool { false }
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String, for account: String) throws {}
        func removeSecret(for account: String) throws {}
    }

    /// The apps "running" in a test. Activity Monitor sorts first, as on a real Mac.
    private final class RunningApps {
        var applications: [InputSource]
        init(_ applications: [InputSource]) { self.applications = applications }
    }

    private let activityMonitor = InputSource(
        id: "app:com.apple.ActivityMonitor",
        name: "Activity Monitor",
        detail: "com.apple.ActivityMonitor",
        category: .application
    )
    private let zoom = InputSource(id: "app:us.zoom.xos", name: "zoom.us", detail: "us.zoom.xos", category: .application)
    private let chrome = InputSource(
        id: "app:com.google.Chrome",
        name: "Google Chrome",
        detail: "com.google.Chrome",
        category: .application
    )

    private var settingsURL: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-source-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
    }

    private func makeModel(running: RunningApps) -> AppModel {
        AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: running.applications, microphones: [])
            }),
            secretStore: NoSecrets()
        )
    }

    private func storedSettings() throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
    }

    private func chooseSourceMessage(for model: AppModel) -> String {
        AppLocalization.string(.chooseInputSourceBeforeStarting, languageID: model.resolvedInterfaceLanguageID)
    }

    func testAFreshInstallSelectsNothingEvenWithAppsRunning() {
        let model = makeModel(running: RunningApps([activityMonitor, zoom]))

        XCTAssertTrue(model.selectedSourceIDs.isEmpty)
        XCTAssertTrue(model.selectedSources.isEmpty)
        XCTAssertNil(model.selectedSourceID)
        XCTAssertTrue(model.isSessionButtonDisabled, "Start cannot begin a session on an unchosen source")
        XCTAssertEqual(model.statusMessage, chooseSourceMessage(for: model))

        // Opening the popover or the refresh timer must not pick one either.
        model.refreshSources()
        model.refreshSources()
        XCTAssertTrue(model.selectedSources.isEmpty)
    }

    func testTheShortcutAsksInsteadOfListeningToTheFirstApp() {
        let model = makeModel(running: RunningApps([activityMonitor, zoom]))
        model.recognitionEngine = .openAITranslate
        var feedback: [SessionToggleFeedback] = []
        model.toggleFeedback.sink { feedback.append($0) }.store(in: &cancellables)
        var attentionRequests = 0
        model.onSessionStartNeedsAttention = { attentionRequests += 1 }

        model.toggleSessionFromHotkey()

        XCTAssertEqual(attentionRequests, 1)
        XCTAssertTrue(model.selectedSources.isEmpty)
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertNil(model.cloudEngineState, "no cloud session was opened")
        XCTAssertTrue(feedback.isEmpty)
        XCTAssertEqual(model.statusMessage, chooseSourceMessage(for: model))
    }

    func testAChosenSourceIsKeptAcrossRelaunch() throws {
        let running = RunningApps([activityMonitor, zoom])
        let model = makeModel(running: running)
        model.setSelectedSourceIDs([zoom.id])

        XCTAssertEqual(model.selectedSources, [zoom])
        XCTAssertFalse(model.isSessionButtonDisabled)

        let relaunched = makeModel(running: running)
        XCTAssertEqual(relaunched.selectedSources, [zoom])
    }

    func testWhenTheChosenAppQuitsNothingElseIsSelected() {
        let running = RunningApps([activityMonitor, zoom])
        let model = makeModel(running: running)
        model.setSelectedSourceIDs([zoom.id])

        running.applications = [activityMonitor]
        model.refreshSources()

        XCTAssertTrue(model.selectedSources.isEmpty, "Activity Monitor must not take Zoom's place")
        XCTAssertEqual(model.statusMessage, chooseSourceMessage(for: model))
    }

    func testTheLastSessionSourceIsUsedWhenNothingIsSelected() throws {
        let running = RunningApps([activityMonitor, zoom])
        let model = makeModel(running: running)
        model.setSelectedSourceIDs([zoom.id])
        model.rememberSessionSources([zoom])
        XCTAssertEqual(try storedSettings().lastSessionSourceIDs, [zoom.id])

        // Zoom quits, then comes back for the next call.
        running.applications = [activityMonitor]
        model.refreshSources()
        XCTAssertTrue(model.selectedSources.isEmpty)

        running.applications = [activityMonitor, zoom]
        model.refreshSources()
        XCTAssertEqual(model.selectedSources, [zoom])

        // The same after a relaunch, even though the saved selection was empty.
        running.applications = [activityMonitor]
        model.refreshSources()
        running.applications = [activityMonitor, zoom]
        let relaunched = makeModel(running: running)
        XCTAssertEqual(relaunched.selectedSources, [zoom])
    }

    func testTheLastSessionSourceIsNotUsedWhileItIsNotRunning() {
        let running = RunningApps([activityMonitor, zoom])
        let model = makeModel(running: running)
        model.rememberSessionSources([zoom])
        var attentionRequests = 0
        model.onSessionStartNeedsAttention = { attentionRequests += 1 }

        running.applications = [activityMonitor, chrome]
        model.toggleSessionFromHotkey()

        XCTAssertTrue(model.selectedSources.isEmpty)
        XCTAssertEqual(attentionRequests, 1)
        XCTAssertEqual(model.sessionState, .idle)
    }

    func testAnExplicitChoiceWinsOverTheLastSessionSource() {
        let running = RunningApps([activityMonitor, chrome, zoom])
        let model = makeModel(running: running)
        model.rememberSessionSources([zoom])

        model.setSelectedSourceIDs([chrome.id])
        model.refreshSources()

        XCTAssertEqual(model.selectedSources, [chrome])
    }

    func testCloudModeFallsBackToOneSourceOnly() {
        let running = RunningApps([activityMonitor, chrome, zoom])
        let model = makeModel(running: running)
        model.rememberSessionSources([chrome, zoom])
        model.recognitionEngine = .openAITranslate

        model.refreshSources()

        XCTAssertEqual(model.selectedSources.count, 1, "one billed stream at a time")
        XCTAssertTrue([chrome, zoom].contains(model.selectedSources[0]))
    }

    /// Earlier versions saved the first app in the list as if the user had chosen it.
    func testASelectionSavedByAnEarlierVersionIsNotTrusted() throws {
        let json = """
        {
          "selectedSourceID": "app:com.apple.ActivityMonitor",
          "selectedSourceIDs": ["app:com.apple.ActivityMonitor"],
          "inputLanguageID": "de",
          "outputLanguageID": "en",
          "recognitionEngine": "openAITranslate"
        }
        """
        try Data(json.utf8).write(to: settingsURL)
        XCTAssertNil(try storedSettings().lastSessionSourceIDs)

        let model = makeModel(running: RunningApps([activityMonitor, zoom]))

        XCTAssertTrue(model.selectedSources.isEmpty)
        XCTAssertEqual(model.recognitionEngine, .openAITranslate, "the other settings are kept")

        // Asked once: the file is marked, so a choice made from now on is kept.
        let stored = try storedSettings()
        XCTAssertEqual(stored.lastSessionSourceIDs, [])
        XCTAssertTrue(stored.selectedSourceIDs.isEmpty)

        model.setSelectedSourceIDs([zoom.id])
        let relaunched = makeModel(running: RunningApps([activityMonitor, zoom]))
        XCTAssertEqual(relaunched.selectedSources, [zoom])
    }
}
