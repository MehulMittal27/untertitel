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

    /// Words grouped into segments by speaker. A segment also ends at a long pause
    /// or once a sentence has run long. Speakers are numbered from 1 in order of
    /// first appearance.
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

        func close() {
            guard current.isEmpty == false else { return }
            let joined = LiveWordSegmenter.joined(current)
            segments.append(MeetingSegment(start: joined.start, end: joined.end, text: joined.text, speaker: currentSpeaker))
            current = []
        }

        for word in words {
            let turnSpeaker = Self.speaker(from: word.start, to: max(word.end, word.start + 0.01), in: turns)
            let wordSpeaker = number(for: turnSpeaker) ?? currentSpeaker
            let pause = current.last.map { word.start - $0.end } ?? 0
            let sentenceRanLong = current.count >= maximumWords
                && current.last.map { LiveWordSegmenter.endsSentence($0.text) } == true
            if current.isEmpty == false, wordSpeaker != currentSpeaker || pause >= pauseThatSplits || sentenceRanLong {
                close()
            }
            currentSpeaker = wordSpeaker
            current.append(word)
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
