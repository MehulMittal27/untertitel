import Foundation
import MeetingKit

/// Cuts the live model's growing word list into sentences: finished sentences become
/// final segments, the rest is the provisional line. Pure value type.
struct LiveWordSegmenter {
    /// A sentence also ends at a pause this long between two words.
    var pauseThatEndsSentence: TimeInterval = 1.2
    /// A finished sentence with nothing after it is final once this much audio has
    /// gone by without a word.
    var settleTime: TimeInterval = 1.0

    private(set) var committedWordCount = 0

    struct Output: Equatable {
        var finals: [(text: String, start: TimeInterval, end: TimeInterval)]
        var draft: (text: String, start: TimeInterval, end: TimeInterval)?

        static func == (lhs: Output, rhs: Output) -> Bool {
            lhs.finals.map(\.text) == rhs.finals.map(\.text) && lhs.draft?.text == rhs.draft?.text
        }
    }

    /// - Parameters:
    ///   - words: Every word of the run so far.
    ///   - audioTime: How much audio the model has been given, in seconds.
    mutating func update(words: [TimedWord], audioTime: TimeInterval, flush: Bool = false) -> Output {
        if words.count < committedWordCount {
            committedWordCount = words.count
        }

        var finals: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        var sentenceStart = committedWordCount
        var index = committedWordCount
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            let endsWithPunctuation = Self.endsSentence(word.text)
            let pauseFollows = next.map { $0.start - word.end >= pauseThatEndsSentence } ?? false
            let settled = next == nil && audioTime - word.end >= settleTime
            if (endsWithPunctuation && (next != nil || settled)) || pauseFollows || (flush && next == nil) {
                let sentence = Array(words[sentenceStart...index])
                finals.append(Self.joined(sentence))
                sentenceStart = index + 1
            }
            index += 1
        }
        committedWordCount = sentenceStart

        let rest = Array(words[committedWordCount...])
        return Output(finals: finals, draft: rest.isEmpty ? nil : Self.joined(rest))
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…。？！".contains(last)
    }

    static func joined(_ words: [TimedWord]) -> (text: String, start: TimeInterval, end: TimeInterval) {
        (
            words.map(\.text).joined(separator: " "),
            words.first?.start ?? 0,
            words.last?.end ?? 0
        )
    }
}

/// Matches words to speakers, and the live speakers to the ones found after Stop.
enum MeetingAlignment {
    /// The speaker who talks most between `start` and `end`; failing that, the one
    /// whose turn is closest, within a second.
    static func speaker(from start: TimeInterval, to end: TimeInterval, in turns: [SpeakerTurn]) -> String? {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            overlap[turn.speaker, default: 0] += min(turn.end, end) - max(turn.start, start)
        }
        if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }

        let middle = (start + end) / 2
        let nearest = turns.min { distance($0, to: middle) < distance($1, to: middle) }
        guard let nearest, distance(nearest, to: middle) <= 1 else {
            return nil
        }
        return nearest.speaker
    }

    private static func distance(_ turn: SpeakerTurn, to time: TimeInterval) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    /// The speaker of one word from the pass after Stop, whose turns may overlap: the
    /// turn that covers the word's middle; where two do, the speaker who started most
    /// recently, since that is who begins the new phrase. `overlapping` is true when
    /// someone else is talking at the same time.
    static func wordSpeaker(_ word: TimedWord, in turns: [SpeakerTurn]) -> (speaker: String?, overlapping: Bool) {
        let middle = (word.start + word.end) / 2
        let covering = turns.filter { $0.start <= middle && middle <= $0.end }
        guard let latest = covering.max(by: { $0.start < $1.start }) else {
            return (speaker(from: word.start, to: max(word.end, word.start + 0.01), in: turns), false)
        }
        return (latest.speaker, Set(covering.map(\.speaker)).count > 1)
    }

    /// Words grouped into segments by speaker. A segment also ends at a long pause
    /// or once a sentence has run long. Speakers are numbered from 1 in order of
    /// first appearance. A segment most of whose words were spoken over someone else
    /// is marked overlapping.
    static func segments(
        words: [TimedWord],
        turns: [SpeakerTurn],
        pauseThatSplits: TimeInterval = 1.5,
        maximumWords: Int = 40
    ) -> [MeetingSegment] {
        var numbers: [String: Int] = [:]
        func number(for speaker: String?) -> Int? {
            guard let speaker else { return nil }
            if let existing = numbers[speaker] { return existing }
            let next = numbers.count + 1
            numbers[speaker] = next
            return next
        }

        var segments: [MeetingSegment] = []
        var current: [TimedWord] = []
        var currentSpeaker: Int?
        var currentOverlaps = 0

        func close() {
            guard current.isEmpty == false else { return }
            let joined = LiveWordSegmenter.joined(current)
            segments.append(MeetingSegment(
                start: joined.start,
                end: joined.end,
                text: joined.text,
                speaker: currentSpeaker,
                overlapping: currentOverlaps * 2 >= current.count
            ))
            current = []
            currentOverlaps = 0
        }

        for word in words {
            let assignment = wordSpeaker(word, in: turns)
            let wordSpeaker = number(for: assignment.speaker) ?? currentSpeaker
            let pause = current.last.map { word.start - $0.end } ?? 0
            let sentenceRanLong = current.count >= maximumWords
                && current.last.map { LiveWordSegmenter.endsSentence($0.text) } == true
            if current.isEmpty == false, wordSpeaker != currentSpeaker || pause >= pauseThatSplits || sentenceRanLong {
                close()
            }
            currentSpeaker = wordSpeaker
            current.append(word)
            if assignment.overlapping { currentOverlaps += 1 }
        }
        close()
        return segments
    }

    /// Carries the names given to live speakers over to the speakers found after
    /// Stop: each named live speaker's name goes to the final speaker it overlaps
    /// most, and no final speaker gets two names.
    static func carryNames(
        names: [Int: String],
        live: [MeetingSegment],
        final: [MeetingSegment]
    ) -> [Int: String] {
        guard names.isEmpty == false else { return [:] }

        var overlap: [Int: [Int: TimeInterval]] = [:]
        for liveSegment in live {
            guard let liveSpeaker = liveSegment.speaker, names[liveSpeaker] != nil else { continue }
            for finalSegment in final {
                guard let finalSpeaker = finalSegment.speaker else { continue }
                let shared = min(liveSegment.end, finalSegment.end) - max(liveSegment.start, finalSegment.start)
                if shared > 0 {
                    overlap[liveSpeaker, default: [:]][finalSpeaker, default: 0] += shared
                }
            }
        }

        let pairs = overlap.flatMap { liveSpeaker, finals in
            finals.map { (live: liveSpeaker, final: $0.key, seconds: $0.value) }
        }
        .sorted { $0.seconds > $1.seconds }

        var result: [Int: String] = [:]
        var usedLive = Set<Int>()
        for pair in pairs where usedLive.contains(pair.live) == false && result[pair.final] == nil {
            result[pair.final] = names[pair.live]
            usedLive.insert(pair.live)
        }
        return result
    }
}

