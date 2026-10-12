import Combine
import XCTest
@testable import v2s

final class CallAppDetectorTests: XCTestCase {
    private func candidate(
        _ bundleID: String,
        _ activity: AppAudioActivity = .idle,
        approved: Bool = true,
        activated: TimeInterval? = nil
    ) -> CallAppCandidate {
        CallAppCandidate(
            sourceID: "app:\(bundleID)",
            bundleID: bundleID,
            activity: activity,
            isApproved: approved,
            lastActivatedAt: activated.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func testAnAppInACallBeatsABrowserPlayingMusic() {
        let detection = CallAppDetector.detect([
            candidate("com.google.Chrome", .playing),
            candidate("us.zoom.xos", .inCall),
        ])

        XCTAssertEqual(detection.pick, "app:us.zoom.xos")
        XCTAssertNil(detection.suggestion)
    }

    func testAMeetTabAloneInSafariPicksSafari() {
        let detection = CallAppDetector.detect([
            candidate("com.apple.Safari", .inCall),
            candidate("com.google.Chrome", .idle),
        ])

        XCTAssertEqual(detection.pick, "app:com.apple.Safari")
    }

    func testACallInOneBrowserBeatsMusicInSafari() {
        let detection = CallAppDetector.detect([
            candidate("com.apple.Safari", .playing),
            candidate("com.google.Chrome", .inCall),
        ])

        XCTAssertEqual(detection.pick, "app:com.google.Chrome", "what the apps are doing outranks the preferred order")
    }

    func testWithNothingToTellThemApartSafariComesFirst() {
        let detection = CallAppDetector.detect([
            candidate("com.google.Chrome", .playing),
            candidate("us.zoom.xos", .playing),
            candidate("com.apple.Safari", .playing),
        ])

        XCTAssertEqual(detection.pick, "app:com.apple.Safari")
        XCTAssertEqual(CallAppCatalog.bundleIDs.first, "com.apple.Safari")
    }

    func testDedicatedCallAppsComeBeforeOtherBrowsers() {
        let detection = CallAppDetector.detect([
            candidate("com.google.Chrome", .idle),
            candidate("com.apple.FaceTime", .idle),
        ])

        XCTAssertEqual(detection.pick, "app:com.apple.FaceTime")
    }

    func testAmongAppsOutsideTheListTheMostRecentlyUsedWins() {
        let detection = CallAppDetector.detect([
            candidate("com.example.older", .playing, activated: 100),
            candidate("com.example.newer", .playing, activated: 200),
        ])

        XCTAssertEqual(detection.pick, "app:com.example.newer")
    }

    func testAnUnapprovedAppIsNeverPicked() {
        let detection = CallAppDetector.detect([
            candidate("us.zoom.xos", .inCall, approved: false),
        ])

        XCTAssertNil(detection.pick)
        XCTAssertEqual(detection.suggestion, "app:us.zoom.xos", "it is offered instead")
        XCTAssertEqual(detection.suggestionActivity, .inCall)
    }

    func testAnUnapprovedCallWinsOverAnIdleApprovedAppByOfferingNotStarting() {
        let detection = CallAppDetector.detect([
            candidate("com.apple.Safari", .idle),
            candidate("com.apple.FaceTime", .inCall, approved: false),
        ])

        XCTAssertNil(detection.pick, "starting on Safari would show nothing and could bill for it later")
        XCTAssertEqual(detection.suggestion, "app:com.apple.FaceTime")
    }

    func testAnApprovedCallIsPickedEvenWhenAnotherCallAppIsAlsoInACall() {
        let detection = CallAppDetector.detect([
            candidate("com.apple.Safari", .inCall),
            candidate("com.apple.FaceTime", .inCall, approved: false),
        ])

        XCTAssertEqual(detection.pick, "app:com.apple.Safari")
        XCTAssertEqual(detection.suggestion, "app:com.apple.FaceTime")
    }

    func testMusicInAnUnapprovedBrowserIsNotOfferedWhileAnApprovedAppIsRunning() {
        let detection = CallAppDetector.detect([
            candidate("com.apple.Safari", .idle),
            candidate("com.google.Chrome", .playing, approved: false),
        ])

        XCTAssertEqual(detection.pick, "app:com.apple.Safari")
        XCTAssertNil(detection.suggestion)
    }

    func testWithNothingApprovedAPlayingCallAppIsOffered() {
        let detection = CallAppDetector.detect([
            candidate("com.google.Chrome", .playing, approved: false),
            candidate("com.example.game", .playing, approved: false),
        ])

        XCTAssertNil(detection.pick)
        XCTAssertEqual(detection.suggestion, "app:com.google.Chrome", "apps outside the list are never offered")
    }

    func testNothingRunningGivesNothing() {
        XCTAssertEqual(CallAppDetector.detect([]), CallAppDetection(pick: nil, suggestion: nil))
        XCTAssertEqual(
            CallAppDetector.detect([candidate("com.google.Chrome", .idle, approved: false)]),
            CallAppDetection(pick: nil, suggestion: nil)
        )
    }

    func testMicrophoneAndSpeakerTogetherMeanACall() {
        XCTAssertEqual(AppAudioActivity(isRunningInput: true, isRunningOutput: true), .inCall)
        XCTAssertEqual(AppAudioActivity(isRunningInput: false, isRunningOutput: true), .playing)
        XCTAssertEqual(AppAudioActivity(isRunningInput: true, isRunningOutput: false), .idle, "dictation is not a call")
        XCTAssertEqual(AppAudioActivity(isRunningInput: false, isRunningOutput: false), .idle)
    }
}

@MainActor
final class AutomaticSourceSelectionTests: XCTestCase {
    private struct NoSecrets: SecretStore {
        func hasSecret(for account: String) -> Bool { false }
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String, for account: String) throws {}
        func removeSecret(for account: String) throws {}
    }

    /// The apps "running" in a test and what each is doing with audio.
    private final class Desk {
        var applications: [InputSource]
        var activities: [String: AppAudioActivity] = [:]
        init(_ applications: [InputSource]) { self.applications = applications }
    }

    private let safari = InputSource(id: "app:com.apple.Safari", name: "Safari", detail: "com.apple.Safari", category: .application)
    private let chrome = InputSource(
        id: "app:com.google.Chrome",
        name: "Google Chrome",
        detail: "com.google.Chrome",
        category: .application
    )
    private let faceTime = InputSource(id: "app:com.apple.FaceTime", name: "FaceTime", detail: "com.apple.FaceTime", category: .application)
    private let activityMonitor = InputSource(
        id: "app:com.apple.ActivityMonitor",
        name: "Activity Monitor",
        detail: "com.apple.ActivityMonitor",
        category: .application
    )

    private var settingsURL: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-auto-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
    }

