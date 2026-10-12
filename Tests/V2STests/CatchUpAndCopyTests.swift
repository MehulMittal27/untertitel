import Combine
import XCTest
@testable import v2s

final class RecentTranscriptFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ source: String, _ translated: String, secondsAgo: TimeInterval) -> TranscriptEntry {
        TranscriptEntry(
            id: UUID(),
            sourceText: source,
            translatedText: translated,
            createdAt: now.addingTimeInterval(-secondsAgo)
        )
    }

    func testEachSentenceIsTheEnglishLineThenTheGermanLine() {
        let text = RecentTranscriptFormatter.text(
            entries: [
                entry("Guten Morgen zusammen.", "Good morning everyone.", secondsAgo: 60),
                entry("Fangen wir an.", "Let's begin.", secondsAgo: 30),
            ],
            now: now
        )

        XCTAssertEqual(text, "Good morning everyone.\nGuten Morgen zusammen.\n\nLet's begin.\nFangen wir an.")
    }

    func testOnlyTheLastTwoMinutesAreCopied() {
        let text = RecentTranscriptFormatter.text(
            entries: [
                entry("Alt.", "Old.", secondsAgo: 121),
                entry("Gerade noch.", "Just in time.", secondsAgo: 119),
                entry("Neu.", "New.", secondsAgo: 1),
            ],
            now: now
        )

        XCTAssertEqual(text, "Just in time.\nGerade noch.\n\nNew.\nNeu.")
    }

    func testASentenceWithoutASeparateOriginalIsOneLineNotADuplicate() {
        let text = RecentTranscriptFormatter.text(
            entries: [
                // English speaker, or the cloud engine without the original line.
                entry("Let's switch to English.", "Let's switch to English.", secondsAgo: 30),
                entry("", "English only.", secondsAgo: 20),
                entry("Noch nicht übersetzt.", "", secondsAgo: 10),
                entry("  ", "", secondsAgo: 5),
            ],
            now: now
        )

        XCTAssertEqual(text, "Let's switch to English.\n\nEnglish only.\n\nNoch nicht übersetzt.")
    }

    func testNothingRecentGivesAnEmptyText() {
        XCTAssertEqual(RecentTranscriptFormatter.text(entries: [], now: now), "")
        XCTAssertEqual(
            RecentTranscriptFormatter.text(entries: [entry("Alt.", "Old.", secondsAgo: 600)], now: now),
            ""
        )
    }
}

