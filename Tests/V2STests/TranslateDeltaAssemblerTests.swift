import XCTest
@testable import v2s

final class TranslateDeltaAssemblerTests: XCTestCase {
    private func makeAssembler(hasVoiceActivitySignal: Bool = true) -> TranslateDeltaAssembler {
        TranslateDeltaAssembler(hasVoiceActivitySignal: hasVoiceActivitySignal)
    }

    private func sentences(in outputs: [TranslateDeltaAssembler.Output]) -> [TranslateDeltaAssembler.Sentence] {
        outputs.compactMap { output in
            if case .sentence(let sentence) = output { return sentence }
            return nil
        }
    }

    private func lastDraft(in outputs: [TranslateDeltaAssembler.Output]) -> TranslateDeltaAssembler.Draft?? {
        outputs.reversed().lazy.compactMap { output -> TranslateDeltaAssembler.Draft??  in
            if case .draft(let draft) = output { return .some(draft) }
            return nil
        }.first
    }

    func testDeltasAreConcatenatedWithoutAddedSpacesIntoTheDraft() {
        var assembler = makeAssembler()

        _ = assembler.appendSource("Guten", at: 0)
        _ = assembler.appendSource(" Mor", at: 0.1)
        let outputs = assembler.appendSource("gen", at: 0.2)

        XCTAssertEqual(lastDraft(in: outputs)??.sourceText, "Guten Morgen")
        XCTAssertEqual(lastDraft(in: outputs)??.translatedText, "")
        XCTAssertTrue(sentences(in: outputs).isEmpty)
    }

    func testTranslationTrailingTheSourceStaysInOneSentence() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Ich habe das Dokument gestern geschickt.", at: 0)
        assembler.speechEnded(at: 0.2)

        // The pause is long enough, but the translation is still arriving.
        _ = assembler.appendTranslation("I sent the document", at: 1.5)
        XCTAssertTrue(sentences(in: assembler.advance(to: 1.6)).isEmpty)

