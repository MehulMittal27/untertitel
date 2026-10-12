import Foundation

/// Turns the cloud engine's append-only transcript deltas into what the subtitle
/// pipeline expects: a live draft plus committed sentences.
///
/// The engine sends no sentence or "final" events, so boundaries come from pauses in
/// the speech (voice activity) and from punctuation. The translation trails the
/// source, so a commit also waits until the delta stream has gone quiet: committing
/// while text is still arriving would split a sentence from its translation.
///
/// Pure value type: every input carries its own timestamp, so tests can script it.
struct TranslateDeltaAssembler {
    struct Configuration: Equatable {
        /// Pause needed after a translation that ends a sentence.
        var punctuationSilence: TimeInterval = 0.3
        /// Pause that commits whatever has arrived, punctuation or not.
        var pauseSilence: TimeInterval = 1.2
        /// How long the delta stream must be quiet before a pause-based commit.
        var settleInterval: TimeInterval = 0.35
        /// Pause after which a commit no longer waits for the stream to settle.
        var maximumPauseWait: TimeInterval = 2.5
        /// Pause after which source text with no translation is shown as-is. The
        /// engine may not translate speech that is already in the target language.
        var missingTranslationWait: TimeInterval = 1.5
        /// A tail longer than this is cut at its last punctuation mark.
        var maximumTailLength = 200
    }

    struct Draft: Equatable, Sendable {
        let segmentID: UUID
        let sourceText: String
        let translatedText: String
    }

    /// Timestamps for the latency log (R16). All on the caller's clock.
    struct Timing: Equatable, Sendable {
        let speechEndedAt: TimeInterval?
        let firstSourceDeltaAt: TimeInterval?
        let firstTranslationDeltaAt: TimeInterval?
        let committedAt: TimeInterval
    }

    struct Sentence: Equatable, Sendable {
        let segmentID: UUID
        let sourceText: String
        let translatedText: String
        /// False when the engine sent no translation and the source text stands in.
        let hasEngineTranslation: Bool
        let timing: Timing
    }

    enum Output: Equatable, Sendable {
        case draft(Draft?)
        case sentence(Sentence)
    }

    private let configuration: Configuration
    /// False when no voice activity detector is running. Pauses are then inferred from
    /// gaps in the delta stream.
    private let hasVoiceActivitySignal: Bool
    private let makeSegmentID: () -> UUID

    private var segmentID: UUID
    private var sourceTail = ""
    private var translationTail = ""
    private var silenceStartedAt: TimeInterval?
    private var lastDeltaAt: TimeInterval?
    private var firstSourceDeltaAt: TimeInterval?
    private var firstTranslationDeltaAt: TimeInterval?

    init(
        configuration: Configuration = Configuration(),
        hasVoiceActivitySignal: Bool = true,
        makeSegmentID: @escaping () -> UUID = { UUID() }
    ) {
        self.configuration = configuration
        self.hasVoiceActivitySignal = hasVoiceActivitySignal
        self.makeSegmentID = makeSegmentID
        self.segmentID = makeSegmentID()
    }

    var hasPendingText: Bool {
        Self.displayText(sourceTail).isEmpty == false || Self.displayText(translationTail).isEmpty == false
    }

    // MARK: Inputs

    mutating func appendSource(_ delta: String, at now: TimeInterval) -> [Output] {
        guard delta.isEmpty == false else { return [] }
        sourceTail += delta
        lastDeltaAt = now
        if firstSourceDeltaAt == nil { firstSourceDeltaAt = now }
        return commitsAndDraft(at: now)
    }

    mutating func appendTranslation(_ delta: String, at now: TimeInterval) -> [Output] {
        guard delta.isEmpty == false else { return [] }
        translationTail += delta
        lastDeltaAt = now
        if firstTranslationDeltaAt == nil { firstTranslationDeltaAt = now }
        return commitsAndDraft(at: now)
    }

    mutating func speechStarted(at now: TimeInterval) {
        silenceStartedAt = nil
    }

