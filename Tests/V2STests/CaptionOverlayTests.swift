import XCTest
@testable import v2s

final class CaptionOverlayTests: XCTestCase {
    private func resolve(
        _ state: OverlayPreviewState,
        showsTranslated: Bool = true,
        showsOriginal: Bool = true
    ) -> CaptionOverlayContent? {
        CaptionOverlayContent.resolve(
            state: state,
            showsTranslated: showsTranslated,
            showsOriginal: showsOriginal,
            isStatusText: { $0 == "Listening…" }
        )
    }

    private func state(translated: String = "", source: String = "") -> OverlayPreviewState {
        OverlayPreviewState(translatedText: translated, sourceText: source, sourceName: "Chrome")
    }

    func testFinishedCaptionShowsTranslationLargeAndOriginalSmall() {
        let content = resolve(state(translated: "Good morning.", source: "Guten Morgen."))

        XCTAssertEqual(
            content,
            CaptionOverlayContent(primaryText: "Good morning.", secondaryText: "Guten Morgen.", isStatus: false)
        )
    }

    func testLiveDraftReplacesTheFinishedCaptionInsteadOfStackingOnIt() {
        var overlay = state(translated: "Good morning.", source: "Guten Morgen.")
        let draftID = UUID()
        overlay.draftSourceText = "Wie geht es"
        overlay.draftPromotionID = draftID
        overlay.setDraftTranslation("How are", sourceText: "Wie geht es", promotionID: draftID)

        XCTAssertEqual(
            resolve(overlay),
            CaptionOverlayContent(primaryText: "How are", secondaryText: "Wie geht es", isStatus: false)
        )
    }

    func testHistoryIsNeverPartOfTheCaption() {
        var overlay = state(translated: "Now.", source: "Jetzt.")
        overlay.history = [
            OverlayHistoryEntry(translatedText: "Earlier one.", sourceText: "Früher eins."),
            OverlayHistoryEntry(translatedText: "Earlier two.", sourceText: "Früher zwei."),
        ]

        let content = resolve(overlay)

        XCTAssertEqual(content?.primaryText, "Now.")
        XCTAssertEqual(content?.secondaryText, "Jetzt.")
    }

    func testDraftWhoseTranslationIsStillOnItsWayShowsOnlyTheOriginal() {
        var overlay = state()
        overlay.draftSourceText = "Guten"
        overlay.draftPromotionID = UUID()

        XCTAssertEqual(resolve(overlay), CaptionOverlayContent(primaryText: "", secondaryText: "Guten", isStatus: false))
    }

    func testSpeechAlreadyInEnglishIsNotShownTwice() {
        let content = resolve(state(translated: "Okay, let's switch to English.", source: "okay, let's switch to english."))

        XCTAssertEqual(content?.primaryText, "Okay, let's switch to English.")
        XCTAssertEqual(content?.secondaryText, "")
    }

    func testDisplayModesChooseTheLines() {
        let overlay = state(translated: "Good morning.", source: "Guten Morgen.")

        XCTAssertEqual(
            resolve(overlay, showsTranslated: true, showsOriginal: false),
            CaptionOverlayContent(primaryText: "Good morning.", secondaryText: "", isStatus: false)
        )
        XCTAssertEqual(
            resolve(overlay, showsTranslated: false, showsOriginal: true),
            CaptionOverlayContent(primaryText: "Guten Morgen.", secondaryText: "", isStatus: false)
        )
    }

    func testStatusMessagesAreMarkedAsSuch() {
        let content = resolve(state(translated: "Listening…", source: "Waiting for audio from Chrome"))

        XCTAssertEqual(content?.isStatus, true)
        XCTAssertEqual(content?.primaryText, "Listening…")
    }

    func testNothingToShowMeansNoBlock() {
        XCTAssertNil(resolve(state()))
        XCTAssertNil(resolve(state(translated: "  ", source: "\n")))
    }

    func testLineBreaksAndDoubleSpacesAreFlattenedAndDashesStayWithTheirWord() {
        XCTAssertEqual(CaptionOverlayContent.displayText("  one\n two   three "), "one two three")
        XCTAssertEqual(
            CaptionOverlayContent.displayText("the result – as expected – is clear"),
            "the result\u{00A0}– as expected\u{00A0}– is clear"
        )
    }

    func testBlockIsNeverWiderThanSeventyPercentOfTheScreen() {
        XCTAssertEqual(CaptionOverlayLayout.maximumBlockWidth(availableWidth: 1_240, screenWidth: 1_512), 1_058.4, accuracy: 0.01)
        XCTAssertEqual(CaptionOverlayLayout.maximumBlockWidth(availableWidth: 700, screenWidth: 1_512), 700, "a narrower panel limits it further")

        let maximum = CaptionOverlayLayout.maximumBlockWidth(availableWidth: 1_240, screenWidth: 1_512)
        for textWidth in stride(from: CGFloat(0), through: 6_000, by: 37) {
            XCTAssertLessThanOrEqual(
                CaptionOverlayLayout.blockWidth(forTextWidth: textWidth, maximumWidth: maximum),
                maximum
            )
        }
    }

    func testBlockWidthMovesInStepsAndAlwaysHoldsItsText() {
        let maximum: CGFloat = 1_000

        XCTAssertEqual(CaptionOverlayLayout.blockWidth(forTextWidth: 60, maximumWidth: maximum), 250)
        XCTAssertEqual(CaptionOverlayLayout.blockWidth(forTextWidth: 200, maximumWidth: maximum), 250)
        XCTAssertEqual(CaptionOverlayLayout.blockWidth(forTextWidth: 230, maximumWidth: maximum), 500, "text plus padding no longer fits 250")
        XCTAssertEqual(CaptionOverlayLayout.blockWidth(forTextWidth: 720, maximumWidth: maximum), 1_000)
        XCTAssertEqual(CaptionOverlayLayout.blockWidth(forTextWidth: 5_000, maximumWidth: maximum), 1_000, "longer text wraps inside")
    }

    func testBackgroundStaysDarkEnoughToReadOverVideo() {
        XCTAssertGreaterThanOrEqual(CaptionOverlayLayout.backgroundOpacity(styleOpacity: 0), 0.55)
        XCTAssertEqual(CaptionOverlayLayout.backgroundOpacity(styleOpacity: 0.32), 0.678, accuracy: 0.001)
        XCTAssertEqual(CaptionOverlayLayout.backgroundOpacity(styleOpacity: 1), 0.95, accuracy: 0.001)
        XCTAssertLessThan(CaptionOverlayLayout.backgroundOpacity(styleOpacity: 5), 1, "never fully opaque")
    }

    /// The longest caption the splitter lets through must fit two lines at the
    /// default size inside the 70 percent block on a 13-inch screen.
    func testLongestAllowedCaptionFitsTwoLinesAtDefaultSize() {
        let style = OverlayStyle.default
        let maximum = CaptionOverlayLayout.maximumBlockWidth(availableWidth: 1_440 * 0.82, screenWidth: 1_440)
        let textWidthPerLine = maximum - CaptionOverlayLayout.horizontalPadding * 2
        let longest = String(repeating: "W", count: TranslateDeltaAssembler.Configuration().maximumCaptionCharacters)
        let singleLine = CaptionOverlayLayout.singleLineWidth(
            of: longest,
            fontSize: CGFloat(style.scaledTranslatedFontSize),
            weight: .semibold
        )

        // Even all capital W, the widest letter, needs at most the scale-down the
        // view allows (to 60 percent) to stay within two lines.
        XCTAssertLessThanOrEqual(singleLine * 0.6, textWidthPerLine * 2)
    }
}
