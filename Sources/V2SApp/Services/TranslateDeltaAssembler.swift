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
        /// A caption is cut once its translation is longer than this, in words or in
        /// characters, so it always fits two lines of the subtitle block.
        var maximumCaptionWords = 16
        var maximumCaptionCharacters = 110
        /// Where an overlong caption with no punctuation is cut.
        var preferredCaptionWords = 12
        /// A finished sentence becomes its own caption once it is at least this long,
        /// as soon as the next sentence starts.
        var minimumSentenceCaptionWords = 8
        /// A cut at a comma or similar must leave at least this many words before it.
        var minimumClauseCaptionWords = 6
        /// Source text with no translation at all is cut on its own at this length.
        var maximumUntranslatedCharacters = 160
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

    /// Forgets source text that has not been committed, for when source transcription
    /// is switched off mid-sentence and the rest of it will never arrive.
    mutating func discardPendingSource() {
        sourceTail = ""
        firstSourceDeltaAt = nil
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

    /// Continuous speech: commit a readable chunk so the caption stays short.
    ///
    /// The translation decides when: it trails the source, so cutting on the source's
    /// length would commit sentences before their translation exists. Two cases:
    /// a finished sentence of reasonable length is committed as soon as the next one
    /// starts, and anything longer than a caption can hold is cut at the best
    /// punctuation mark inside the limit.
    private mutating func cutOverlongTail(at now: TimeInterval) -> Sentence? {
        if let cut = Self.captionCut(in: translationTail, configuration: configuration) {
            let translationHead = String(translationTail[..<cut.index])
            let translationRest = String(translationTail[cut.index...])
            let sourceCut = sourceCutIndex(matching: translationHead, cut: cut)
            return commitCut(
                sourceHead: String(sourceTail[..<sourceCut]),
                sourceRest: String(sourceTail[sourceCut...]),
                translationHead: translationHead,
                translationRest: translationRest,
                at: now
            )
        }

        // Source text that never gets a translation (speech already in the target
        // language) is cut on its own once it is clearly too long to keep waiting.
        guard Self.displayText(translationTail).isEmpty,
              sourceTail.count > configuration.maximumUntranslatedCharacters else {
            return nil
        }

        var sourceConfiguration = configuration
        sourceConfiguration.minimumSentenceCaptionWords = Int.max
        let sourceCut = Self.captionCut(in: sourceTail, configuration: sourceConfiguration)?.index
            ?? Self.cutIndex(in: sourceTail)
        return commitCut(
            sourceHead: String(sourceTail[..<sourceCut]),
            sourceRest: String(sourceTail[sourceCut...]),
            translationHead: "",
            translationRest: translationTail,
            at: now
        )
    }

    private mutating func commitCut(
        sourceHead: String,
        sourceRest: String,
        translationHead: String,
        translationRest: String,
        at now: TimeInterval
    ) -> Sentence? {
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

    /// Where the source is cut so both lines keep describing the same speech.
    private func sourceCutIndex(matching translationHead: String, cut: CaptionCut) -> String.Index {
        let sourceSentenceEnds = Self.sentenceEnds(in: sourceTail)

        if cut.isSentenceEnd {
            // Give up as many sentences as the translation did.
            let translatedSentenceCount = Self.sentenceEnds(in: translationHead).count
            if translatedSentenceCount > 0, sourceSentenceEnds.count >= translatedSentenceCount {
                return sourceSentenceEnds[translatedSentenceCount - 1]
            }
            return sourceSentenceEnds.last ?? sourceTail.endIndex
        }

        // A cut inside a sentence has no counterpart to count, so take about as many
        // words as were translated and settle on the nearest punctuation mark.
        let sourceWords = Self.wordEnds(in: sourceTail)
        guard sourceWords.isEmpty == false else { return sourceTail.endIndex }
        let translatedWordCount = Self.wordEnds(in: translationHead).count
        let target = min(max(Int((Double(translatedWordCount) * 0.9).rounded()), 1), sourceWords.count)

        let window = max(0, target - 4)...min(sourceWords.count - 1, target + 2)
        let boundaries = Set(Self.clauseEnds(in: sourceTail) + sourceSentenceEnds)
        let punctuated = window
            .filter { boundaries.contains(sourceWords[$0]) }
            .min { abs($0 + 1 - target) < abs($1 + 1 - target) }
        return sourceWords[punctuated ?? (target - 1)]
    }

    struct CaptionCut: Equatable {
        let index: String.Index
        let isSentenceEnd: Bool
    }

    /// Decides whether `text` should give up a caption now, and where.
    static func captionCut(in text: String, configuration: Configuration) -> CaptionCut? {
        let wordEnds = wordEnds(in: text)
        guard wordEnds.isEmpty == false else { return nil }

        func wordCount(upTo index: String.Index) -> Int {
            wordEnds.prefix { $0 <= index }.count
        }
        func hasTextAfter(_ index: String.Index) -> Bool {
            text[index...].contains { $0.isWhitespace == false }
        }

        let sentenceEnds = sentenceEnds(in: text)
        let isOverlong = wordEnds.count > configuration.maximumCaptionWords
            || displayText(text).count > configuration.maximumCaptionCharacters

        // The furthest point a single caption may reach.
        var limit = wordEnds[min(wordEnds.count, configuration.maximumCaptionWords) - 1]
        while text.distance(from: text.startIndex, to: limit) > configuration.maximumCaptionCharacters,
              let shorter = wordEnds.last(where: { $0 < limit }) {
            limit = shorter
        }

        // A finished sentence, with the next one already started.
        if let sentenceEnd = sentenceEnds.last(where: { $0 <= limit && hasTextAfter($0) }),
           wordCount(upTo: sentenceEnd) >= (isOverlong ? 1 : configuration.minimumSentenceCaptionWords) {
            return CaptionCut(index: sentenceEnd, isSentenceEnd: true)
        }

        guard isOverlong else { return nil }

        if let clauseEnd = clauseEnds(in: text).last(where: { $0 <= limit && hasTextAfter($0) }),
           wordCount(upTo: clauseEnd) >= configuration.minimumClauseCaptionWords {
            return CaptionCut(index: clauseEnd, isSentenceEnd: false)
        }

        let preferred = wordEnds[min(wordEnds.count, configuration.preferredCaptionWords) - 1]
        return CaptionCut(index: min(preferred, limit), isSentenceEnd: false)
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
    private static let leadingStrayMarks: Set<Character> = ["-", "–", "—", ")", "]", "”", "’"]

    /// Text as it is shown: trimmed, and never starting with punctuation. A comma or
    /// full stop at the start belongs to the caption before, which has already gone.
    static func displayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.drop { character in
            character.isWhitespace
                || sentenceTerminators.contains(character)
                || clauseSeparators.contains(character)
                || leadingStrayMarks.contains(character)
        }
        return String(body)
    }

    /// The index just past each word, in order. Punctuation stays with its word.
    static func wordEnds(in text: String) -> [String.Index] {
        var ends: [String.Index] = []
        var isInsideWord = false
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                if isInsideWord { ends.append(index) }
                isInsideWord = false
            } else {
                isInsideWord = true
            }
            index = text.index(after: index)
        }

        if isInsideWord { ends.append(text.endIndex) }
        return ends
    }

    /// The index just past each comma, semicolon or colon that ends a word.
    static func clauseEnds(in text: String) -> [String.Index] {
        wordEnds(in: text).filter { end in
            end > text.startIndex && clauseSeparators.contains(text[text.index(before: end)])
        }
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
            // A full stop inside a word, as in "3.5" or "z.B.", ends nothing.
            if end == text.endIndex || text[end].isWhitespace {
                ends.append(end)
            }
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