    mutating func speechEnded(at now: TimeInterval) {
        silenceStartedAt = now
    }

    /// Call regularly: time passing is what turns a pause into a commit.
    mutating func advance(to now: TimeInterval) -> [Output] {
        let sentences = collectCommits(at: now)
        guard sentences.isEmpty == false else { return [] }
        return sentences.map(Output.sentence) + [.draft(currentDraft())]
    }

    /// Commits everything that is left, for the end of a session or a reconnect.
    mutating func flush(at now: TimeInterval) -> [Output] {
        guard let sentence = makeSentence(source: sourceTail, translation: translationTail, at: now) else {
            resetSegment()
            return []
        }

        sourceTail = ""
        translationTail = ""
        resetSegment()
        return [.sentence(sentence), .draft(nil)]
    }

    // MARK: Commit rules

    private mutating func commitsAndDraft(at now: TimeInterval) -> [Output] {
        let sentences = collectCommits(at: now)
        return sentences.map(Output.sentence) + [.draft(currentDraft())]
    }

    private mutating func collectCommits(at now: TimeInterval) -> [Sentence] {
        var sentences: [Sentence] = []

        while let sentence = cutOverlongTail(at: now) {
            sentences.append(sentence)
        }

        if let sentence = commitOnPause(at: now) {
            sentences.append(sentence)
        }

        return sentences
    }

    private mutating func commitOnPause(at now: TimeInterval) -> Sentence? {
        guard hasPendingText, let silence = silenceDuration(at: now) else {
            return nil
        }

        let quietFor = lastDeltaAt.map { now - $0 } ?? .infinity
        let isSettled = quietFor >= configuration.settleInterval
        let translation = Self.displayText(translationTail)

        let shouldCommit: Bool
        if translation.isEmpty {
            shouldCommit = silence >= configuration.missingTranslationWait && isSettled
        } else if silence >= configuration.maximumPauseWait {
            shouldCommit = true
        } else if silence >= configuration.pauseSilence {
            shouldCommit = isSettled
        } else if silence >= configuration.punctuationSilence, Self.endsSentence(translation) {
            shouldCommit = isSettled
        } else {
            shouldCommit = false
        }

        guard shouldCommit,
              let sentence = makeSentence(source: sourceTail, translation: translationTail, at: now) else {
            return nil
        }

        sourceTail = ""
        translationTail = ""
        resetSegment()
        return sentence
    }

    /// Long monologue: commit up to the last punctuation mark so the draft stays short.
    ///
    /// The translation decides when: it trails the source, so cutting on the source's
    /// length would commit sentences before their translation exists. Source text with
    /// no translation at all is only cut once it is twice as long.
    private mutating func cutOverlongTail(at now: TimeInterval) -> Sentence? {
        let limit = configuration.maximumTailLength
        let translationIsOverlong = translationTail.count > limit
        let sourceIsOverlongAlone = Self.displayText(translationTail).isEmpty && sourceTail.count > limit * 2
        guard translationIsOverlong || sourceIsOverlongAlone else {
            return nil
        }

        let translationCut = translationIsOverlong ? Self.cutIndex(in: translationTail) : translationTail.endIndex
        let translationHead = String(translationTail[..<translationCut])
        let translationRest = String(translationTail[translationCut...])

        // The source gives up as many sentences as the translation did, so the two
        // lines keep describing the same speech. If it cannot be matched that way it
        // is cut at its last sentence end, or moves whole.
        let sourceCut: String.Index
        if translationIsOverlong {
            let translatedSentenceCount = Self.sentenceEnds(in: translationHead).count
            let sourceSentenceEnds = Self.sentenceEnds(in: sourceTail)
            if translatedSentenceCount > 0, sourceSentenceEnds.count >= translatedSentenceCount {
                sourceCut = sourceSentenceEnds[translatedSentenceCount - 1]
            } else {
                sourceCut = sourceSentenceEnds.last ?? sourceTail.endIndex
            }
        } else {
            sourceCut = Self.cutIndex(in: sourceTail)
        }
        let sourceHead = String(sourceTail[..<sourceCut])
        let sourceRest = String(sourceTail[sourceCut...])

        guard let sentence = makeSentence(source: sourceHead, translation: translationHead, at: now) else {
            return nil
        }

        sourceTail = sourceRest
        translationTail = translationRest
        resetSegment()
        // The remainder is already under way: its first deltas count as arriving now.
        if Self.displayText(sourceTail).isEmpty == false { firstSourceDeltaAt = now }
        if Self.displayText(translationTail).isEmpty == false { firstTranslationDeltaAt = now }
        return sentence
    }