    private func makeModel(_ desk: Desk) -> AppModel {
        AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: desk.applications, microphones: [])
            }),
            secretStore: NoSecrets(),
            audioActivityProbe: { sources in
                desk.activities.filter { id, _ in sources.contains(where: { $0.id == id }) }
            }
        )
    }

    func testAutomaticSelectionIsOnByDefaultAndPicksNothingUntilAnAppIsApproved() {
        let desk = Desk([activityMonitor, chrome, safari])
        desk.activities = [safari.id: .inCall]
        let model = makeModel(desk)

        XCTAssertTrue(model.selectsSourceAutomatically)
        XCTAssertTrue(model.approvedSourceIDs.isEmpty)
        XCTAssertTrue(model.selectedSources.isEmpty, "Safari is in a call, but has not been approved")
        XCTAssertEqual(model.suggestedSource, safari, "so it is offered")
        XCTAssertEqual(model.suggestedSourceText, "Safari is in a call")
    }

    func testTheShortcutNeverStartsOnAnOfferedApp() {
        let desk = Desk([chrome, safari])
        desk.activities = [safari.id: .inCall]
        let model = makeModel(desk)
        model.recognitionEngine = .openAITranslate
        var attentionRequests = 0
        model.onSessionStartNeedsAttention = { attentionRequests += 1 }
        var feedback: [SessionToggleFeedback] = []
        model.toggleFeedback.sink { feedback.append($0) }.store(in: &cancellables)

        model.toggleSessionFromHotkey()

        XCTAssertEqual(attentionRequests, 1, "the popover opens with the offer")
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertTrue(model.selectedSources.isEmpty)
        XCTAssertTrue(feedback.isEmpty)
        XCTAssertEqual(model.suggestedSource, safari)
    }

    func testAcceptingTheOfferApprovesAndSelectsTheAppWithoutStarting() {
        let desk = Desk([chrome, safari])
        desk.activities = [safari.id: .inCall]
        let model = makeModel(desk)

        model.useSuggestedSource()

        XCTAssertEqual(model.approvedSourceIDs, [safari.id])
        XCTAssertEqual(model.selectedSources, [safari])
        XCTAssertNil(model.suggestedSource)
        XCTAssertTrue(model.selectsSourceAutomatically, "accepting the detector's own offer keeps it on")
        XCTAssertEqual(model.sessionState, .idle)
        XCTAssertEqual(makeModel(desk).approvedSourceIDs, [safari.id], "the approval is saved")
    }

    func testAmongApprovedAppsTheOneInACallIsPicked() {
        let desk = Desk([chrome, faceTime, safari])
        let model = makeModel(desk)
        model.chooseSources([safari.id])
        model.chooseSources([chrome.id])
        model.selectsSourceAutomatically = true

        desk.activities = [chrome.id: .playing, safari.id: .inCall]
        model.refreshSources()
        XCTAssertEqual(model.selectedSources, [safari])

        desk.activities = [chrome.id: .inCall, safari.id: .playing]
        model.refreshSources()
        XCTAssertEqual(model.selectedSources, [chrome])

        desk.activities = [:]
        model.refreshSources()
        XCTAssertEqual(model.selectedSources, [safari], "nothing to tell them apart: Safari first")
    }

    func testChoosingAnAppByHandApprovesItAndSwitchesAutomaticOff() {
        let desk = Desk([chrome, safari])
        let model = makeModel(desk)

        model.chooseSources([chrome.id])

        XCTAssertFalse(model.selectsSourceAutomatically)
        XCTAssertEqual(model.approvedSourceIDs, [chrome.id])

        // The manual choice holds, whatever the apps are doing.
        desk.activities = [safari.id: .inCall]
        model.refreshSources()
        XCTAssertEqual(model.selectedSources, [chrome])
        XCTAssertNil(model.suggestedSource, "no offers while the user is choosing by hand")

        let relaunched = makeModel(desk)
        XCTAssertFalse(relaunched.selectsSourceAutomatically)
        XCTAssertEqual(relaunched.selectedSources, [chrome])
    }

    func testWhenTheApprovedAppIsNotRunningNothingIsSelected() {
        let desk = Desk([activityMonitor, safari])
        let model = makeModel(desk)
        model.chooseSources([safari.id])
        model.selectsSourceAutomatically = true
        XCTAssertEqual(model.selectedSources, [safari])

        desk.applications = [activityMonitor]
        model.refreshSources()

        XCTAssertTrue(model.selectedSources.isEmpty, "never an app the user has not approved")
        XCTAssertTrue(model.isSessionButtonDisabled)
    }

    func testRemovingAnApprovalStopsTheAppBeingPicked() {
        let desk = Desk([safari])
        desk.activities = [safari.id: .inCall]
        let model = makeModel(desk)
        model.useSuggestedSource()
        XCTAssertEqual(model.selectedSources, [safari])

        model.removeApprovedSource(safari.id)

        XCTAssertTrue(model.approvedSourceIDs.isEmpty)
        XCTAssertTrue(model.selectedSources.isEmpty)
        XCTAssertEqual(model.suggestedSource, safari, "it is back to being offered")
    }

    func testASettingsFileFromBeforeApprovalsTreatsUsedSourcesAsApproved() throws {
        let json = """
        {
          "selectedSourceIDs": ["app:com.apple.Safari"],
          "lastSessionSourceIDs": ["app:com.google.Chrome"],
          "inputLanguageID": "de",
          "outputLanguageID": "en"
        }
        """
        try Data(json.utf8).write(to: settingsURL)

        let model = makeModel(Desk([chrome, safari]))

        XCTAssertEqual(Set(model.approvedSourceIDs), [chrome.id, safari.id])
        XCTAssertTrue(model.selectsSourceAutomatically)
    }

    func testTheConfirmationLabelNamesTheApp() {
        let desk = Desk([safari])
        let model = makeModel(desk)
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"
        model.chooseSources([safari.id])

        XCTAssertEqual(model.toggleConfirmationText(for: .on), "Subtitles on - Safari")
        XCTAssertEqual(model.toggleConfirmationText(for: .off), "Subtitles off")
    }
}