/// A word with the speaker who said it, as a cloud engine labels it.
struct SpokenWord: Equatable {
    var word: TimedWord
    var speaker: String?
}

/// Turns Soniox's speaker-labelled tokens into meeting segments: words are rebuilt
/// from their pieces, a segment ends at a speaker change or at the end of a sentence,
/// and a segment is final once something follows it. Pure value type.
struct SpeakerTokenAssembler {
    private var finalWords: [SpokenWord] = []
    private var committedCount = 0

    struct Segment: Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String?
    }

    struct Output: Equatable {
        var finals: [Segment] = []
        var draft: Segment?
    }

    /// Words from tokens: a piece that starts with a space starts a new word.
    static func words(from tokens: [SpeakerToken], offset: TimeInterval) -> [SpokenWord] {
        var words: [SpokenWord] = []
        for token in tokens where token.text.isEmpty == false {
            let start = offset + TimeInterval(token.startMilliseconds) / 1000
            let end = offset + TimeInterval(token.endMilliseconds) / 1000
            let startsWord = token.text.first?.isWhitespace == true || words.isEmpty
            let text = token.text.trimmingCharacters(in: .whitespaces)
            guard text.isEmpty == false else { continue }
            if startsWord {
                words.append(SpokenWord(word: TimedWord(text: text, start: start, end: end), speaker: token.speaker))
            } else {
                let last = words[words.count - 1]
                words[words.count - 1] = SpokenWord(
                    word: TimedWord(text: last.word.text + text, start: last.word.start, end: end),
                    speaker: last.speaker
                )
            }
        }
        return words
    }

    /// Takes one response: its final tokens (appended) and its provisional ones.
    mutating func update(final: [SpeakerToken], provisional: [SpeakerToken], offset: TimeInterval) -> Output {
        appendFinal(Self.words(from: final, offset: offset), continuing: final.first.map { $0.text.first?.isWhitespace == false } ?? false)

        var output = Output()
        var sentenceStart = committedCount
        var index = committedCount
        while index < finalWords.count {
            let current = finalWords[index]
            let next = index + 1 < finalWords.count ? finalWords[index + 1] : nil
            let speakerChanges = next.map { $0.speaker != current.speaker } ?? false
            if next != nil, speakerChanges || LiveWordSegmenter.endsSentence(current.word.text) {
                output.finals.append(Self.segment(Array(finalWords[sentenceStart...index])))
                sentenceStart = index + 1
            }
            index += 1
        }
        committedCount = sentenceStart

        let pending = Array(finalWords[committedCount...]) + Self.words(from: provisional, offset: offset)
        output.draft = pending.isEmpty ? nil : Self.segment(pending)
        return output
    }

    /// Everything left, as final segments: the meeting has ended.
    mutating func flush() -> [Segment] {
        var segments: [Segment] = []
        var start = committedCount
        for index in committedCount..<finalWords.count {
            let isLast = index == finalWords.count - 1
            if isLast || finalWords[index + 1].speaker != finalWords[index].speaker {
                segments.append(Self.segment(Array(finalWords[start...index])))
                start = index + 1
            }
        }
        committedCount = finalWords.count
        return segments
    }

    /// A response's first final piece may continue the last word of the one before.
    private mutating func appendFinal(_ words: [SpokenWord], continuing: Bool) {
        guard var first = words.first else { return }
        if continuing, let last = finalWords.last, finalWords.count > committedCount {
            first.word = TimedWord(text: last.word.text + first.word.text, start: last.word.start, end: first.word.end)
            first.speaker = last.speaker
            finalWords[finalWords.count - 1] = first
            finalWords.append(contentsOf: words.dropFirst())
        } else {
            finalWords.append(contentsOf: words)
        }
    }

    private static func segment(_ words: [SpokenWord]) -> Segment {
        let joined = LiveWordSegmenter.joined(words.map(\.word))
        return Segment(text: joined.text, start: joined.start, end: joined.end, speaker: words.first?.speaker)
    }
}
