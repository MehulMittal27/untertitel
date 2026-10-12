import AppKit
import Combine
import XCTest
@testable import v2s

final class HotkeySettingsTests: XCTestCase {
    func testSettingsWrittenBeforeTheShortcutExistedGetTheDefaults() throws {
        let json = """
        {
          "inputLanguageID": "de",
          "outputLanguageID": "en",
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {},
          "recognitionEngine": "openAITranslate"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.toggleHotkey.binding, .defaultToggle)
        XCTAssertFalse(settings.playsToggleSound, "the sound is opt-in")
        XCTAssertTrue(settings.showsToggleLabel)
        XCTAssertEqual(settings.recognitionEngine, .openAITranslate)
    }

    func testAReboundShortcutSurvivesSavingAndLoading() throws {
        var settings = AppSettings.default
        let binding = HotkeyBinding(keyCode: HotkeyKeyCode.s, modifiers: [.control, .shift, .command])
        settings.toggleHotkey = HotkeySetting(binding: binding)
        settings.playsToggleSound = true
        settings.showsToggleLabel = false

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.toggleHotkey.binding, binding)
        XCTAssertTrue(decoded.playsToggleSound)
        XCTAssertFalse(decoded.showsToggleLabel)
    }

    func testAClearedShortcutStaysClearedInsteadOfComingBackAsTheDefault() throws {
        var settings = AppSettings.default
        settings.toggleHotkey = .cleared

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertNil(decoded.toggleHotkey.binding)
    }

    func testAnUnreadableShortcutEntryFallsBackToTheDefault() throws {
        let json = """
        { "inputLanguageID": "de", "outputLanguageID": "en", "toggleHotkey": "ctrl-alt-t" }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.toggleHotkey.binding, .defaultToggle)
    }
}

final class HotkeyToggleActionTests: XCTestCase {
    func testAPressWhileIdleStartsAndAPressWhileRunningStops() {
        XCTAssertEqual(
            HotkeyToggleAction.resolve(isRunning: false, isStartPending: false, hasSelectedSource: true),
            .start
        )
        XCTAssertEqual(
            HotkeyToggleAction.resolve(isRunning: true, isStartPending: false, hasSelectedSource: true),
            .stop
        )
    }

    func testAPressWhileAStartIsUnderWayIsIgnored() {
        XCTAssertEqual(
            HotkeyToggleAction.resolve(isRunning: false, isStartPending: true, hasSelectedSource: true),
            .ignore
        )
    }

    func testWithoutASourceNothingStartsAndTheUserIsAsked() {
        XCTAssertEqual(
            HotkeyToggleAction.resolve(isRunning: false, isStartPending: false, hasSelectedSource: false),
            .askForSource
        )
    }

    func testAPressOnASessionPausedForSilenceCarriesOnWithIt() {
        XCTAssertEqual(
            HotkeyToggleAction.resolve(
                isRunning: true,
                isStartPending: false,
                hasSelectedSource: true,
                isPausedAwaitingUser: true
            ),
            .resume
        )
        // Not running: "paused" means nothing, the press starts a session.
        XCTAssertEqual(
            HotkeyToggleAction.resolve(
                isRunning: false,
                isStartPending: false,
                hasSelectedSource: true,
                isPausedAwaitingUser: true
            ),
            .start
        )
    }

    func testRunningWinsEvenWithoutASourceSoASessionCanAlwaysBeStopped() {
        XCTAssertEqual(
            HotkeyToggleAction.resolve(isRunning: true, isStartPending: true, hasSelectedSource: false),
            .stop
        )
    }
}

private struct EmptySecretStore: SecretStore {
    func hasSecret(for account: String) -> Bool { false }
    func secret(for account: String) -> String? { nil }
    func setSecret(_ secret: String, for account: String) throws {}
    func removeSecret(for account: String) throws {}
}

