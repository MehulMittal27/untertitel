import AVFoundation
import XCTest
@testable import v2s

final class MeetingMarkdownTests: XCTestCase {
    func testTheFileIsNamedAfterTheStartTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9, minute: 5))!

        XCTAssertEqual(MeetingMarkdown.fileName(startedAt: start, calendar: calendar), "2026-10-14 09-05 Meeting.md")
    }

    func testTheDocumentListsSpeakersAndGroupsTheirTurns() {
        var transcript = MeetingTranscript()
        transcript.applyFinal(text: "Guten Morgen.", start: 1, end: 2, speaker: 1)
        transcript.applyFinal(text: "Lasst uns anfangen.", start: 3, end: 4, speaker: 1)
        transcript.applyFinal(text: "*Sure* - [one] #two", start: 65, end: 67, speaker: 2)
        let names = [1: "Anna"]
        let start = Date(timeIntervalSince1970: 1_791_968_700)

        let document = MeetingMarkdown.document(
            transcript: transcript,
            startedAt: start,
            duration: 3_725,
            speakerName: { names[$0] ?? "Speaker \($0)" },
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertTrue(document.hasPrefix("# Meeting, "))
        XCTAssertTrue(document.contains("- Duration: 1:02:05"))
        XCTAssertTrue(document.contains("- Speakers: Anna, Speaker 2"))
        XCTAssertTrue(document.contains("**Anna** [0:01]  \nGuten Morgen.\n\n[0:03]  \nLasst uns anfangen."))
        XCTAssertTrue(document.contains("**Speaker 2** [1:05]  \n\\*Sure\\* - \\[one\\] #two"))
        XCTAssertFalse(document.contains("\u{2014}"))
    }

    func testSpeechThatLooksLikeMarkdownStaysText() {
        XCTAssertEqual(MeetingMarkdown.escaped("# not a heading"), "\\# not a heading")
        XCTAssertEqual(MeetingMarkdown.escaped("- not a list"), "\\- not a list")
        XCTAssertEqual(MeetingMarkdown.escaped("a_b"), "a\\_b")
    }
}

final class MeetingTranscriptStoreTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("untertitel-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testTheDefaultFolderIsOutsideEverySyncedPlace() {
        XCTAssertEqual(MeetingTranscriptStore.defaultFolder.path, NSHomeDirectory() + "/Meeting Transcripts")
        XCTAssertFalse(MeetingTranscriptStore.isSyncedLocation(MeetingTranscriptStore.defaultFolder))
    }

    func testSyncedPlacesAreRecognizedAlsoThroughALink() throws {
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Meetings")
        let dropbox = home.appendingPathComponent("Library/CloudStorage/Dropbox/Meetings")
        try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
        let linked = home.appendingPathComponent("Untertitel")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: dropbox)

        XCTAssertTrue(MeetingTranscriptStore.isSyncedLocation(icloud, home: home))
        XCTAssertTrue(MeetingTranscriptStore.isSyncedLocation(dropbox, home: home))
        XCTAssertTrue(MeetingTranscriptStore.isSyncedLocation(linked, home: home), "a link into a synced folder counts")
        XCTAssertFalse(MeetingTranscriptStore.isSyncedLocation(home.appendingPathComponent("Untertitel-local"), home: home))
    }

    func testSavingDeletingAndListing() throws {
        let store = MeetingTranscriptStore(folder: home.appendingPathComponent("Untertitel/Meetings"))
        let first = try store.save("# one", fileName: "2026-10-14 09-00 Meeting.md")
        _ = try store.save("# two", fileName: "2026-10-15 09-00 Meeting.md")
        _ = try store.save("# one again", fileName: "2026-10-14 09-00 Meeting.md")

        XCTAssertEqual(store.transcripts().map(\.lastPathComponent), ["2026-10-15 09-00 Meeting.md", "2026-10-14 09-00 Meeting.md"])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# one again")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int, 0o600)

        let outside = home.appendingPathComponent("keep.md")
        try Data("keep".utf8).write(to: outside)
        try store.delete(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "only files in the meetings folder are deleted")

        try store.delete(first)
        XCTAssertEqual(store.transcripts().count, 1)
        try store.deleteAll()
        XCTAssertTrue(store.transcripts().isEmpty)
    }
}

private final class SilentSource: MeetingAudioSource {
    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
}