        _ = assembler.appendTranslation(" yesterday.", at: 1.7)
        let committed = sentences(in: assembler.advance(to: 2.1))

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.sourceText, "Ich habe das Dokument gestern geschickt.")
        XCTAssertEqual(committed.first?.translatedText, "I sent the document yesterday.")
        XCTAssertEqual(committed.first?.hasEngineTranslation, true)
        XCTAssertFalse(assembler.hasPendingText)
    }

    func testPunctuationPlusShortPauseCommits() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Das passt.", at: 0)
        _ = assembler.appendTranslation("That works.", at: 0.1)
        assembler.speechEnded(at: 0.2)

        XCTAssertTrue(sentences(in: assembler.advance(to: 0.4)).isEmpty, "0.2 s of silence is not a pause yet")

        let committed = sentences(in: assembler.advance(to: 0.6))
        XCTAssertEqual(committed.map(\.translatedText), ["That works."])
    }

    func testUnfinishedSentenceWaitsForTheLongPause() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Und dann", at: 0)
        _ = assembler.appendTranslation("And then", at: 0.1)
        assembler.speechEnded(at: 0.2)

        XCTAssertTrue(sentences(in: assembler.advance(to: 1.0)).isEmpty)

        let committed = sentences(in: assembler.advance(to: 1.5))
        XCTAssertEqual(committed.map(\.translatedText), ["And then"])
    }

    func testSpeechResumingCancelsThePendingCommit() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Das passt.", at: 0)
        _ = assembler.appendTranslation("That works.", at: 0.1)
        assembler.speechEnded(at: 0.2)
        assembler.speechStarted(at: 0.3)

        XCTAssertTrue(sentences(in: assembler.advance(to: 5)).isEmpty)
        XCTAssertTrue(assembler.hasPendingText)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    func testFinishedSentenceBecomesItsOwnCaptionWhenTheNextOneStarts() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Die Regierung hat heute neue Maßnahmen beschlossen. Sie", at: 0)

        let beforeNextSentence = assembler.appendTranslation("The government decided on a set of new measures today.", at: 0.1)
        XCTAssertTrue(sentences(in: beforeNextSentence).isEmpty, "the sentence may still continue")

        let outputs = assembler.appendTranslation(" They", at: 0.2)
        let committed = sentences(in: outputs)

        XCTAssertEqual(committed.map(\.translatedText), ["The government decided on a set of new measures today."])
        XCTAssertEqual(committed.map(\.sourceText), ["Die Regierung hat heute neue Maßnahmen beschlossen."])
        XCTAssertEqual(lastDraft(in: outputs)??.translatedText, "They")
        XCTAssertEqual(lastDraft(in: outputs)??.sourceText, "Sie")
        XCTAssertNotEqual(lastDraft(in: outputs)??.segmentID, committed.first?.segmentID)
    }

    func testShortSentencesStayTogetherInOneCaption() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Ja. Genau. Das", at: 0)

        let outputs = assembler.appendTranslation("Yes. Exactly. That", at: 0.1)

        XCTAssertTrue(sentences(in: outputs).isEmpty)
        XCTAssertEqual(lastDraft(in: outputs)??.translatedText, "Yes. Exactly. That")
    }

    func testOverlongSentenceIsCutAtACommaInsideTheLimit() {
        var assembler = makeAssembler()
        _ = assembler.appendSource(
            "Der Sturm zog am Abend über die Küste, im Nordwesten fiel in tausenden Haushalten der Strom aus und",
            at: 0
        )
        let english = "The storm moved across the coast in the evening, in the northwest the power went out in thousands of homes and"

        let outputs = assembler.appendTranslation(english, at: 0.1)
        let committed = sentences(in: outputs)

        XCTAssertEqual(committed.map(\.translatedText), ["The storm moved across the coast in the evening,"])
        XCTAssertEqual(committed.map(\.sourceText), ["Der Sturm zog am Abend über die Küste,"])
        XCTAssertEqual(
            lastDraft(in: outputs)??.translatedText,
            "in the northwest the power went out in thousands of homes and",
            "the next caption starts with a word, not with the comma"
        )
    }

    func testTextWithoutPunctuationIsCutAfterTwelveWords() {
        var assembler = makeAssembler()
        let english = (1...17).map { "word\($0)" }.joined(separator: " ")

        let committed = sentences(in: assembler.appendTranslation(english, at: 0))

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(wordCount(committed[0].translatedText), 12)
    }

    func testVeryLongWordsAreCutByLengthToo() {
        var assembler = makeAssembler()
        let english = (1...10).map { _ in "extraordinarily" }.joined(separator: " ")

        let committed = sentences(in: assembler.appendTranslation(english, at: 0))

        XCTAssertEqual(committed.count, 1)
        XCTAssertLessThanOrEqual(committed[0].translatedText.count, 110)
    }

    /// Streams a news paragraph word by word, as the engine does, with no pauses.
    func testNoCaptionIsLongerThanSixteenWordsOrStartsWithPunctuation() {
        var assembler = makeAssembler()
        let english = "A severe storm hit northern Germany on Thursday evening, in the northwest thousands of households were left without power, and rail traffic between Hamburg and Bremen was suspended for several hours. The fire brigade reported more than 3.5 thousand call-outs, most of them because of fallen trees. Nobody was seriously hurt, according to the police, but the damage is expected to run into the millions."
        var captions: [String] = []
        var drafts: [String] = []
        var time: TimeInterval = 0

        for word in english.split(separator: " ") {
            time += 0.05
            let outputs = assembler.appendTranslation(" " + word, at: time)
            captions += sentences(in: outputs).map(\.translatedText)
            if let draft = lastDraft(in: outputs)??.translatedText { drafts.append(draft) }
        }
        captions += sentences(in: assembler.flush(at: time + 1)).map(\.translatedText)

        XCTAssertGreaterThan(captions.count, 3)
        for text in captions + drafts {
            XCTAssertLessThanOrEqual(wordCount(text), 17, "caption too long: \(text)")
            XCTAssertLessThanOrEqual(text.count, 125, "caption too long: \(text)")
            let first = try? XCTUnwrap(text.first)
            XCTAssertTrue(first?.isLetter == true || first?.isNumber == true, "starts with punctuation: \(text)")
        }
        XCTAssertEqual(
            captions.joined(separator: " "),
            english,
            "cutting into captions loses and repeats nothing"
        )
        XCTAssertTrue(captions.contains { $0.contains("3.5 thousand") }, "a decimal point is not a sentence end")
    }

    func testCaptionThatWouldStartWithPunctuationHasItRemoved() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Das ist in Niedersachsen", at: 0)
        _ = assembler.appendTranslation("That is in Lower Saxony", at: 0.1)
        assembler.speechEnded(at: 0.2)
        XCTAssertEqual(sentences(in: assembler.advance(to: 1.6)).map(\.translatedText), ["That is in Lower Saxony"])

        // The speaker carries on with the same sentence after the pause.
        assembler.speechStarted(at: 1.7)
        _ = assembler.appendSource(", im Nordwesten.", at: 1.8)
        let outputs = assembler.appendTranslation(", in the northwest.", at: 1.9)

        XCTAssertEqual(lastDraft(in: outputs)??.translatedText, "in the northwest.")
        XCTAssertEqual(lastDraft(in: outputs)??.sourceText, "im Nordwesten.")
    }

    func testLongSourceWaitsForItsTranslationBeforeBeingCut() {
        var assembler = makeAssembler()
        let longSource = String(repeating: "Wir sprechen weiter und weiter. ", count: 4)

        let outputs = assembler.appendSource(longSource, at: 0)

        XCTAssertGreaterThan(longSource.count, 110)
        XCTAssertTrue(sentences(in: outputs).isEmpty, "the translation has not arrived yet")
    }

    func testCutKeepsSourceAndTranslationOnTheSameSentences() {
        var assembler = makeAssembler()
        // The source is three sentences ahead; the translation has finished two.
        _ = assembler.appendSource("Erster Satz ist da. Zweiter Satz kommt gleich danach! Dritter Satz. Vier", at: 0)

        let committed = sentences(
            in: assembler.appendTranslation("The first sentence is here. The second one follows right after! Third", at: 0.1)
        )

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.sourceText, "Erster Satz ist da. Zweiter Satz kommt gleich danach!")
        XCTAssertEqual(committed.first?.translatedText, "The first sentence is here. The second one follows right after!")
    }

    func testSourceWithNoTranslationIsEventuallyCutOnItsOwn() {
        var assembler = makeAssembler()
        let english = String(repeating: "This part is already in English. ", count: 6)

        let committed = sentences(in: assembler.appendSource(english, at: 0))

        XCTAssertGreaterThan(english.count, 160)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.hasEngineTranslation, false)
        XCTAssertLessThanOrEqual(committed.first?.sourceText.count ?? .max, 110)
        XCTAssertTrue(assembler.hasPendingText, "the rest stays for the next caption")
    }

    func testSpeechAlreadyInTheTargetLanguageIsShownAsIs() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Okay, let's switch to English.", at: 0)
        assembler.speechEnded(at: 0.2)

        XCTAssertTrue(sentences(in: assembler.advance(to: 1.5)).isEmpty, "the translation may still arrive")

        let committed = sentences(in: assembler.advance(to: 1.8))
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.sourceText, "Okay, let's switch to English.")
        XCTAssertEqual(committed.first?.translatedText, "Okay, let's switch to English.")
        XCTAssertEqual(committed.first?.hasEngineTranslation, false)
    }

    func testFlushCommitsWhatIsLeftAndClearsTheDraft() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Bis morgen", at: 0)
        _ = assembler.appendTranslation("See you tomorrow", at: 0.1)

        let outputs = assembler.flush(at: 0.2)

        XCTAssertEqual(sentences(in: outputs).map(\.translatedText), ["See you tomorrow"])
        XCTAssertEqual(lastDraft(in: outputs), .some(nil))
        XCTAssertTrue(assembler.flush(at: 0.3).isEmpty)
    }

    func testEachSentenceGetsItsOwnSegmentID() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Eins.", at: 0)
        _ = assembler.appendTranslation("One.", at: 0)
        assembler.speechEnded(at: 0)
        let first = sentences(in: assembler.advance(to: 1))
        assembler.speechStarted(at: 1.1)
        _ = assembler.appendSource("Zwei.", at: 1.2)
        _ = assembler.appendTranslation("Two.", at: 1.3)
        assembler.speechEnded(at: 1.4)
        let second = sentences(in: assembler.advance(to: 2.4))

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first.first?.segmentID, second.first?.segmentID)
    }

    func testWithoutAVoiceActivitySignalPausesComeFromGapsInTheStream() {
        var assembler = makeAssembler(hasVoiceActivitySignal: false)
        _ = assembler.appendSource("Das passt.", at: 0)
        _ = assembler.appendTranslation("That works.", at: 0.1)

        XCTAssertTrue(sentences(in: assembler.advance(to: 0.3)).isEmpty)
        XCTAssertEqual(sentences(in: assembler.advance(to: 0.5)).map(\.translatedText), ["That works."])
    }

    func testTimingRecordsTheFirstDeltasAndTheEndOfSpeech() {
        var assembler = makeAssembler()
        _ = assembler.appendSource("Ja.", at: 1)
        assembler.speechEnded(at: 1.5)
        _ = assembler.appendTranslation("Yes.", at: 2)

        let timing = sentences(in: assembler.advance(to: 3)).first?.timing

        XCTAssertEqual(timing?.firstSourceDeltaAt, 1)
        XCTAssertEqual(timing?.speechEndedAt, 1.5)
        XCTAssertEqual(timing?.firstTranslationDeltaAt, 2)
        XCTAssertEqual(timing?.committedAt, 3)
    }

    func testSentenceEndDetectionAllowsClosingQuotes() {
        XCTAssertTrue(TranslateDeltaAssembler.endsSentence("He said \"no.\" "))
        XCTAssertTrue(TranslateDeltaAssembler.endsSentence("Really?"))
        XCTAssertFalse(TranslateDeltaAssembler.endsSentence("and then,"))
        XCTAssertFalse(TranslateDeltaAssembler.endsSentence(""))
    }
}