@MainActor
final class HotkeyModelTests: XCTestCase {
    private var settingsURL: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-hotkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
    }

    /// No apps and no microphones: a model built from this can never open a live capture.
    private func makeModel() -> AppModel {
        AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: [], microphones: [])
            }),
            secretStore: EmptySecretStore()
        )
    }

    func testAFreshInstallHasTheDefaultShortcutLabelOnAndSoundOff() {
        let model = makeModel()

        XCTAssertEqual(model.toggleHotkey, .defaultToggle)
        XCTAssertTrue(model.showsToggleLabel)
        XCTAssertFalse(model.playsToggleSound)
        XCTAssertEqual(model.toggleHotkeyDisplayText?.hasPrefix("⌃⌥"), true)
    }

    func testRebindingAndClearingPersistAcrossRelaunch() {
        let binding = HotkeyBinding(keyCode: HotkeyKeyCode.s, modifiers: [.control, .command])
        let first = makeModel()
        first.toggleHotkey = binding
        first.playsToggleSound = true
        first.showsToggleLabel = false

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.toggleHotkey, binding)
        XCTAssertTrue(relaunched.playsToggleSound)
        XCTAssertFalse(relaunched.showsToggleLabel)

        relaunched.toggleHotkey = nil

        let relaunchedAgain = makeModel()
        XCTAssertNil(relaunchedAgain.toggleHotkey)
        XCTAssertNil(relaunchedAgain.toggleHotkeyDisplayText)
    }

    func testAPressWithNoSourceSelectedAsksForAttentionAndStartsNothing() {
        let model = makeModel()
        XCTAssertTrue(model.selectedSources.isEmpty)

        var feedback: [SessionToggleFeedback] = []
        model.toggleFeedback.sink { feedback.append($0) }.store(in: &cancellables)
        var attentionRequests = 0
        model.onSessionStartNeedsAttention = { attentionRequests += 1 }

        model.toggleSessionFromHotkey()

        XCTAssertEqual(attentionRequests, 1, "the popover is asked to open")
        XCTAssertEqual(model.sessionState, .idle, "asking is not an error")
        XCTAssertTrue(feedback.isEmpty, "nothing is announced when nothing started")
    }
}

@MainActor
final class HotkeyRecorderTests: XCTestCase {
    private func makeRecorder() -> HotkeyRecorder {
        HotkeyRecorder(rules: HotkeyBindingRules(systemShortcuts: {
            [HotkeyBinding(keyCode: HotkeyKeyCode.space, modifiers: .command)]
        }))
    }

    func testAValidCombinationIsAcceptedAndEndsRecording() {
        let recorder = makeRecorder()
        var accepted: [HotkeyBinding] = []
        recorder.start { accepted.append($0) }
        XCTAssertTrue(recorder.isRecording)

        recorder.handleKey(keyCode: HotkeyKeyCode.s, flags: [.control, .option])

        XCTAssertEqual(accepted, [HotkeyBinding(keyCode: HotkeyKeyCode.s, modifiers: [.control, .option])])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.issue)
    }

    func testARejectedCombinationSaysWhyAndKeepsListening() {
        let recorder = makeRecorder()
        var accepted: [HotkeyBinding] = []
        recorder.start { accepted.append($0) }

        recorder.handleKey(keyCode: HotkeyKeyCode.t, flags: [])
        XCTAssertEqual(recorder.issue, .needsModifier)
        recorder.handleKey(keyCode: HotkeyKeyCode.space, flags: [.command])
        XCTAssertEqual(recorder.issue, .usedBySystem)
        recorder.handleKey(keyCode: HotkeyKeyCode.t, flags: [.control, .option, .function])
        XCTAssertEqual(recorder.issue, .usesFunctionModifier)

        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(accepted.isEmpty)

        recorder.handleKey(keyCode: HotkeyKeyCode.t, flags: [.control, .option])
        XCTAssertEqual(accepted, [.defaultToggle])
        XCTAssertFalse(recorder.isRecording)
    }

    func testArrowKeysAreNotMistakenForFn() {
        let recorder = makeRecorder()
        var accepted: [HotkeyBinding] = []
        recorder.start { accepted.append($0) }

        // Arrow-key events always carry the Fn flag.
        recorder.handleKey(keyCode: 126, flags: [.control, .option, .function, .numericPad])

        XCTAssertEqual(accepted, [HotkeyBinding(keyCode: 126, modifiers: [.control, .option])])
    }

    func testEscapeCancelsWithoutChangingAnything() {
        let recorder = makeRecorder()
        var accepted: [HotkeyBinding] = []
        recorder.start { accepted.append($0) }
        recorder.handleKey(keyCode: HotkeyKeyCode.t, flags: [])

        recorder.handleKey(keyCode: HotkeyKeyCode.escape, flags: [])

        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.issue)
        XCTAssertTrue(accepted.isEmpty)

        // Keys typed afterwards are not recorded.
        recorder.handleKey(keyCode: HotkeyKeyCode.s, flags: [.control, .option])
        XCTAssertTrue(accepted.isEmpty)
    }
}

