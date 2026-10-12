import XCTest
@testable import v2s

final class CaptureSilenceTests: XCTestCase {
    func testSilentThenAudibleThenSilentAgain() {
        var tracker = CaptureSilenceTracker()
        XCTAssertFalse(tracker.isSilent)

        XCTAssertTrue(tracker.handle(.silentWhileSourcePlays))
        XCTAssertTrue(tracker.isSilent)

        XCTAssertFalse(tracker.handle(.silentWhileSourcePlays), "a repeat changes nothing")
        XCTAssertTrue(tracker.isSilent)

        XCTAssertTrue(tracker.handle(.receivingAudio))
        XCTAssertFalse(tracker.isSilent)

        XCTAssertFalse(tracker.handle(.receivingAudio))
        XCTAssertTrue(tracker.handle(.silentWhileSourcePlays))
        XCTAssertTrue(tracker.isSilent)

        tracker.reset()
        XCTAssertFalse(tracker.isSilent)
    }

    func testARunningSessionThatHearsNothingGetsItsOwnIcon() {
        let warning = StatusItemAppearance(symbolName: "exclamationmark.triangle.fill", tint: .warning, title: "")

        XCTAssertEqual(
            StatusItemAppearance.resolve(sessionState: .running, cloudEngineState: nil, isCaptureSilent: true),
            warning
        )
        XCTAssertEqual(
            StatusItemAppearance.resolve(sessionState: .running, cloudEngineState: .waitingForAudio, isCaptureSilent: true),
            warning,
            "a broken capture is not the same as a quiet source"
        )
        XCTAssertNotEqual(
            warning,
            StatusItemAppearance.resolve(sessionState: .running, cloudEngineState: nil),
            "it must not look like a session that is working"
        )
        XCTAssertNotNil(warning.makeImage())
    }

    func testTheWarningNeverShowsWithoutASessionAndNeverHidesBilling() {
        XCTAssertEqual(
            StatusItemAppearance.resolve(sessionState: .idle, cloudEngineState: nil, isCaptureSilent: true),
            StatusItemAppearance.resolve(sessionState: .idle, cloudEngineState: nil)
        )
        XCTAssertEqual(
            StatusItemAppearance.resolve(
                sessionState: .running,
                cloudEngineState: .streaming,
                hasOpenCloudConnection: true,
                isCaptureSilent: true
            ).tint,
            .billing,
            "an open connection always shows as billing"
        )
    }

    func testTheHintNamesTheAppAndThePermissionInEveryLanguage() {
        for language in LanguageCatalog.interface {
            let hint = AppLocalization.string(.captureSilentHintFormat, languageID: language.id, "Safari")
            XCTAssertTrue(hint.contains("Safari"), language.id)
            if language.id != "en" {
                XCTAssertNotEqual(
                    hint,
                    AppLocalization.string(.captureSilentHintFormat, languageID: "en", "Safari"),
                    "\(language.id) falls back to English"
                )
            }
        }
    }
}