private final class SilentRecognizer: MeetingSpeechRecognizer {
    func start(onUpdate: @escaping @MainActor (MeetingRecognitionUpdate) -> Void) async throws {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async {}
}

@MainActor
final class MeetingSavingControllerTests: XCTestCase {
    private var folder: URL!
    private var saves = false

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("untertitel-meetings-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeController(store: MeetingTranscriptStore? = nil) -> MeetingController {
        MeetingController(environment: MeetingController.Environment(
            settings: { [unowned self] in
                MeetingSettings(hotkey: .defaultMeeting, languageID: "de", microphoneID: nil, savesTranscripts: self.saves)
            },
            interfaceLanguageID: { "en" },
            makeAudioSource: { _ in SilentSource() },
            makeRecognizer: { _ in SilentRecognizer() },
            requestMicrophoneAccess: { true },
            areSubtitlesRunning: { false },
            stopSubtitles: {},
            now: Date.init,
            transcriptStore: store ?? MeetingTranscriptStore(folder: folder)
        ))
    }

    private func meetingWithWords(store: MeetingTranscriptStore? = nil) async -> MeetingController {
        let meeting = makeController(store: store)
        meeting.prepareToStart()
        await meeting.start()
        meeting.apply(.final(text: "Wir fangen an.", start: 0.5, end: 2))
        await meeting.stop()
        return meeting
    }

    func testWithSavingOffNothingIsWritten() async {
        let meeting = await meetingWithWords()

        XCTAssertNil(meeting.saveOutcome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(meeting.hasUnsavedTranscript, "the next consent note warns")
    }

    func testWithSavingOnTheTranscriptIsWrittenAndFollowsRenames() async throws {
        saves = true
        let meeting = await meetingWithWords()

        guard case .saved(let url) = meeting.saveOutcome else { return XCTFail("\(String(describing: meeting.saveOutcome))") }
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Wir fangen an."))
        XCTAssertFalse(meeting.hasUnsavedTranscript)

        meeting.setTranscriptForTesting({
            var transcript = meeting.transcript
            transcript.relabel { _ in 1 }
            return transcript
        }())
        meeting.renameSpeaker(1, to: "Anna")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("**Anna**"))

        meeting.deleteSavedTranscript()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "deleted for good, in one click")
        XCTAssertTrue(meeting.transcript.isEmpty)
        XCTAssertNil(meeting.saveOutcome)
    }

    func testATranscriptIsNotWrittenIntoASyncedFolder() async throws {
        saves = true
        let home = folder.appendingPathComponent("home")
        let synced = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Meetings")
        let meeting = await meetingWithWords(store: MeetingTranscriptStore(folder: synced, home: home))

        XCTAssertEqual(meeting.saveOutcome, .failed("Not saved: the meetings folder is inside a synced folder."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: synced.path), "nothing is even created there")
    }

    func testTheConsentNoteMentionsTheTranscriptOnlyWhenItIsKept() {
        let meeting = makeController()
        XCTAssertFalse(meeting.consentText(in: "en").contains("written transcript"))
        XCTAssertTrue(meeting.consentText(in: "en").hasSuffix("just say so."))

        saves = true
        XCTAssertTrue(meeting.consentText(in: "en").contains("I keep the written transcript as my notes. If anyone"))
        XCTAssertTrue(meeting.consentText(in: "de").contains("Notizen. Falls das"))
    }

    func testSavingIsOffInOlderSettings() throws {
        XCTAssertFalse(MeetingSettings.default.savesTranscripts)
        let decoded = try JSONDecoder().decode(MeetingSettings.self, from: Data(#"{"languageID":"de"}"#.utf8))
        XCTAssertFalse(decoded.savesTranscripts)
    }

    func testTheSavingTextsExistInEveryInterfaceLanguage() {
        let keys: [AppTextKey] = [
            .meetingSaveTranscripts, .meetingSaveExplanationFormat, .meetingShowInFinder, .meetingDeleteAll,
            .meetingDeleteAllConfirm, .meetingDeleteTranscript, .meetingSavedFormat, .meetingSaveFailedSynced,
            .meetingSaveFailedFormat, .meetingConsentUnsavedWarning,
        ]
        for language in LanguageCatalog.interface {
            for key in keys {
                let text = AppLocalization.string(key, languageID: language.id)
                XCTAssertNotEqual(text, key.rawValue, "\(language.id) \(key)")
            }
            XCTAssertTrue(AppLocalization.string(.meetingSaveExplanationFormat, languageID: language.id, "~/Meeting Transcripts").contains("~/Meeting Transcripts"))
        }
    }
}