@MainActor
final class ToggleConfirmationTests: XCTestCase {
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 160, height: 38)

    func testLabelSitsCenteredJustUnderTheCaptionArea() {
        let captionArea = NSRect(x: 320, y: 700, width: 800, height: 120)

        let frame = ToggleConfirmationLayout.frame(size: size, captionArea: captionArea, visibleFrame: visibleFrame)

        XCTAssertEqual(frame.midX, captionArea.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, captionArea.minY - ToggleConfirmationLayout.gap, accuracy: 0.5)
        XCTAssertEqual(frame.size, size)
        XCTAssertFalse(frame.intersects(captionArea), "it must not cover the first caption")
    }

    func testLabelMovesAboveWhenTheCaptionAreaIsAtTheBottomOfTheScreen() {
        let captionArea = NSRect(x: 320, y: 10, width: 800, height: 120)

        let frame = ToggleConfirmationLayout.frame(size: size, captionArea: captionArea, visibleFrame: visibleFrame)

        XCTAssertEqual(frame.minY, captionArea.maxY + ToggleConfirmationLayout.gap, accuracy: 0.5)
        XCTAssertFalse(frame.intersects(captionArea))
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    func testLabelStaysOnScreenWhenTheCaptionAreaHangsOffTheEdge() {
        let captionArea = NSRect(x: -700, y: 700, width: 800, height: 120)

        let frame = ToggleConfirmationLayout.frame(size: size, captionArea: captionArea, visibleFrame: visibleFrame)

        XCTAssertTrue(visibleFrame.contains(frame))
        XCTAssertEqual(frame.minX, visibleFrame.minX, accuracy: 0.5)
    }

    func testLabelIsVisibleForAboutASecond() {
        let total = ToggleConfirmationLayout.fadeInDuration
            + ToggleConfirmationLayout.holdDuration
            + ToggleConfirmationLayout.fadeOutDuration

        XCTAssertEqual(ToggleConfirmationLayout.holdDuration, 1.0, accuracy: 0.01)
        XCTAssertLessThan(total, 1.6)
    }

    func testControllerShowsTheLabelThenTakesItAway() async throws {
        let controller = ToggleConfirmationController(level: .floating, collectionBehavior: [.canJoinAllSpaces])
        let captionArea = NSRect(x: 320, y: 700, width: 800, height: 120)

        controller.show(.on, text: "Subtitles on", captionArea: captionArea, visibleFrame: visibleFrame, sharingType: .none)

        XCTAssertTrue(controller.isVisibleForTesting)
        XCTAssertEqual(controller.sharingTypeForTesting, .none, "hidden from recordings when the overlay is")
        XCTAssertGreaterThan(controller.frameForTesting.width, 60)
        XCTAssertEqual(controller.frameForTesting.midX, captionArea.midX, accuracy: 1)
        XCTAssertFalse(controller.frameForTesting.intersects(captionArea))

        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertFalse(controller.isVisibleForTesting)
    }

    func testASecondToggleReplacesTheLabelInsteadOfStacking() async throws {
        let controller = ToggleConfirmationController(level: .floating, collectionBehavior: [.canJoinAllSpaces])
        let captionArea = NSRect(x: 320, y: 700, width: 800, height: 120)

        controller.show(.on, text: "Subtitles on", captionArea: captionArea, visibleFrame: visibleFrame, sharingType: .readOnly)
        try await Task.sleep(nanoseconds: 900_000_000)
        controller.show(.off, text: "Subtitles off", captionArea: captionArea, visibleFrame: visibleFrame, sharingType: .readOnly)

        // The first label's timer would have hidden it by now; the second is still up.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(controller.isVisibleForTesting)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(controller.isVisibleForTesting)
    }

    func testSoundsDifferForOnAndOffAndExistOnThisMac() {
        let on = SystemToggleSoundPlayer.soundName(for: .on)
        let off = SystemToggleSoundPlayer.soundName(for: .off)

        XCTAssertNotEqual(on, off)
        XCTAssertNotNil(NSSound(named: on))
        XCTAssertNotNil(NSSound(named: off))
    }

    func testLabelTextExistsInEveryInterfaceLanguage() {
        for language in LanguageCatalog.interface {
            let on = AppLocalization.string(.subtitlesOn, languageID: language.id)
            let off = AppLocalization.string(.subtitlesOff, languageID: language.id)

            XCTAssertFalse(on.isEmpty, language.id)
            XCTAssertNotEqual(on, off, language.id)
            if language.id != "en" {
                XCTAssertNotEqual(on, "Subtitles on", "\(language.id) falls back to English")
            }
        }
    }
}