@MainActor
final class CatchUpAndCopyModelTests: XCTestCase {
    private struct NoSecrets: SecretStore {
        func hasSecret(for account: String) -> Bool { false }
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String, for account: String) throws {}
        func removeSecret(for account: String) throws {}
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private var settingsURL: URL!
    private var cancellables = Set<AnyCancellable>()
    private var pasteboard: [String] = []
    private let clock = Clock()

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-catch-up-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
        pasteboard = []
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
    }

    private func makeModel() -> AppModel {
        let clock = clock
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(snapshotOverride: {
                SourceCatalogSnapshot(applications: [], microphones: [])
            }),
            secretStore: NoSecrets(),
            now: { clock.now },
            writeToPasteboard: { [weak self] text in self?.pasteboard.append(text) }
        )
        model.interfaceLanguageSelectionBinding.wrappedValue = "en"
        return model
    }

    func testCopyPutsTheLastTwoMinutesOnTheClipboardAndSaysSo() {
        let model = makeModel()
        var notices: [OverlayNotice] = []
        model.overlayNotices.sink { notices.append($0) }.store(in: &cancellables)

        model.addTranscriptEntryForTesting(sourceText: "Zu alt.", translatedText: "Too old.")
        clock.now += 200
        model.addTranscriptEntryForTesting(sourceText: "Guten Morgen.", translatedText: "Good morning.")
        clock.now += 30
        model.addTranscriptEntryForTesting(sourceText: "Fangen wir an.", translatedText: "Let's begin.")
        clock.now += 10
        XCTAssertTrue(model.hasRecentTranscript)

        let copied = model.copyRecentTranscript()

        XCTAssertEqual(copied, "Good morning.\nGuten Morgen.\n\nLet's begin.\nFangen wir an.")
        XCTAssertEqual(pasteboard, [copied].compactMap { $0 })
        XCTAssertEqual(notices.map(\.text), ["Copied the last 2 minutes"])
    }

    func testCopyWithNothingRecentLeavesTheClipboardAlone() {
        let model = makeModel()
        var notices: [OverlayNotice] = []
        model.overlayNotices.sink { notices.append($0) }.store(in: &cancellables)
        model.addTranscriptEntryForTesting(sourceText: "Alt.", translatedText: "Old.")
        clock.now += 500

        XCTAssertNil(model.copyRecentTranscript())

        XCTAssertTrue(pasteboard.isEmpty, "whatever was on the clipboard is kept")
        XCTAssertEqual(notices.map(\.text), ["Nothing to copy yet"])
        XCTAssertFalse(model.hasRecentTranscript)
    }

    func testCatchUpDoesNothingWithoutARunningSession() {
        let model = makeModel()

        model.toggleCatchUp()

        XCTAssertFalse(model.isCatchUpVisible)
    }

    func testTheCatchUpViewShowsTheLastFewSentences() {
        let model = makeModel()
        for index in 1...9 {
            model.addTranscriptEntryForTesting(sourceText: "Satz \(index).", translatedText: "Sentence \(index).")
        }

        XCTAssertEqual(model.catchUpEntries.count, AppModel.catchUpEntryCount)
        XCTAssertEqual(model.catchUpEntries.last?.translatedText, "Sentence 9.")
        XCTAssertEqual(model.catchUpEntries.first?.translatedText, "Sentence 4.")
    }

    func testTheNewShortcutsDefaultToControlOptionUpAndControlOptionCAndPersist() throws {
        let model = makeModel()
        XCTAssertEqual(model.catchUpHotkey, HotkeyBinding(keyCode: 126, modifiers: [.control, .option]))
        XCTAssertEqual(model.copyRecentHotkey, HotkeyBinding(keyCode: 8, modifiers: [.control, .option]))

        let custom = HotkeyBinding(keyCode: HotkeyKeyCode.s, modifiers: [.control, .command])
        model.catchUpHotkey = custom
        model.copyRecentHotkey = nil

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.catchUpHotkey, custom)
        XCTAssertNil(relaunched.copyRecentHotkey, "a cleared shortcut stays cleared")
        XCTAssertEqual(relaunched.toggleHotkey, .defaultToggle)

        let legacy = #"{ "inputLanguageID": "de", "outputLanguageID": "en" }"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.catchUpHotkey.binding, .defaultCatchUp)
        XCTAssertEqual(settings.copyRecentHotkey.binding, .defaultCopyRecent)
    }

    func testTheDefaultShortcutsAreAllowedAndDistinct() {
        let rules = HotkeyBindingRules()
        let defaults: [HotkeyBinding] = [.defaultToggle, .defaultCatchUp, .defaultCopyRecent]

        for binding in defaults {
            XCTAssertNil(rules.issue(for: binding))
        }
        XCTAssertEqual(Set(defaults).count, 3)
    }

    func testAShortcutCannotTakeACombinationAnotherOneUses() {
        let recorder = HotkeyRecorder(rules: HotkeyBindingRules())
        var accepted: [HotkeyBinding] = []
        recorder.start(reserved: [.defaultToggle, .defaultCopyRecent]) { accepted.append($0) }

        recorder.handleKey(keyCode: HotkeyKeyCode.t, flags: [.control, .option])

        XCTAssertEqual(recorder.issue, .usedByThisApp)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(accepted.isEmpty)

        recorder.handleKey(keyCode: 126, flags: [.control, .option, .function, .numericPad])
        XCTAssertEqual(accepted, [.defaultCatchUp])
    }

    func testCatchUpLinesLeaveOutTheCaptionAlreadyOnScreen() {
        let entries = [
            TranscriptEntry(id: UUID(), sourceText: "Eins.", translatedText: "One."),
            TranscriptEntry(id: UUID(), sourceText: "Zwei.", translatedText: "Two."),
            TranscriptEntry(id: UUID(), sourceText: "Drei.", translatedText: ""),
        ]

        XCTAssertEqual(
            CaptionCatchUpLayout.lines(entries: entries, excluding: "Two.", showsTranslated: true),
            ["One.", "Drei."],
            "English where there is one, the original where there is not"
        )
        XCTAssertEqual(
            CaptionCatchUpLayout.lines(entries: entries, excluding: nil, showsTranslated: false),
            ["Eins.", "Zwei.", "Drei."]
        )
        XCTAssertGreaterThan(
            CaptionCatchUpLayout.height(entryCount: 6, style: .default),
            CaptionCatchUpLayout.height(entryCount: 2, style: .default)
        )
    }

    func testEveryNewTextExistsInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .catchUpShortcut, .copyRecentShortcut, .copiedRecent, .nothingToCopy, .catchUpEmpty, .shortcutUsedByThisApp,
        ]
        for language in LanguageCatalog.interface where language.id != "en" {
            for key in keys {
                XCTAssertNotEqual(
                    AppLocalization.string(key, languageID: language.id),
                    AppLocalization.string(key, languageID: "en"),
                    "\(language.id) falls back to English for \(key.rawValue)"
                )
            }
        }
    }
}