    private func silenceDuration(at now: TimeInterval) -> TimeInterval? {
        if hasVoiceActivitySignal {
            return silenceStartedAt.map { max(0, now - $0) }
        }

        return lastDeltaAt.map { max(0, now - $0) }
    }

    private func makeSentence(source: String, translation: String, at now: TimeInterval) -> Sentence? {
        let sourceText = Self.displayText(source)
        let translatedText = Self.displayText(translation)
        guard sourceText.isEmpty == false || translatedText.isEmpty == false else {
            return nil
        }

        return Sentence(
            segmentID: segmentID,
            sourceText: sourceText.isEmpty ? translatedText : sourceText,
            translatedText: translatedText.isEmpty ? sourceText : translatedText,
            hasEngineTranslation: translatedText.isEmpty == false,
            timing: Timing(
                speechEndedAt: hasVoiceActivitySignal ? silenceStartedAt : nil,
                firstSourceDeltaAt: firstSourceDeltaAt,
                firstTranslationDeltaAt: firstTranslationDeltaAt,
                committedAt: now
            )
        )
    }

    private mutating func resetSegment() {
        segmentID = makeSegmentID()
        firstSourceDeltaAt = nil
        firstTranslationDeltaAt = nil
    }

    private func currentDraft() -> Draft? {
        let sourceText = Self.displayText(sourceTail)
        let translatedText = Self.displayText(translationTail)
        guard sourceText.isEmpty == false || translatedText.isEmpty == false else {
            return nil
        }

        return Draft(segmentID: segmentID, sourceText: sourceText, translatedText: translatedText)
    }

    // MARK: Text helpers

    private static let sentenceTerminators: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    private static let clauseSeparators: Set<Character> = [",", ";", ":", "，", "；", "：", "、"]
    private static let closingMarks: Set<Character> = ["\"", "'", "”", "’", "»", "«", ")", "]", "“"]

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func endsSentence(_ text: String) -> Bool {
        var remainder = Substring(displayText(text))
        while let last = remainder.last, closingMarks.contains(last) {
            remainder = remainder.dropLast()
        }

        guard let last = remainder.last else { return false }
        return sentenceTerminators.contains(last)
    }

    /// Every sentence end in order: the index just past a run of terminators and any
    /// closing marks after it.
    static func sentenceEnds(in text: String) -> [String.Index] {
        var ends: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard sentenceTerminators.contains(text[index]) else {
                index = text.index(after: index)
                continue
            }

            var end = text.index(after: index)
            while end < text.endIndex,
                  sentenceTerminators.contains(text[end]) || closingMarks.contains(text[end]) {
                end = text.index(after: end)
            }
            ends.append(end)
            index = end
        }

        return ends
    }

    static func lastSentenceEnd(in text: String) -> String.Index? {
        sentenceEnds(in: text).last
    }

    /// Where to cut an overlong tail: the last sentence end, else the last clause
    /// separator, else the last space, else the whole text.
    static func cutIndex(in text: String) -> String.Index {
        if let sentenceEnd = lastSentenceEnd(in: text) {
            return sentenceEnd
        }

        if let separatorIndex = text.lastIndex(where: { clauseSeparators.contains($0) }) {
            return text.index(after: separatorIndex)
        }

        if let spaceIndex = text.lastIndex(where: { $0.isWhitespace }), spaceIndex != text.startIndex {
            return spaceIndex
        }

        return text.endIndex
    }
}
